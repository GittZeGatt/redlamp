#!/usr/bin/env python3
"""The build Mac: builds and tests run on the owner's MacBook Pro, over SSH from this Mac (ARC-15).

Agents run builds and test suites there first, and here only when it doesn't answer (the owner's
rule, 13 October 2026). It's run from the owner's own Terminal, or from an agent's shell through the
sandbox relay (scripts/sandbox-relay.py); without the relay agents' shells can't reach the local
network, and everything runs here, as it would without the build Mac:

    scripts/build-mac.py status               # whether it answers, its versions, what it's running
    scripts/build-mac.py test --scheme <S>    # xcodebuild test on the working tree as it is
    scripts/build-mac.py test --scheme <S> --only <Target/Suite>    # some of its tests
    scripts/build-mac.py gate [<commit>]      # the push gate on a commit (HEAD by default)
    scripts/build-mac.py gate --suite         # the whole test suite, as CI runs it
    scripts/build-mac.py gate --full          # and CI's Release builds
    scripts/build-mac.py e2e [-- <arguments>] # the regression suite on the working tree
    scripts/build-mac.py release-checks       # a release's checks on this checkout's commit
    scripts/build-mac.py attach [<job>]       # follow a job again (the one running by default)
    scripts/build-mac.py cancel [<job>]       # stop a job there (the one running by default)
    scripts/build-mac.py models               # this Mac's models, copied to the build Mac where it lacks them
    scripts/build-mac.py setup [<options>]    # scripts/build-mac/setup.sh there, with this Mac's versions

A job sends a commit with git push to the build Mac's clone (~/src/build-mac/redlamp), under
refs/build-mac/, which the pre-push hook lets through. test and e2e send the working tree,
uncommitted and new files included, as a commit made with a temporary index, which leaves the
checkout's index and branch as they are (HEAD itself when nothing differs from it). The job runs
there in a process of its own, so it carries on if the connection drops, under caffeinate. The
command prints what the job prints; Ctrl-C cancels the job, and --detach leaves it running for
attach to follow. Its log comes back into build/build-mac/<job>/, with the push gate's own log or
xcodebuild's, the tests' results (tests.json, which scripts/test-results.py compares with a run
here) and, when tests fail, their result bundle; a gate's pass comes back into
build/push-gate/passed, so a push of that commit, by the owner or an agent, goes straight through.

The build Mac runs several jobs at once, each in a lane of its own: 3 short tests (test with --only)
and 2 long jobs (a gate, or test for a whole scheme). A test's lane is a worktree beside the clone
whose DerivedData stays warm between jobs, and a job takes the lane its checkout used last when
it's free. The regression suite drives the screen, so it runs alone: it waits for the jobs running,
and jobs that come meanwhile wait for it. A job whose lanes are all taken waits there, saying what
for, rather than running here (the owner's choice, 13 October 2026).

test runs xcodebuild test for the scheme unsigned, as CI and the push gate do, and shows failures,
errors and each bundle's result. e2e runs scripts/e2e.py, with the arguments after --, and brings
the run's folder back into the checkout's build/e2e/, leaving its photos, test home and exports
there; mise run release finds a passing report in it as it would one made here. e2e.py's options
that name this Mac's files, check a signed app or record performance run it here. release-checks,
which mise run release-checks runs in the release copy, is the regression suite's release tier with
focus, then the push gate on every test suite, each skipped if it has passed already, on either Mac.

When the build Mac doesn't answer, or its Xcode isn't this Mac's, a command says so in one line and
runs here (test in the checkout, with its own build/DerivedData-test); a different macOS is reported
and allowed, since only Xcode has to match. --there waits for the build Mac instead, and gate
--there checks a commit there even when it passed here; --here doesn't try it.

The build Mac is the host build-mac in ~/.ssh/config; REDLAMP_BUILD_MAC names another. Under its
~/src/build-mac: the clone, the push gate's worktree beside it (redlamp-push-gate), lanes/, with a
worktree for each test lane, and jobs/, with a folder per job (job.json and its log) and a copy of
this script, sent with each command, which runs its side of them.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOST = os.environ.get("REDLAMP_BUILD_MAC", "build-mac")
# Under the build Mac's home folder.
BASE_THERE = "src/build-mac"
CLONE_THERE = f"{BASE_THERE}/redlamp"
JOBS_THERE = f"{BASE_THERE}/jobs"
LANES_THERE = f"{BASE_THERE}/lanes"
# An answer within 12 seconds or none: through the sandbox relay that includes the relay's own
# lookup of the build Mac's name, which took 4.2 s once it had just come back, and the 10 s the
# relay gives it to answer. A connection that stops answering for a minute has dropped.
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=12", "-o", "ServerAliveInterval=15",
       "-o", "ServerAliveCountMax=4"]
# How many jobs of each size run there at once, each in a lane of its own (the owner's choice).
LANES = {"short": 3, "long": 2}
# What a test lane takes from the clone, as the push gate takes them from the main checkout.
FIXTURES = ("tests/fixtures/raw", "tests/fixtures/cameras", "tests/fixtures/shoots")
BUILT = ("vendor/build", "vendor/cache", "Tuist/.build")
# Worth showing while tests run, as the push gate shows them: failures, errors, crashes and each
# bundle's result. The rest is kept in the job's xcodebuild.log.
SHOWN = re.compile(r"✘|(?:^|: )error: |Test run with \d+ tests|unexpected exit|\*\* [A-Z ]+ \*\*")
# e2e.py's options that keep it here: they name this Mac's files or check a signed app, or record
# performance, which stays with this Mac until the build Mac has a series of its own (ARC-09).
E2E_HERE = ("--passing-report", "--blackbox", "--app", "--replay", "--out", "--record", "-h", "--help")
# The push gate's levels, each covering the ones before it (scripts/push-gate.py).
LEVELS = ("checks", "reference", "suite", "full")
FINAL = ("passed", "failed", "cancelled", "lost")
JOB_ID = re.compile(r"\d{8}-\d{6}-[a-z0-9]+-[0-9a-f]{7}")
# What a regression run's folder keeps that each run makes again: left on the build Mac.
LEFT_THERE = ("home", "photos", "originals", "exports")
# Starts the last line the build Mac's side of a command prints: what came of it, as JSON.
MARK = b"@@build-mac "
KEPT_JOBS = 30
MODELS = Path.home() / "Library/Application Support/Redlamp/Models"
# Git exports GIT_DIR and the like to hooks; git run from here mustn't see them.
ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def say(message: str) -> None:
    print(f"==> {message}", flush=True)


def took(seconds: float) -> str:
    seconds = round(seconds)
    return f"{seconds} s" if seconds < 60 else f"{seconds // 60} min {seconds % 60} s"


def now() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def between(start: str | None, end: str | None) -> float | None:
    if not start or not end:
        return None
    return (dt.datetime.fromisoformat(end) - dt.datetime.fromisoformat(start)).total_seconds()


def xcode(answer: str) -> str:
    """`xcodebuild -version`'s answer as "26.6 (17F113)"."""
    version = re.search(r"^Xcode (\S+)", answer, re.M)
    build = re.search(r"^Build version (\S+)", answer, re.M)
    return f"{version.group(1)} ({build.group(1)})" if version and build else "none"


