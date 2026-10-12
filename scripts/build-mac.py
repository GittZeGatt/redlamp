#!/usr/bin/env python3
"""The build Mac: heavy checks run on the owner's MacBook Pro, over SSH from this Mac (ARC-15).

Run from the owner's own Terminal. Agents' shells can't reach the local network, so for them a
check runs here, as it would without the build Mac:

    scripts/build-mac.py status               # whether it answers, its versions, what it's running
    scripts/build-mac.py gate [<commit>]      # the push gate on a commit (HEAD by default)
    scripts/build-mac.py gate --suite         # the whole test suite, as CI runs it
    scripts/build-mac.py gate --full          # and CI's Release builds
    scripts/build-mac.py attach [<job>]       # follow a job again (the one running by default)
    scripts/build-mac.py cancel [<job>]       # stop a job there (the one running by default)
    scripts/build-mac.py setup [<options>]    # scripts/build-mac/setup.sh there, with this Mac's versions

A job sends its commit with git push to the build Mac's clone (~/src/build-mac/redlamp), under
refs/build-mac/, which the pre-push hook lets through, and runs in the clone in a process of its
own, so it carries on if the connection drops. Jobs run there one at a time, under caffeinate.
The command prints what the job prints; Ctrl-C cancels the job, and --detach leaves it running for
attach to follow. Its log comes back into build/build-mac/<job>/, with the push gate's own log, and
a gate's pass into build/push-gate/passed, so a push of that commit, by the owner or an agent,
goes straight through.

When the build Mac doesn't answer, or its Xcode isn't this Mac's, gate says so in one line and runs
the same check here; a different macOS is reported and allowed, since only Xcode has to match.
--there waits for the build Mac instead, and checks a commit there even when it passed here; --here
doesn't try it.

The build Mac is the host build-mac in ~/.ssh/config; REDLAMP_BUILD_MAC names another. Under its
~/src/build-mac: the clone, the push gate's worktree beside it (redlamp-push-gate), and jobs/, with
a folder per job (job.json and its log) and a copy of this script, sent with each command, which
runs its side of them.
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
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOST = os.environ.get("REDLAMP_BUILD_MAC", "build-mac")
# Under the build Mac's home folder.
BASE_THERE = "src/build-mac"
CLONE_THERE = f"{BASE_THERE}/redlamp"
JOBS_THERE = f"{BASE_THERE}/jobs"
# An answer within 3 seconds or none; a connection that stops answering for a minute has dropped.
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "ServerAliveInterval=15",
       "-o", "ServerAliveCountMax=4"]
# The push gate's levels, each covering the ones before it (scripts/push-gate.py).
LEVELS = ("checks", "reference", "suite", "full")
FINAL = ("passed", "failed", "cancelled", "lost")
JOB_ID = re.compile(r"\d{8}-\d{6}-[a-z]+-[0-9a-f]{7}")
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


def samples(root: Path) -> list[str]:
    """The sample raws a checkout's tests read, as paths under tests/fixtures (what the push gate copies)."""
    found = []
    for folder in ("raw", "cameras", "shoots"):
        base = root / "tests/fixtures" / folder
        for path in sorted(base.rglob("*")) if base.is_dir() else []:
            if path.is_file() and not path.name.startswith(".") and path.suffix not in (".part", ".redlamp"):
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


def send(commit: str, job: str) -> None:
    """Puts the commit in the build Mac's clone, under refs/build-mac/, which the pre-push hook lets through."""
    env = {**ENV, "GIT_SSH_COMMAND": shlex.join(SSH)}
    result = subprocess.run(["git", "push", "--quiet", f"{HOST}:{CLONE_THERE}", f"{commit}:refs/build-mac/{job}"],
                            cwd=ROOT, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"build-mac: sending {commit[:7]} to the build Mac failed: {result.stderr.strip()}")


def start(kind: str, commit: str, command: list[str], detach: bool) -> int:
    job = f"{dt.datetime.now():%Y%m%d-%H%M%S}-{kind}-{commit[:7]}"
    say(f"On the build Mac, as {job}")
    send(commit, job)
    mode = ["_start", job, kind, commit, *(["--detach"] if detach else []), "--", *command]
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


def fetch(path: str, target: Path) -> None:
    with target.open("wb") as out:
        subprocess.run([*SSH, HOST, f"cat {shlex.quote(path)}"], stdout=out, stderr=subprocess.DEVNULL, env=ENV)


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
    gate_log = re.search(r"Log: (/\S+\.log)", (folder / "log").read_text(errors="replace"))
    if gate_log:
        fetch(gate_log.group(1), folder / "push-gate.log")
    if state.get("passed"):
        remember(state)
    ran = between(state.get("started"), state.get("finished"))
    waited = between(state.get("queued"), state.get("started"))
    spent = f" in {took(ran)}" if ran is not None else ""
    queued = f", after {took(waited)} waiting for the job before it" if waited and waited >= 5 else ""
    say(f"{job}: {state['state']}{spent} on the build Mac{queued}; its logs are in {shown(folder)}")
    kept = sorted(path for path in folder.parent.iterdir() if path.is_dir() and JOB_ID.fullmatch(path.name))
    for old in kept[:-KEPT_JOBS]:
        shutil.rmtree(old, ignore_errors=True)
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


