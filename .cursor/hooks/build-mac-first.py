#!/usr/bin/env python3
"""Before an agent's shell command: builds and test suites go to the build Mac first (ARC-15).

While the build Mac answers, this refuses xcodebuild test, the push gate and the regression suite
run directly, and gives the agent the scripts/build-mac.py line that runs the same there, and here by
itself when the build Mac stops answering. When the build Mac doesn't answer, the command runs as
it is, and so does a run that records references into the checkout or that build-mac.py keeps here.
.cursor/hooks.json runs it; it reads Cursor's JSON on stdin:

    echo '{"command": "xcodebuild test -scheme RedlampEngine"}' | .cursor/hooks/build-mac-first.py
"""

from __future__ import annotations

import json
import os
import re
import shlex
import socket
import subprocess
import sys
from pathlib import Path

HOST = os.environ.get("REDLAMP_BUILD_MAC", "build-mac")
MENTIONS = re.compile(r"xcodebuild|push-gate\.py|e2e\.py")
OPERATORS = "();<>|&\n"
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_]\w*)\1")
# Words that run the word after them: mise exec -- xcodebuild, python3 scripts/e2e.py, timeout 600 xcodebuild.
RUNNERS = {"python", "python3", "exec", "env", "time", "nice", "caffeinate", "mise", "xcrun", "--", "command",
           "timeout", "gtimeout"}
# timeout's durations (600, 10m, -k 5) and other runners' counts (nice -n 10).
DURATION = re.compile(r"\d+(?:\.\d+)?[smhd]?")
SHELLS = {"bash", "sh", "zsh"}
# Recording references writes them into the checkout the tests run in, so such a run stays here.
RECORDING = re.compile(r"(?:TEST_RUNNER_)?REDLAMP_(?:RECORD|UPDATE)_\w*=")
# scripts/build-mac.py's E2E_HERE: e2e.py's options that keep it on this Mac.
E2E_HERE = ("--passing-report", "--blackbox", "--app", "--replay", "--out", "--record", "-h", "--help")


def without_heredocs(text: str) -> str:
    """The command without the bodies of its here-documents, which are text rather than commands."""
    kept, end = [], None
    for line in text.split("\n"):
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        kept.append(line)
        found = HEREDOC.search(line)
        end = found.group(2) if found else None
    return "\n".join(kept)


def leads(words: list[str], index: int) -> bool:
    """Whether the word at index can come before the program a command runs: a runner, an option, an assignment,
    a duration, or the signal after timeout's -s (timeout -s KILL 600)."""
    word = words[index]
    return (Path(word).name in RUNNERS or word.startswith("-") or "=" in word or bool(DURATION.fullmatch(word))
            or (index > 0 and words[index - 1] in ("-s", "--signal")))


def commands(text: str, depth: int = 0) -> list[list[str]]:
    """The simple commands in a shell line as their words, with those given to a shell or to ssh to run."""
    lexer = shlex.shlex(without_heredocs(text), posix=True, punctuation_chars=OPERATORS)
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    try:
        words = list(lexer)
    except ValueError:
        words = text.split()
    found, current = [], []
    for word in [*words, ";"]:
        if word and all(character in OPERATORS for character in word):
            # The descriptor of a redirection (2>&1) isn't an argument.
            if current and current[-1].isdigit() and word[0] in "<>":
                current.pop()
            if current:
                found.append(current)
            current = []
        else:
            current.append(word)
    inner = []
    for words in found:
        start = next((index for index in range(len(words)) if not leads(words, index)), 0)
        name = Path(words[start]).name
        for index, word in enumerate(words[start + 1:], start + 1):
            given = (name in SHELLS and words[index - 1] in ("-c", "-lc")) or (name == "ssh" and " " in word)
            if depth < 2 and given and MENTIONS.search(word):
                inner += commands(word, depth + 1)
    return found + inner


def program(words: list[str], name: str) -> int | None:
    """Where the command runs the program, rather than naming it as another program's argument."""
    for index, word in enumerate(words):
        if Path(word).name == name and all(leads(words, before) for before in range(index)):
            return index
    return None