def versions() -> dict:
    """This Mac's macOS and Xcode."""
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    found = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout
    return {"macos": macos, "xcode": xcode(found)}


def sample(path: Path, base: Path) -> bool:
    """A sample raw the tests read: not a partial download, nor a sidecar written by opening one."""
    parts = path.relative_to(base).parts
    return path.is_file() and not any(part.startswith(".") or part.endswith((".part", ".redlamp")) for part in parts)


def samples(root: Path) -> list[str]:
    """The sample raws a checkout's tests read, as paths under tests/fixtures (what the push gate copies)."""
    found = []
    for folder in FIXTURES:
        base = root / folder
        for path in sorted(base.rglob("*")) if base.is_dir() else []:
            if sample(path, base):
                found.append(str(path.relative_to(root / "tests/fixtures")))
    return found


def models() -> list[str]:
    """The models installed for this account, as <id>/<version>."""
    if not MODELS.is_dir():
        return []
    return sorted(f"{model.name}/{version.name}" for model in MODELS.iterdir() if model.is_dir()
                  for version in model.iterdir() if version.is_dir())


# ---------------------------------------------------------------- this Mac's side


def git(*args: str, cwd: Path = ROOT) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"build-mac: git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def checkout() -> Path:
    """The main checkout, whose build/ the push gate reads, whichever worktree this runs in."""
    return Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).parent


def results(job: str) -> Path:
    return checkout() / "build/build-mac" / job