def gate(args: argparse.Namespace) -> int:
    commit = git("rev-parse", "--verify", f"{args.commit}^{{commit}}")
    flags = ["--full"] if args.full else ["--suite"] if args.suite else []
    asked = "full" if args.full else "suite" if args.suite else "reference"
    record = covered(git("rev-parse", f"{commit}^{{tree}}"), asked)
    there = record is not None and record.get("machine") == "build-mac"
    if record and (there or not args.there):
        on = " on the build Mac" if there else ""
        say(f"Its files passed the gate ({record['level']}){on} on {record['at'][:16].replace('T', ' at ')} "
            f"({record['commit'][:7]}); nothing to check")
        return 0
    if record:
        say(f"Its files passed the gate here ({record['level']}); --there checks them on the build Mac too")
    if where(args) is None:
        command = [str(ROOT / "scripts/push-gate.py"), commit, *flags]
        os.execve(command[0], command, ENV)
    return start("gate", commit, ["scripts/push-gate.py", commit, *flags], args.detach)


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
        print(f"    {name}: {'; '.join(parts)}; the tests that need them skip where they're missing")
    for job in info["jobs"][:8]:
        ran = between(job.get("started"), job.get("finished") or now())
        spent = f" {'for' if job['state'] == 'running' else 'in'} {took(ran)}" if ran is not None else ""
        print(f"    {job['id']}: {job['state']}{spent}")
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


def supervise(job: str) -> None:
    """Runs the job in the clone once the job before it has finished, and records what came of it."""
    state = update_job(job, supervisor=os.getpid())
    clone = Path.home() / CLONE_THERE
    env = environment_there()
    with (folder_there(job) / "log").open("ab", buffering=0) as log:
        queue = (Path.home() / JOBS_THERE / "lock").open("a+")
        try:
            fcntl.flock(queue, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            queue.seek(0)
            log.write(f"==> Waiting for {queue.read().strip() or 'the job before it'}\n".encode())
            fcntl.flock(queue, fcntl.LOCK_EX)
        queue.seek(0)
        queue.truncate()
        queue.write(job)
        queue.flush()
        if read_job(job).get("cancel"):
            update_job(job, state="cancelled", finished=now())
            return
        update_job(job, state="running", started=now())
        # origin/main as GitHub has it now, which the push gate measures the commit's changes from.
        subprocess.run(["git", "fetch", "--quiet", "origin"], cwd=clone, env=env, stdin=subprocess.DEVNULL,
                       stdout=log, stderr=subprocess.STDOUT)
        moved = subprocess.run(["git", "checkout", "--quiet", "--detach", state["commit"]], cwd=clone, env=env,
                               stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        if moved.returncode != 0:
            log.write(f"==> The clone couldn't be put at {state['commit'][:7]}\n".encode())
            update_job(job, state="failed", exit=moved.returncode, finished=now())
            return
        awake = subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # A process group of its own, so that cancelling stops what it started too.
        process = subprocess.Popen(state["command"], cwd=clone, env=env, stdin=subprocess.DEVNULL, stdout=log,
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
    detach, command = "--detach" in rest[:split], rest[split + 1:]
    folder = folder_there(job)
    folder.mkdir(parents=True)
    (folder / "log").touch()
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    found = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout
    update_job(job, id=job, kind=kind, commit=commit, command=command, state="queued", queued=now(),
               macos=macos, xcode=xcode(found))
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


THERE = {
    "_start": start_there,
    "_follow": lambda argv: follow_there(argv[0], int(argv[1])),
    "_cancel": lambda argv: cancel_there(argv[0]),
    "_status": lambda argv: status_there(),
}


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in THERE:
        mode, argv = sys.argv[1], sys.argv[2:]
        if mode in ("_follow", "_cancel") and not (folder_there(argv[0]) / "job.json").exists():
            emit({"id": argv[0], "state": "unknown"})
            return 1
        return THERE[mode](argv)
    parser = argparse.ArgumentParser(description="Heavy checks on the build Mac, over SSH (ARC-15).")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="whether the build Mac answers, its versions, what it's running")
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
    following = commands.add_parser("attach", help="follow a job there again")
    following.add_argument("job", nargs="?", help="the job (the one running there by default)")
    stopping = commands.add_parser("cancel", help="stop a job there")
    stopping.add_argument("job", nargs="?", help="the job (the one running there by default)")
    commands.add_parser("setup", help="scripts/build-mac/setup.sh there, with this Mac's versions, passing it "
                                      "its options (--gate, --no-settings, --no-fixtures)")
    args, options = parser.parse_known_args()
    if options and args.command != "setup":
        parser.error(f"unrecognized arguments: {' '.join(options)}")
    args.options = options
    try:
        return {"status": status, "gate": gate, "attach": attach, "cancel": cancel, "setup": setup}[args.command](args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