def xcodebuild_test(words: list[str]) -> str | None:
    """build-mac.py's line for an xcodebuild test of Redlamp's workspace on macOS, if this is one."""
    index = program(words, "xcodebuild")
    if index is None or any(RECORDING.match(word) for word in words[:index]):
        return None
    args = words[index + 1:]
    if not {"test", "test-without-building"} & set(args):
        return None
    given, tests = {}, {"only": [], "skip": []}
    for position, word in enumerate(args):
        following = args[position + 1] if position + 1 < len(args) else ""
        if word in ("-workspace", "-project", "-scheme", "-destination", "-testPlan", "-xctestrun"):
            given[word] = following
        for flag, kind in (("-only-testing", "only"), ("-skip-testing", "skip")):
            if word.startswith(f"{flag}:"):
                tests[kind].append(word.split(":", 1)[1])
            elif word == flag and following:
                tests[kind].append(following)
    workspace = given.get("-workspace")
    if {"-project", "-testPlan", "-xctestrun"} & set(given) or (workspace and Path(workspace).name != "Redlamp.xcworkspace"):
        return None
    if "macOS" not in given.get("-destination", "platform=macOS"):
        return None
    runner = [shlex.quote(word) for word in words[:index] if word.startswith("TEST_RUNNER_") and "=" in word]
    line = [*runner, "scripts/build-mac.py", "test", "--scheme", shlex.quote(given["-scheme"]) if given.get("-scheme")
            else "<Scheme>"]
    for kind in ("only", "skip"):
        line += [part for name in tests[kind] for part in (f"--{kind}", shlex.quote(name))]
    return " ".join(line)


def push_gate(words: list[str]) -> str | None:
    """build-mac.py's line for the push gate run by hand, if this is one."""
    index = program(words, "push-gate.py")
    args = words[index + 1:] if index is not None else []
    if index is None or {"--hook", "-h", "--help"} & set(args):
        return None
    return shlex.join(["scripts/build-mac.py", "gate", *args])


def regression(words: list[str]) -> str | None:
    """build-mac.py's line for the regression suite, if this runs it and build-mac.py would send it there."""
    index = program(words, "e2e.py")
    if index is None:
        return None
    args = words[index + 1:]
    for position, word in enumerate(args):
        if word.split("=")[0] in E2E_HERE:
            return None
        if word == "--tier=performance" or (word == "--tier" and args[position + 1:position + 2] == ["performance"]):
            return None
    return shlex.join(["scripts/build-mac.py", "e2e", *(["--", *args] if args else [])])


def endpoints() -> list[tuple[str, int]]:
    """Where ssh connects to the build Mac: through the sandbox relay when it's set up, and directly."""
    found = []
    for relayed in (True, False):
        env = dict(os.environ)
        if relayed:
            env.setdefault("X2P_AGENT_PROXY_ADDRESS", "build-mac-first")
        else:
            env.pop("X2P_AGENT_PROXY_ADDRESS", None)
        try:
            config = subprocess.run(["ssh", "-G", HOST], env=env, capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        host, port = re.search(r"^hostname (\S+)$", config, re.M), re.search(r"^port (\d+)$", config, re.M)
        if host and port and (host.group(1), int(port.group(1))) not in found:
            found.append((host.group(1), int(port.group(1))))
    return found


def answers() -> bool:
    """Whether the build Mac's SSH server answers; the relay gives it 10 s to."""
    for host, port in endpoints():
        try:
            with socket.create_connection((host, port), timeout=12) as connection:
                connection.settimeout(12)
                if connection.recv(64).startswith(b"SSH-"):
                    return True
        except OSError:
            continue
    return False


def main() -> int:
    try:
        command = json.load(sys.stdin).get("command") or ""
    except ValueError:
        command = ""
    lines = []
    if MENTIONS.search(command):
        for words in commands(command):
            for check in (xcodebuild_test, push_gate, regression):
                line = check(words)
                if line and line not in lines:
                    lines.append(line)
    if not lines or not answers():
        print(json.dumps({"permission": "allow"}))
        return 0
    named = " and ".join(f"`{line}`" for line in lines)
    print(json.dumps({
        "permission": "deny",
        "user_message": f"The build Mac answers, so the agent was asked to run {named} instead.",
        "agent_message": (
            f"The build Mac answers, so builds and test suites run there first, and here only when it doesn't "
            f"(AGENTS.md, Build and test). Run {named} instead. It runs the same on your working tree, "
            "uncommitted and new files included, in a lane of its own on the build Mac, shows the failures, "
            "errors and each bundle's result, and keeps the whole log and the results in build/build-mac/<job>/; "
            "when the build Mac stops answering it runs here by itself. Add --here (before -- for e2e) only "
            "when the run needs this Mac; a run that records references runs here by itself."
        ),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