def shown(path: Path) -> str:
    try:
        return str(path.relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def covered(tree: str, level: str) -> dict | None:
    """The pass this Mac's push gate remembers for these files at this level or above."""
    try:
        record = json.loads((checkout() / "build/push-gate/passed" / tree).read_text())
    except (OSError, ValueError):
        return None
    if record.get("level") not in LEVELS or LEVELS.index(record["level"]) < LEVELS.index(level):
        return None
    return record


def line_there(mode: str, *args: str) -> str:
    """The shell line that puts this copy of the script on the build Mac and runs it there in a mode."""
    script = f"{JOBS_THERE}/build-mac.py"
    return (f"mkdir -p {JOBS_THERE} && cat > {script}.$$ && mv -f {script}.$$ {script} && "
            f"PATH=/opt/homebrew/bin:$PATH exec python3 {script} {shlex.join([mode, *args])}")


def run_there(mode: str, *args: str) -> subprocess.Popen:
    """The build Mac's side of a command, printing as it goes."""
    process = subprocess.Popen([*SSH, HOST, line_there(mode, *args)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, env=ENV)
    process.stdin.write(Path(__file__).read_bytes())
    process.stdin.close()
    return process


def ask(mode: str, *args: str, timeout: float = 60) -> tuple[dict | None, str]:
    """What the build Mac's side of a command came to, or None and why there was no answer."""
    try:
        result = subprocess.run([*SSH, HOST, line_there(mode, *args)], input=Path(__file__).read_bytes(),
                                capture_output=True, env=ENV, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, f"no answer in {round(timeout)} s"
    for line in reversed(result.stdout.splitlines()):
        if line.startswith(MARK):
            return json.loads(line[len(MARK):]), ""
    errors = result.stderr.decode(errors="replace").strip().splitlines()
    return None, errors[-1] if errors else f"ssh exited with {result.returncode}"


def probe() -> tuple[dict | None, str]:
    """The build Mac's macOS and Xcode, or None and why it didn't answer."""
    try:
        result = subprocess.run([*SSH, HOST, "sw_vers -productVersion; xcodebuild -version"],
                                capture_output=True, text=True, env=ENV, timeout=30)
    except subprocess.TimeoutExpired:
        return None, "no answer in 30 s"
    lines = result.stdout.strip().splitlines()
    if not lines:
        errors = result.stderr.strip().splitlines()
        return None, errors[-1] if errors else f"ssh exited with {result.returncode}"
    return {"macos": lines[0], "xcode": xcode(result.stdout)}, ""


def where(args: argparse.Namespace) -> dict | None:
    """The build Mac's versions when the check runs there; None when it runs here. Says which, and why."""
    if args.here:
        return None
    here = versions()
    waiting = False
    while True:
        found, why = probe()
        if found and found["xcode"] != here["xcode"]:
            differs = f"The build Mac has Xcode {found['xcode']} and this Mac {here['xcode']}"
            if args.there:
                sys.exit(f"build-mac: {differs}; `scripts/build-mac.py setup` installs this Mac's there")
            say(f"{differs}, so this runs here (`scripts/build-mac.py setup` installs this Mac's there)")
            return None
        if found:
            if found["macos"] != here["macos"]:
                say(f"The build Mac runs macOS {found['macos']} and this Mac {here['macos']}: allowed, "
                    "since only Xcode has to match")
            return found
        if not args.there:
            say(f"The build Mac doesn't answer ({why}), so this runs here")
            return None
        if not waiting:
            say(f"The build Mac doesn't answer ({why}); waiting for it (Ctrl-C stops)")
            waiting = True
        time.sleep(30)


def snapshot() -> str:
    """The working tree as a commit: HEAD when nothing differs from it, else a commit of the working
    tree on HEAD, uncommitted and new files included, made with a temporary index so the checkout's
    own index and branch stay as they are."""
    head = git("rev-parse", "HEAD")
    with tempfile.TemporaryDirectory() as scratch:
        index = Path(scratch) / "index"
        own = Path(git("rev-parse", "--path-format=absolute", "--git-path", "index"))
        if own.exists():
            shutil.copyfile(own, index)
        env = {**ENV, "GIT_INDEX_FILE": str(index)}
        for step in (["add", "--all"], ["write-tree"]):
            result = subprocess.run(["git", *step], cwd=ROOT, env=env, capture_output=True, text=True)
            if result.returncode != 0:
                sys.exit(f"build-mac: git {' '.join(step)}: {result.stderr.strip()}")
        tree = result.stdout.strip()
    if tree == git("rev-parse", "HEAD^{tree}"):
        say(f"On {git('log', '-1', '--format=%h %s', head)[:90]}, with nothing uncommitted")
        return head
    commit = git("commit-tree", tree, "-p", head, "-m", f"The working tree on {head[:7]}, for the build Mac")
    say(f"On {head[:7]}, with what's uncommitted ({git('diff', '--shortstat', head, commit)}), as {commit[:7]}")
    return commit


def new_job(kind: str, commit: str) -> str:
    """A job's name, with its folder here for the results, which no other job has."""
    while True:
        job = f"{dt.datetime.now():%Y%m%d-%H%M%S}-{kind}-{commit[:7]}"
        try:
            results(job).mkdir(parents=True)
            return job
        except FileExistsError:
            time.sleep(1)


def prune() -> None:
    """The newest jobs' results, and no others."""
    base = checkout() / "build/build-mac"
    kept = sorted(path for path in base.iterdir() if path.is_dir() and JOB_ID.fullmatch(path.name))
    for old in kept[:-KEPT_JOBS]:
        shutil.rmtree(old, ignore_errors=True)


def send(commit: str, job: str) -> None:
    """Puts the commit in the build Mac's clone, under refs/build-mac/, which the pre-push hook lets through."""
    env = {**ENV, "GIT_SSH_COMMAND": shlex.join(SSH)}
    result = subprocess.run(["git", "push", "--quiet", f"{HOST}:{CLONE_THERE}", f"{commit}:refs/build-mac/{job}"],
                            cwd=ROOT, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"build-mac: sending {commit[:7]} to the build Mac failed: {result.stderr.strip()}")


def start(kind: str, commit: str, command: list[str], detach: bool, size: str, into: Path | None = None) -> int:
    """Starts a job there, in a lane of its size (short, long, or alone); a regression run's folder
    comes back into `into`'s build/e2e/ when it ends."""
    job = new_job(kind, commit)
    say(f"On the build Mac, as {job}")
    send(commit, job)
    if into:
        (results(job) / "into").write_text(f"{into}\n")
    mode = ["_start", job, kind, commit, f"--size={size}", f"--from={ROOT}", *(["--detach"] if detach else []),
            "--", *command]
    if not detach:
        return follow(job, mode)
    state, why = ask(*mode)
    if state is None:
        sys.exit(f"build-mac: the build Mac didn't take {job}: {why}")
    results(job).mkdir(parents=True, exist_ok=True)
    say(f"{job} is {state['state']} there; `scripts/build-mac.py attach {job}` follows it and brings its "
        "results back")
    return 0


def follow(job: str, mode: list[str]) -> int:
    """Prints the job's log as it grows, keeping it in build/build-mac/<job>/, until the job ends."""
    folder = results(job)
    folder.mkdir(parents=True, exist_ok=True)
    state = None
    process = run_there(*mode)
    try:
        with (folder / "log").open("ab") as log:
            for line in process.stdout:
                if line.startswith(MARK):
                    state = json.loads(line[len(MARK):])
                    continue
                log.write(line)
                log.flush()
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
        process.wait()
    except KeyboardInterrupt:
        process.kill()
        say(f"Cancelling {job} on the build Mac")
        state, why = ask("_cancel", job, timeout=180)
        if state is None:
            say(f"The build Mac didn't answer ({why}); `scripts/build-mac.py cancel {job}` tries again")
            return 130
    if state is None:
        say(f"The connection dropped and {job} carries on there; `scripts/build-mac.py attach {job}` follows it")
        return 1
    if state["state"] == "unknown":
        shutil.rmtree(folder, ignore_errors=True)
        sys.exit(f"build-mac: the build Mac has no job {job}")
    return finish(job, state, folder)


def fetch(path: str, target: Path) -> bool:
    with target.open("wb") as out:
        code = subprocess.run([*SSH, HOST, f"cat {shlex.quote(path)}"], stdout=out, stderr=subprocess.DEVNULL,
                              env=ENV).returncode
    if code != 0:
        target.unlink(missing_ok=True)
    return code == 0


def unpack(path: str, target: Path) -> bool:
    """A folder there, without what a regression run makes again each time, into the target here."""
    process = run_there("_pack", path)
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            archive.extractall(target, filter="data")
    except (tarfile.TarError, OSError) as error:
        say(f"{Path(path).name} didn't come back ({error})")
        return False
    finally:
        process.wait()
    return target.exists()


def bring_back(run: str, into: Path) -> Path | None:
    """A regression run's folder there into the checkout's build/e2e/."""
    target = into / "build/e2e" / Path(run).name
    return target if unpack(run, target) else None


def remember(state: dict) -> None:
    """The build Mac's pass, where this Mac's push gate looks, so a push of the commit goes straight through."""
    passed = state["passed"]
    mine = covered(state["tree"], passed["level"])
    if mine and mine.get("machine") != "build-mac":
        return
    path = checkout() / "build/push-gate/passed" / state["tree"]
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {**passed, "machine": "build-mac", "macos": state.get("macos"), "xcode": state.get("xcode")}
    path.write_text(json.dumps(record) + "\n")
    say(f"Its pass ({passed['level']}) is kept here, so a push of {state['commit'][:7]} goes straight through")


def finish(job: str, state: dict, folder: Path) -> int:
    (folder / "job.json").write_text(json.dumps(state, indent=1) + "\n")
    printed = (folder / "log").read_text(errors="replace")
    gate_log = re.search(r"Log: (/\S+)\.log", printed)
    if gate_log:
        fetch(f"{gate_log.group(1)}.log", folder / "push-gate.log")
        fetch(f"{gate_log.group(1)}.tests.json", folder / "tests.json")
    if state.get("kind") == "test":
        fetch(f"{JOBS_THERE}/{job}/xcodebuild.log", folder / "xcodebuild.log")
        fetch(f"{JOBS_THERE}/{job}/tests.json", folder / "tests.json")
        if state["state"] != "passed" and unpack(f"{JOBS_THERE}/{job}/tests.xcresult", folder / "tests.xcresult"):
            say(f"Its result bundle is in {shown(folder / 'tests.xcresult')}")
    report = re.search(r"Report: (/\S+)/report\.md", printed)
    if report:
        into = Path((folder / "into").read_text().strip()) if (folder / "into").exists() else ROOT
        run = bring_back(report.group(1), into)
        say(f"Its report is in {shown(run / 'report.md')}" if run else f"`scripts/build-mac.py attach {job}` tries again")
    if state.get("passed"):
        remember(state)
    ran = between(state.get("started"), state.get("finished"))
    waited = between(state.get("queued"), state.get("started"))
    spent = f" in {took(ran)}" if ran is not None else ""
    queued = f", after {took(waited)} waiting for its turn" if waited and waited >= 5 else ""
    lane = f" (lane {state['lane']})" if state.get("lane") else ""
    say(f"{job}: {state['state']}{spent} on the build Mac{lane}{queued}; its logs are in {shown(folder)}")
    prune()
    if state["state"] == "passed":
        return 0
    return 130 if state["state"] == "cancelled" else state.get("exit") or 1


def pick(named: str | None, unfinished: bool) -> str:
    """The job named; or the one running there, else the next queued, else (unless unfinished) the newest."""
    if named:
        return named
    info, why = ask("_status")
    if info is None:
        sys.exit(f"build-mac: the build Mac doesn't answer ({why})")
    jobs = info["jobs"]
    running = [job for job in jobs if job["state"] == "running"]
    queued = [job for job in jobs if job["state"] == "queued"]
    if running or queued:
        return (running or queued[-1:])[0]["id"]
    if unfinished or not jobs:
        sys.exit("build-mac: nothing is running or queued there")
    return jobs[0]["id"]


# ---------------------------------------------------------------- commands


def here(command: list[str], replace: bool) -> int:
    """Runs the command on this Mac: in place of this process, or in one of its own."""
    if replace:
        os.execve(command[0], command, ENV)
    return subprocess.call(command, env=ENV)


def gate(args: argparse.Namespace, replace: bool = True, again: bool | None = None) -> int:
    """The push gate on a commit; with `again` (--there), there even when this Mac's gate passed it."""
    again = args.there if again is None else again
    commit = git("rev-parse", "--verify", f"{args.commit}^{{commit}}")
    flags = ["--full"] if args.full else ["--suite"] if args.suite else []
    asked = "full" if args.full else "suite" if args.suite else "reference"
    record = covered(git("rev-parse", f"{commit}^{{tree}}"), asked)
    there = record is not None and record.get("machine") == "build-mac"
    if record and (there or not again):
        on = " on the build Mac" if there else ""
        say(f"Its files passed the gate ({record['level']}){on} on {record['at'][:16].replace('T', ' at ')} "
            f"({record['commit'][:7]}); nothing to check")
        return 0
    if record:
        say(f"Its files passed the gate here ({record['level']}); --there checks them on the build Mac too")
    if where(args) is None:
        return here([str(ROOT / "scripts/push-gate.py"), commit, *flags], replace)
    return start("gate", commit, ["scripts/push-gate.py", commit, *flags], args.detach, size="long")


def kept_here(options: list[str]) -> str | None:
    """Why e2e.py's options keep it on this Mac, if they do."""
    for index, option in enumerate(options):
        name = option.split("=")[0]
        if name in E2E_HERE:
            return f"e2e.py's {name} is about this Mac's files, a signed app or its performance records"
        if option == "--tier=performance" or (option == "--tier" and options[index + 1:index + 2] == ["performance"]):
            return "The performance tier measures this Mac until the build Mac has a series of its own (ARC-09)"
    return None


def e2e(args: argparse.Namespace, replace: bool = True) -> int:
    """The regression suite on the working tree as it is, its run's folder brought back into build/e2e/."""
    kept = kept_here(args.options)
    if kept:
        say(f"{kept}, so this runs here")
    if kept or where(args) is None:
        if not (ROOT / "Redlamp.xcworkspace").is_dir():
            subprocess.run(["mise", "run", "generate"], cwd=ROOT, env=ENV, check=True)
        return here([str(ROOT / "scripts/e2e.py"), *args.options], replace)
    commit = snapshot()
    # Generated at each commit, which may add or remove source files.
    command = ["bash", "-c", 'mise run generate && exec scripts/e2e.py "$@"', "e2e", *args.options]
    return start("e2e", commit, command, args.detach, size="alone", into=ROOT)


def xcodebuild_test(args: argparse.Namespace, derived: Path, bundle: Path) -> list[str]:
    """xcodebuild test for the scheme and the tests asked for, unsigned, as the push gate and CI run it."""
    return ["xcodebuild", "test", "-workspace", "Redlamp.xcworkspace", "-scheme", args.scheme,
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived),
            "-resultBundlePath", str(bundle), "CODE_SIGNING_ALLOWED=NO",
            *[f"-only-testing:{name}" for name in args.only], *[f"-skip-testing:{name}" for name in args.skip]]


def run_tests(root: Path, args: argparse.Namespace, derived: Path, folder: Path, generate: bool) -> int:
    """xcodebuild test in the checkout at root, showing failures, errors and each bundle's result, and
    keeping in the job's folder its whole output (xcodebuild.log), the tests' results (tests.json) and,
    when it fails, the result bundle (tests.xcresult)."""
    folder.mkdir(parents=True, exist_ok=True)
    bundle = folder / "tests.xcresult"
    shutil.rmtree(bundle, ignore_errors=True)
    started = beat = time.monotonic()
    with (folder / "xcodebuild.log").open("w") as log:
        if generate:
            say("Generating the workspace")
            code = subprocess.run(["mise", "run", "generate"], cwd=root, env=ENV, stdin=subprocess.DEVNULL,
                                  stdout=log, stderr=subprocess.STDOUT).returncode
            if code != 0:
                say(f"Generating the workspace failed; its output is in {folder / 'xcodebuild.log'}")
                return code
        tests = [*args.only, *(f"all but {name}" for name in args.skip)]
        say(f"xcodebuild test {args.scheme}: {', '.join(tests) or 'every test'}")
        log.flush()
        process = subprocess.Popen(xcodebuild_test(args, derived, bundle), cwd=root, env=ENV,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, errors="replace")
        try:
            for line in process.stdout:
                log.write(line)
                if SHOWN.search(line):
                    print(f"    {line.rstrip()[:400]}", flush=True)
                if time.monotonic() - beat >= 180:
                    beat = time.monotonic()
                    print(f"    {took(beat - started)} so far", flush=True)
            code = process.wait()
        except KeyboardInterrupt:
            process.wait()
            raise
    summary = root / "scripts/test-results.py"
    if bundle.exists() and summary.exists():
        found = subprocess.run([sys.executable, str(summary), "summary", str(bundle), "--out", str(folder / "tests.json")],
                               env=ENV, capture_output=True, text=True)
        if found.returncode == 0 and found.stdout.strip():
            say(found.stdout.strip())
    if code == 0:
        shutil.rmtree(bundle, ignore_errors=True)
    return code


def test(args: argparse.Namespace) -> int:
    """xcodebuild test for a scheme on the working tree as it is: in a lane there, or here."""
    if where(args) is None:
        return test_here(args)
    commit = snapshot()
    options = ["--scheme", args.scheme, *[part for name in args.only for part in ("--only", name)],
               *[part for name in args.skip for part in ("--skip", name)]]
    return start("test", commit, options, args.detach, size="short" if args.only else "long")


def test_here(args: argparse.Namespace) -> int:
    """The same xcodebuild test in this checkout, on its working tree, with a DerivedData of its own."""
    head = git("rev-parse", "HEAD")
    job = new_job("test", head)
    folder = results(job)
    say(f"Here, as {job}")
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    started = now()
    with (build / "DerivedData-test.lock").open("a") as held:
        try:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            say("Waiting for the test run before it in this checkout, which uses the same DerivedData")
            fcntl.flock(held, fcntl.LOCK_EX)
        code = run_tests(ROOT, args, build / "DerivedData-test", folder,
                         generate=not (ROOT / "Redlamp.xcworkspace").is_dir())
    state = {"id": job, "kind": "test", "commit": head, "machine": "here", "state": "passed" if code == 0 else "failed",
             "exit": code, "started": started, "finished": now(), "macos": versions()["macos"]}
    (folder / "job.json").write_text(json.dumps(state, indent=1) + "\n")
    say(f"{job}: {state['state']} in {took(between(started, state['finished']))} here; "
        f"its logs are in {shown(folder)}")
    prune()
    return code


def release_checks(args: argparse.Namespace) -> int:
    """The regression suite's release tier with focus, then every test suite, on the checkout's commit."""
    commit = git("rev-parse", "HEAD")
    if git("status", "--porcelain", "--untracked-files=no"):
        sys.exit(f"build-mac: {ROOT} has uncommitted changes, and a release's checks run on the commit as it is")
    say(f"A release's checks on {git('log', '-1', '--format=%h %s', commit)[:90]}: the regression suite's "
        "release tier with focus, then every test suite")
    outcome = {}
    found = subprocess.run([str(ROOT / "scripts/e2e.py"), "--passing-report", commit, "--tier", "release", "--focus"],
                           capture_output=True, text=True, env=ENV)
    if found.returncode == 0:
        say(f"The regression suite passed already: {shown(Path(found.stdout.strip()))}")
        outcome["The regression suite"] = 0
    else:
        options = argparse.Namespace(there=args.there, here=args.here, detach=False,
                                     options=["--tier", "release", "--focus"])
        outcome["The regression suite"] = e2e(options, replace=False)
    suite = argparse.Namespace(commit=commit, suite=True, full=False, there=args.there, here=args.here, detach=False)
    outcome["Every test suite"] = gate(suite, replace=False, again=False)
    for name, code in outcome.items():
        say(f"{name}: {'passed' if code == 0 else 'failed'}")
    return 0 if all(code == 0 for code in outcome.values()) else 1


def copy_models(_args: argparse.Namespace) -> int:
    """This Mac's models, copied to the build Mac where it lacks them, each put in place once it has arrived."""
    info, why = ask("_status")
    if info is None:
        sys.exit(f"build-mac: the build Mac doesn't answer ({why})")
    missing = sorted(set(models()) - set(info["models"]))
    if not missing:
        say(f"The build Mac has this Mac's {len(models())} models")
        return 0
    size = sum(path.stat().st_size for model in missing for path in (MODELS / model).rglob("*") if path.is_file())
    say(f"Copying {len(missing)} models ({size / 1e9:.1f} GB) to the build Mac: {', '.join(missing)}")
    there = "Library/Application Support/Redlamp/Models"
    incoming = shlex.quote(f"{there}/.incoming")
    moves = []
    for model in missing:
        place, folder = shlex.quote(f"{there}/{model}"), shlex.quote(f"{there}/{Path(model).parent}")
        moves.append(f"mkdir -p {folder} && rm -rf {place} && mv {shlex.quote(f'{there}/.incoming/{model}')} {place}")
    line = (f"rm -rf {incoming} && mkdir -p {incoming} && tar -C {incoming} -xf - && {' && '.join(moves)} && "
            f"rm -rf {incoming}")
    started = time.monotonic()
    pack = subprocess.Popen(["tar", "-C", str(MODELS), "--exclude", ".DS_Store", "-cf", "-", *missing],
                            stdout=subprocess.PIPE, env=ENV)
    unpack = subprocess.run([*SSH, HOST, line], stdin=pack.stdout, env=ENV)
    pack.stdout.close()
    if pack.wait() != 0 or unpack.returncode != 0:
        sys.exit("build-mac: copying the models failed; the build Mac keeps those it had")
    say(f"Copied in {took(time.monotonic() - started)}; the tests and the regression suite there use them")
    return 0


def attach(args: argparse.Namespace) -> int:
    job = pick(args.job, unfinished=False)
    log = results(job) / "log"
    return follow(job, ["_follow", job, str(log.stat().st_size if log.exists() else 0)])


def cancel(args: argparse.Namespace) -> int:
    job = pick(args.job, unfinished=True)
    state, why = ask("_cancel", job, timeout=180)
    if state is None:
        sys.exit(f"build-mac: the build Mac didn't answer ({why})")
    if state["state"] == "unknown":
        sys.exit(f"build-mac: the build Mac has no job {job}")
    say(f"{job}: {state['state']}")
    return 0 if state["state"] in FINAL else 1


def status(_args: argparse.Namespace) -> int:
    info, why = ask("_status")
    if info is None:
        say(f"The build Mac ({HOST}) doesn't answer: {why}")
        return 1
    here = versions()
    say(f"The build Mac ({HOST}) answers: {info['gpu']}, macOS {info['macos']}, Xcode {info['xcode']}")
    if info["xcode"] != here["xcode"]:
        print(f"    This Mac has Xcode {here['xcode']}, so checks run here until "
              "`scripts/build-mac.py setup` installs it there")
    if info["macos"] != here["macos"]:
        print(f"    This Mac runs macOS {here['macos']}: allowed, since only Xcode has to match")
    if info["xcode"] == here["xcode"] and info["macos"] == here["macos"]:
        print("    The same macOS and Xcode as this Mac")
    print(f"    Load average {info['load']:.1f} on {info['cores']} cores; {info['free_gb']:.0f} GB free")
    print(f"    Lid: closing it {'leaves it awake' if info['sleep_disabled'] == '1' else 'puts it to sleep'}")
    screens = [f"{screen['name']} {screen['looks'].split(' @')[0]}"
               f"{' HiDPI' if screen['hidpi'] else ''}{' (main)' if screen['main'] else ''}"
               for screen in info["screens"]]
    print(f"    Screens: {'; '.join(screens) or 'none'}")
    print(f"    Clone: {info['clone']}")
    gate_here = checkout().parent / f"{checkout().name}-push-gate"
    for name, mine, theirs in (("Sample raws", samples(gate_here if (gate_here / "tests/fixtures").is_dir()
                                                       else checkout()), info["samples"]),
                               ("Models", models(), info["models"])):
        missing, extra = sorted(set(mine) - set(theirs)), sorted(set(theirs) - set(mine))
        if not missing and not extra:
            print(f"    {name}: the same {len(mine)} as this Mac's")
            continue
        parts = [f"{len(missing)} of this Mac's {len(mine)} missing ({', '.join(missing[:3])}"
                 f"{', …' if len(missing) > 3 else ''})"] if missing else []
        parts += [f"{len(extra)} this Mac lacks"] if extra else []
        copies = "; `scripts/build-mac.py models` copies them" if name == "Models" and missing else ""
        print(f"    {name}: {'; '.join(parts)}; the tests that need them skip where they're missing{copies}")
    for job in info["jobs"][:8]:
        ran = between(job.get("started"), job.get("finished") or now())
        spent = f" {'for' if job['state'] == 'running' else 'in'} {took(ran)}" if ran is not None else ""
        lane = f" (lane {job['lane']})" if job.get("lane") else ""
        print(f"    {job['id']}: {job['state']}{spent}{lane}")
    return 0


def setup(args: argparse.Namespace) -> int:
    here = versions()
    found = re.fullmatch(r"(\S+) \((\S+)\)", here["xcode"])
    if not found:
        sys.exit("build-mac: `xcodebuild -version` doesn't name this Mac's Xcode")
    version, build = found.groups()
    # The clone on origin/main first, so the setup that runs is origin/main's, unless it has changes.
    line = (f"cd {CLONE_THERE} && git fetch --quiet origin && "
            '{ [ -n "$(git status --porcelain --untracked-files=no)" ] '
            "|| git checkout --quiet --detach origin/main; } && "
            f"MACOS_VERSION={here['macos']} XCODE_VERSION={version} XCODE_BUILD={build} "
            f"exec bash scripts/build-mac/setup.sh {shlex.join(args.options)}")
    return subprocess.call(["ssh", "-t", *SSH[1:], HOST, line], env=ENV)


# ---------------------------------------------------------------- the build Mac's side


def folder_there(job: str) -> Path:
    return Path.home() / JOBS_THERE / job


def read_job(job: str) -> dict:
    try:
        return json.loads((folder_there(job) / "job.json").read_text())
    except (OSError, ValueError):
        return {"id": job, "state": "lost"}


def update_job(job: str, **changes) -> dict:
    folder = folder_there(job)
    with (folder / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = {**read_job(job), **changes}
        (folder / "job.json.new").write_text(json.dumps(state, indent=1) + "\n")
        (folder / "job.json.new").replace(folder / "job.json")
    return state


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def current(job: str) -> dict:
    """The job's state; a job whose supervisor is gone without finishing it (a restart) is lost."""
    state = read_job(job)
    if state["state"] in ("queued", "running"):
        supervisor = state.get("supervisor")
        waited = between(state.get("queued"), now()) or 0
        if (supervisor and not alive(supervisor)) or (not supervisor and waited > 60):
            state = update_job(job, state="lost", finished=now())
    return state


def outcome(job: str) -> dict:
    """The job's state, with a passing gate's record of its pass."""
    state = current(job)
    if state.get("kind") == "gate" and state["state"] == "passed":
        clone = Path.home() / CLONE_THERE
        tree = subprocess.run(["git", "rev-parse", f"{state['commit']}^{{tree}}"], cwd=clone,
                              capture_output=True, text=True).stdout.strip()
        try:
            state = {**state, "tree": tree,
                     "passed": json.loads((clone / "build/push-gate/passed" / tree).read_text())}
        except (OSError, ValueError):
            pass
    return state


def emit(value: dict) -> None:
    sys.stdout.buffer.write(MARK + json.dumps(value).encode() + b"\n")
    sys.stdout.buffer.flush()


def environment_there() -> dict:
    """A login shell's environment there, without relying on its startup files."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:" + env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    env["MISE_TRUSTED_CONFIG_PATHS"] = str(Path.home() / BASE_THERE)
    env.setdefault("LANG", "en_US.UTF-8")
    return env


def lock_there(name: str):
    """A lock file in lanes/, opened; a lock taken on it holds until it's closed or the process ends."""
    path = Path.home() / LANES_THERE / f"{name}.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path.open("a+")


def locked(handle, how: int) -> bool:
    try:
        fcntl.flock(handle, how | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    return True


def noted(name: str) -> dict:
    """What lanes/<name>.json says: which job took a lane, the clone or the Mac to itself last."""
    try:
        return json.loads((Path.home() / LANES_THERE / f"{name}.json").read_text())
    except (OSError, ValueError):
        return {}


def note(name: str, job: str, source: str = "") -> None:
    path = Path.home() / LANES_THERE / f"{name}.json"
    path.with_suffix(".new").write_text(json.dumps({"job": job, "source": source, "used": now()}) + "\n")
    path.with_suffix(".new").replace(path)


def running_jobs() -> list[str]:
    folders = sorted(path for path in (Path.home() / JOBS_THERE).iterdir() if JOB_ID.fullmatch(path.name))
    return [path.name for path in folders if read_job(path.name)["state"] == "running"]


def take_lane(job: str, size: str, source: str, log) -> tuple[str, object]:
    """A free lane of the size, held: the one the job's checkout used last, else the one used most recently."""
    names = [f"{size}-{number}" for number in range(1, LANES[size] + 1)]
    told = False
    while True:
        records = {name: noted(name) for name in names}
        order = sorted(names, key=lambda name: records[name].get("used", ""), reverse=True)
        order.sort(key=lambda name: records[name].get("source") != source)
        for name in order:
            handle = lock_there(name)
            if locked(handle, fcntl.LOCK_EX):
                note(name, job, source)
                return name, handle
            handle.close()
        if not told:
            taken = ", ".join(records[name].get("job", "?") for name in names)
            log.write(f"==> Waiting for one of the {len(names)} {size} lanes, which have {taken}\n".encode())
            told = True
        time.sleep(1)


def wait_turn(job: str, state: dict, log) -> tuple[str | None, list]:
    """Waits for the job's turn; returns its lane (none for a job that runs alone) and the locks it holds.

    A gate or a regression run puts the clone at its commit, so they take the clone one at a time. A
    job that runs alone holds the turnstile, which stops the jobs that come after it, until the jobs
    running have finished. The locks are taken in one order (the clone, a lane, the turnstile, the
    Mac), so jobs can't end up waiting for each other in a circle.
    """
    held, size = [], state.get("size", "long")
    if state["kind"] in ("gate", "e2e"):
        clone = lock_there("clone")
        if not locked(clone, fcntl.LOCK_EX):
            log.write(f"==> Waiting for the clone, which {noted('clone').get('job', 'another job')} has\n".encode())
            fcntl.flock(clone, fcntl.LOCK_EX)
        note("clone", job)
        held.append(clone)
    lane = None
    if size in LANES:
        lane, handle = take_lane(job, size, state.get("source", ""), log)
        held.append(handle)
    turnstile = lock_there("turnstile")
    alone = noted("alone").get("job", "a job")
    if not locked(turnstile, fcntl.LOCK_EX):
        log.write(f"==> Waiting for {alone}, which runs alone\n".encode())
        fcntl.flock(turnstile, fcntl.LOCK_EX)
    mac = lock_there("mac")
    if size in LANES:
        if not locked(mac, fcntl.LOCK_SH):
            log.write(f"==> Waiting for {noted('alone').get('job', 'a job')}, which runs alone\n".encode())
            fcntl.flock(mac, fcntl.LOCK_SH)
    else:
        note("alone", job)
        if not locked(mac, fcntl.LOCK_EX):
            running = ", ".join(running_jobs()) or "the jobs running"
            log.write(f"==> This runs alone, so it waits for {running}\n".encode())
            fcntl.flock(mac, fcntl.LOCK_EX)
    turnstile.close()
    return lane, [*held, mac]


def prepare_lane(place: Path, commit: str, env: dict, log) -> bool:
    """Puts a lane's worktree at the commit, with no other file but the clone's sample raws and built
    inputs, and its build folder, whose DerivedData keeps the lane's builds incremental."""
    clone = Path.home() / CLONE_THERE

    def run(*command: str, cwd: Path = place) -> bool:
        return subprocess.run(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=log,
                              stderr=subprocess.STDOUT).returncode == 0

    if (place / ".git").is_file():
        ready = run("git", "checkout", "--quiet", "--detach", "--force", commit) and \
            run("git", "clean", "-d", "--force", "--quiet")
    else:
        shutil.rmtree(place, ignore_errors=True)
        run("git", "worktree", "prune", cwd=clone)
        ready = run("git", "worktree", "add", "--quiet", "--detach", str(place), commit, cwd=clone)
    if not ready:
        return False
    for item in BUILT:
        if (clone / item).exists() and not (place / item).exists():
            (place / item).parent.mkdir(parents=True, exist_ok=True)
            run("cp", "-cR", str(clone / item), str(place / item))
    for item in FIXTURES:
        source = clone / item
        for path in sorted(source.rglob("*")) if source.is_dir() else []:
            target = place / item / path.relative_to(source)
            if sample(path, source) and not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                run("cp", "-c", str(path), str(target))
    return True


def supervise(job: str) -> None:
    """Runs the job at its commit once it's its turn, a test in its lane's worktree and a gate or a
    regression run in the clone, and records what came of it."""
    state = update_job(job, supervisor=os.getpid())
    clone = Path.home() / CLONE_THERE
    env = environment_there()
    with (folder_there(job) / "log").open("ab", buffering=0) as log:
        lane, held = wait_turn(job, state, log)
        if read_job(job).get("cancel"):
            update_job(job, state="cancelled", finished=now())
            return
        update_job(job, state="running", started=now(), **({"lane": lane} if lane else {}))
        if state["kind"] == "test":
            log.write(f"==> In lane {lane}\n".encode())
            place = Path.home() / LANES_THERE / lane
            ready = prepare_lane(place, state["commit"], env, log)
            command = [sys.executable, str(Path(__file__).resolve()), "_test", job, *state["command"]]
        else:
            place, command = clone, state["command"]
            # origin/main as GitHub has it now, which the push gate measures the commit's changes from.
            subprocess.run(["git", "fetch", "--quiet", "origin"], cwd=clone, env=env, stdin=subprocess.DEVNULL,
                           stdout=log, stderr=subprocess.STDOUT)
            ready = subprocess.run(["git", "checkout", "--quiet", "--detach", state["commit"]], cwd=clone, env=env,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT).returncode == 0
        if not ready:
            log.write(f"==> {place.name} couldn't be put at {state['commit'][:7]}\n".encode())
            update_job(job, state="failed", exit=1, finished=now())
            return
        awake = subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # A process group of its own, so that cancelling stops what it started too.
        process = subprocess.Popen(command, cwd=place, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        update_job(job, pid=process.pid)
        if read_job(job).get("cancel"):
            os.killpg(process.pid, signal.SIGINT)
        code = process.wait()
        # What it started (xcodebuild, the test runners) can outlive it for a moment after a cancel.
        for _ in range(120):
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.5)
        awake.terminate()
        for handle in held:
            handle.close()
        stopped = bool(read_job(job).get("cancel"))
        update_job(job, state="cancelled" if stopped else "passed" if code == 0 else "failed", exit=code,
                   finished=now())


def follow_there(job: str, offset: int) -> int:
    """Prints the job's log from the offset as it grows, then what came of the job."""
    out = sys.stdout.buffer
    last = b"\n"
    try:
        with (folder_there(job) / "log").open("rb") as log:
            log.seek(offset)
            while True:
                chunk = log.read(1 << 16)
                if not chunk:
                    if current(job)["state"] not in FINAL:
                        time.sleep(0.5)
                        continue
                    chunk = log.read()
                    if not chunk:
                        break
                out.write(chunk)
                out.flush()
                last = chunk[-1:]
        if last != b"\n":
            out.write(b"\n")
        emit(outcome(job))
    except BrokenPipeError:
        pass
    return 0


def start_there(argv: list[str]) -> int:
    job, kind, commit, *rest = argv
    split = rest.index("--")
    flags, command = rest[:split], rest[split + 1:]
    detach = "--detach" in flags
    options = dict(flag[2:].split("=", 1) for flag in flags if "=" in flag)
    folder = folder_there(job)
    folder.mkdir(parents=True)
    (folder / "log").touch()
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    found = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout
    update_job(job, id=job, kind=kind, commit=commit, command=command, size=options.get("size", "long"),
               source=options.get("from", ""), state="queued", queued=now(), macos=macos, xcode=xcode(found))
    # The supervisor, detached from this connection: a session of its own, whose parent exits at once.
    if os.fork() == 0:
        try:
            os.setsid()
            if os.fork() > 0:
                os._exit(0)
            null = os.open(os.devnull, os.O_RDWR)
            errors = os.open(folder / "supervisor.log", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            os.dup2(null, 0)
            os.dup2(errors, 1)
            os.dup2(errors, 2)
            supervise(job)
        except BaseException:
            traceback.print_exc()
            update_job(job, state="failed", finished=now())
        finally:
            os._exit(0)
    os.wait()
    clone = Path.home() / CLONE_THERE
    kept = sorted(path for path in folder.parent.iterdir() if path.is_dir() and JOB_ID.fullmatch(path.name))
    for old in kept[:-KEPT_JOBS]:
        if read_job(old.name)["state"] in FINAL:
            shutil.rmtree(old, ignore_errors=True)
            subprocess.run(["git", "update-ref", "-d", f"refs/build-mac/{old.name}"], cwd=clone,
                           capture_output=True)
    if detach:
        emit(current(job))
        return 0
    return follow_there(job, 0)


def cancel_there(job: str) -> int:
    state = update_job(job, cancel=now())
    if state["state"] == "queued" and state.get("supervisor"):
        try:
            os.kill(state["supervisor"], signal.SIGTERM)
        except ProcessLookupError:
            pass
        update_job(job, state="cancelled", finished=now())
    elif state["state"] == "running" and state.get("pid"):
        # Ctrl-C first, which the push gate stops at as it would here, then harder.
        for sent, grace in ((signal.SIGINT, 60), (signal.SIGTERM, 20), (signal.SIGKILL, 5)):
            try:
                os.killpg(state["pid"], sent)
            except ProcessLookupError:
                break
            deadline = time.monotonic() + grace
            while current(job)["state"] not in FINAL and time.monotonic() < deadline:
                time.sleep(0.5)
            if current(job)["state"] in FINAL:
                break
    emit(outcome(job))
    return 0


def status_there() -> int:
    def output(*command: str) -> str:
        return subprocess.run(command, capture_output=True, text=True).stdout

    try:
        gpus = json.loads(output("system_profiler", "-json", "SPDisplaysDataType"))["SPDisplaysDataType"]
    except (ValueError, KeyError):
        gpus = []
    screens = []
    for screen in (screen for gpu in gpus for screen in gpu.get("spdisplays_ndrvs", [])):
        pixels = re.match(r"(\d+)", screen.get("_spdisplays_pixels", ""))
        looks = screen.get("_spdisplays_resolution", "")
        points = re.match(r"(\d+)", looks)
        screens.append({"name": screen.get("_name", "?"), "looks": looks,
                        "hidpi": bool(pixels and points and int(pixels.group(1)) > int(points.group(1))),
                        "main": screen.get("spdisplays_main") == "spdisplays_yes"})
    sleep = re.search(r"SleepDisabled\s+(\d)", output("pmset", "-g"))
    clone = Path.home() / CLONE_THERE
    gate = clone.parent / f"{clone.name}-push-gate"
    folders = sorted((path for path in (Path.home() / JOBS_THERE).glob("*")
                      if path.is_dir() and JOB_ID.fullmatch(path.name)), reverse=True)
    emit({
        "gpu": f"{gpus[0].get('_name')} ({gpus[0].get('sppci_cores')} GPU cores)" if gpus else "no GPU listed",
        "macos": output("sw_vers", "-productVersion").strip(),
        "xcode": xcode(output("xcodebuild", "-version")),
        "load": os.getloadavg()[0],
        "cores": os.cpu_count(),
        "free_gb": shutil.disk_usage(Path.home() / BASE_THERE).free / 1e9,
        "sleep_disabled": sleep.group(1) if sleep else None,
        "screens": screens,
        "clone": output("git", "-C", str(clone), "log", "-1", "--format=%h %s").strip()[:90],
        "samples": samples(gate if (gate / "tests/fixtures").is_dir() else clone),
        "models": models(),
        "jobs": [current(path.name) for path in folders[:KEPT_JOBS]],
    })
    return 0


def pack_there(run: str) -> int:
    """A regression run's folder as a tar stream, leaving out what each run makes again."""
    base = Path(run)
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as archive:
        for folder, folders, files in os.walk(base):
            relative = Path(folder).relative_to(base)
            if not relative.parts or (len(relative.parts) == 1 and relative.parts[0].startswith("attempt-")):
                folders[:] = [name for name in folders if name not in LEFT_THERE]
            for name in sorted(files):
                archive.add(Path(folder) / name, arcname=str(relative / name))
    return 0


def test_there(argv: list[str]) -> int:
    """A test job's tests, in its lane's worktree (the folder it runs in), with the lane's DerivedData."""
    parser = argparse.ArgumentParser(prog="build-mac.py _test")
    parser.add_argument("job")
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--skip", action="append", default=[])
    args = parser.parse_args(argv)
    root = Path.cwd()
    return run_tests(root, args, root / "build/DerivedData", folder_there(args.job), generate=True)


THERE = {
    "_start": start_there,
    "_follow": lambda argv: follow_there(argv[0], int(argv[1])),
    "_cancel": lambda argv: cancel_there(argv[0]),
    "_status": lambda argv: status_there(),
    "_pack": lambda argv: pack_there(argv[0]),
    "_test": test_there,
}


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in THERE:
        mode, argv = sys.argv[1], sys.argv[2:]
        if mode in ("_follow", "_cancel") and not (folder_there(argv[0]) / "job.json").exists():
            emit({"id": argv[0], "state": "unknown"})
            return 1
        return THERE[mode](argv)
    parser = argparse.ArgumentParser(description="Builds and tests on the build Mac, over SSH (ARC-15).")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="whether the build Mac answers, its versions, what it's running")
    testing = commands.add_parser("test", help="xcodebuild test for a scheme on the working tree as it is, in a "
                                               "lane there or, failing that, here")
    testing.add_argument("--scheme", required=True, help="the scheme (Redlamp-Workspace for every suite)")
    testing.add_argument("--only", action="append", default=[], metavar="TARGET[/SUITE[/TEST]]",
                         help="only these tests, as -only-testing names them (repeated for more): a short job")
    testing.add_argument("--skip", action="append", default=[], metavar="TARGET[/SUITE[/TEST]]",
                         help="not these tests, as -skip-testing names them (repeated for more)")
    place = testing.add_mutually_exclusive_group()
    place.add_argument("--there", action="store_true", help="wait for the build Mac rather than test here")
    place.add_argument("--here", action="store_true", help="test here, without trying the build Mac")
    testing.add_argument("--detach", action="store_true", help="start it there and return; attach follows it")
    checking = commands.add_parser("gate", help="the push gate on a commit, there or, failing that, here")
    checking.add_argument("commit", nargs="?", default="HEAD", help="the commit to check (HEAD by default)")
    level = checking.add_mutually_exclusive_group()
    level.add_argument("--suite", action="store_true", help="the whole test suite, not only the reference tests")
    level.add_argument("--full", action="store_true", help="the whole suite and CI's Release builds")
    place = checking.add_mutually_exclusive_group()
    place.add_argument("--there", action="store_true",
                       help="wait for the build Mac rather than check here, and check there what passed here")
    place.add_argument("--here", action="store_true", help="check here, without trying the build Mac")
    checking.add_argument("--detach", action="store_true", help="start it there and return; attach follows it")
    regression = commands.add_parser("e2e", help="the regression suite on the working tree as it is, there or, "
                                                 "failing that, here, passing scripts/e2e.py the arguments after --")
    place = regression.add_mutually_exclusive_group()
    place.add_argument("--there", action="store_true", help="wait for the build Mac rather than run it here")
    place.add_argument("--here", action="store_true", help="run it here, without trying the build Mac")
    regression.add_argument("--detach", action="store_true", help="start it there and return; attach follows it")
    releasing = commands.add_parser("release-checks", help="the regression suite's release tier with focus, then "
                                                           "every test suite, on this checkout's commit")
    place = releasing.add_mutually_exclusive_group()
    place.add_argument("--there", action="store_true", help="wait for the build Mac rather than run them here")
    place.add_argument("--here", action="store_true", help="run them here, without trying the build Mac")
    following = commands.add_parser("attach", help="follow a job there again")
    following.add_argument("job", nargs="?", help="the job (the one running there by default)")
    stopping = commands.add_parser("cancel", help="stop a job there")
    stopping.add_argument("job", nargs="?", help="the job (the one running there by default)")
    commands.add_parser("models", help="copy this Mac's models to the build Mac where it lacks them")
    commands.add_parser("setup", help="scripts/build-mac/setup.sh there, with this Mac's versions, passing it "
                                      "its options (--gate, --no-settings, --no-fixtures)")
    args, options = parser.parse_known_args()
    if options and args.command not in ("setup", "e2e"):
        parser.error(f"unrecognized arguments: {' '.join(options)}")
    args.options = options[1:] if args.command == "e2e" and options[:1] == ["--"] else options
    commands_by_name = {"status": status, "test": test, "gate": gate, "e2e": e2e, "release-checks": release_checks,
                        "attach": attach, "cancel": cancel, "models": copy_models, "setup": setup}
    try:
        return commands_by_name[args.command](args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
