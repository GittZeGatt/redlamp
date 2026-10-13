#!/usr/bin/env python3
"""The sandbox relay: agents in Cursor's sandbox reach a Mac on the local network over SSH (ARC-15).

Agents' shells run in a sandbox that refuses the local network but lets them reach this Mac's own
loopback, so on their own they can't reach the build Mac (scripts/build-mac.py). The relay runs
outside the sandbox, listens on 127.0.0.1 and passes each connection on to one host's SSH port.
SSH stays encrypted from the agent's ssh to that host, and is checked against the key this Mac
already trusts for it, so the relay only passes bytes along. It listens on the loopback only, and
forwards to that one host and port only.

In the owner's own Terminal, once:

    scripts/sandbox-relay.py install            # start it at each login, and send build-mac to it
    scripts/sandbox-relay.py install --daemon   # the same, as a system daemon (asks for a password)
    scripts/sandbox-relay.py uninstall          # stop it, and take out what install put in

Anywhere, an agent's shell included:

    scripts/sandbox-relay.py status             # whether it runs, and the host answers through it
    scripts/sandbox-relay.py run                # relay in the foreground, as the service does

install copies this script to ~/Library/Application Support/sandbox-relay, where a LaunchAgent runs
it at each login and keeps it running, logging to ~/Library/Logs/sandbox-relay; and it puts a block
in ~/.ssh/config that sends the host to the relay only in a shell with X2P_AGENT_PROXY_ADDRESS set,
as every shell in Cursor's sandbox has. So in the sandbox `ssh build-mac`, `git push build-mac:…`
and scripts/build-mac.py go through the relay, unchanged, while in the owner's Terminal they go
straight to the host. When the relay isn't running, ssh can't connect, and build-mac.py runs its
checks here.

macOS's Local Network privacy can keep a LaunchAgent off the local network. install says when it
does, and --daemon installs the relay as a system LaunchDaemon instead, which it doesn't apply to.

--host names the host in ~/.ssh/config (build-mac by default) and --port the relay's port on
127.0.0.1 (2223); a second host needs a port of its own.
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOST = "build-mac"
PORT = 2223
# Set in every shell Cursor's sandbox starts, and in none outside it.
SANDBOX = "X2P_AGENT_PROXY_ADDRESS"
SUPPORT = Path.home() / "Library/Application Support/sandbox-relay"
LOGS = Path.home() / "Library/Logs/sandbox-relay"
SSH_CONFIG = Path.home() / ".ssh/config"
LOOPBACK = ("127.0.0.1", "localhost", "::1")
# Xcode's, which a Homebrew upgrade doesn't move; the relay needs only Python 3.9's standard library.
PYTHON = "/usr/bin/python3" if Path("/usr/bin/python3").exists() else sys.executable
# SSH ends both directions together, so once one has ended the other follows unless its far end is gone.
GRACE = 30


def say(message: str) -> None:
    print(f"==> {message}", flush=True)


def log(message: str) -> None:
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {message}", flush=True)


def sandboxed() -> bool:
    return bool(os.environ.get(SANDBOX))


def outside(command: str) -> None:
    if sandboxed():
        sys.exit(f"sandbox-relay: {command} runs in your own Terminal: the relay has to start outside Cursor's "
                 "sandbox to reach the local network")


def label(host: str) -> str:
    return f"local.sandbox-relay.{host}"


def plist_path(host: str, kind: str) -> Path:
    folder = Path.home() / "Library/LaunchAgents" if kind == "agent" else Path("/Library/LaunchDaemons")
    return folder / f"{label(host)}.plist"


def service(kind: str) -> tuple[list[str], str]:
    """What launchctl runs under for this kind of service, and the service's domain."""
    return ([], f"gui/{os.getuid()}") if kind == "agent" else (["sudo"], "system")


def kind_name(kind: str) -> str:
    return "a LaunchAgent" if kind == "agent" else "a system LaunchDaemon"


def joined(to: tuple[str, int]) -> str:
    return f"[{to[0]}]:{to[1]}" if ":" in to[0] else f"{to[0]}:{to[1]}"


def address(text: str) -> tuple[str, int]:
    """HOST:PORT, with an IPv6 address in brackets."""
    found = re.fullmatch(r"\[(.+)\]:(\d+)|([^:]+):(\d+)", text)
    if not found:
        raise argparse.ArgumentTypeError(f"{text} isn't HOST:PORT")
    return found.group(1) or found.group(3), int(found.group(2) or found.group(4))


# ---------------------------------------------------------------- ssh's view of the host


def resolved(host: str, sandbox: bool = False) -> dict[str, str]:
    """What ssh makes of the host in the sandbox, or out of it, where the relay's block doesn't apply."""
    env = {key: value for key, value in os.environ.items() if key != SANDBOX}
    if sandbox:
        env[SANDBOX] = "1"
    result = subprocess.run(["ssh", "-G", host], capture_output=True, text=True, env=env)
    if result.returncode != 0:
        sys.exit(f"sandbox-relay: ssh -G {host}: {result.stderr.strip()}")
    return dict(line.split(" ", 1) for line in result.stdout.splitlines() if " " in line)


def destination(host: str) -> tuple[str, int, str]:
    """The host's own address and SSH port, and the name known_hosts keeps its key under."""
    found = resolved(host)
    name, port = found["hostname"], int(found["port"])
    return name, port, found.get("hostkeyalias") or (name if port == 22 else f"[{name}]:{port}")


def markers(host: str) -> tuple[str, str]:
    return f"# >>> sandbox relay for {host} (sandbox-relay.py) >>>", f"# <<< sandbox relay for {host} <<<"


def without_block(text: str, host: str) -> str:
    begin, end = markers(host)
    lines = text.splitlines()
    if begin not in lines:
        return text
    start = lines.index(begin)
    if end not in lines[start:]:
        sys.exit(f"sandbox-relay: {SSH_CONFIG} has the relay's block for {host} without its last line; take it "
                 "out by hand")
    stop = lines.index(end, start) + 1
    if stop < len(lines) and not lines[stop].strip():
        stop += 1
    kept = lines[:start] + lines[stop:]
    return "\n".join(kept) + "\n" if kept else ""


def with_block(text: str, host: str, port: int, alias: str) -> str:
    begin, end = markers(host)
    lines = without_block(text, host).splitlines()
    # ssh takes each option from the first block that sets it, and options above the first Host or
    # Match apply to every host, so the block goes just before the first Host or Match.
    first = next((index for index, line in enumerate(lines) if re.match(r"\s*(host|match)[\s=]", line, re.I)),
                 len(lines))
    block = [begin, f'Match originalhost {host} exec "printenv {SANDBOX} >/dev/null"', "  HostName 127.0.0.1",
             f"  Port {port}", f"  HostKeyAlias {alias}", end]
    rest = [""] + lines[first:] if lines[first:] else []
    return "\n".join(lines[:first] + block + rest) + "\n"


def write_config(text: str) -> Path | None:
    """Writes ~/.ssh/config (through a symlink, if it is one), keeping the first version it replaced."""
    path = SSH_CONFIG.resolve()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = path.with_name(f"{path.name}.sandbox-relay.bak")
    if path.exists() and not backup.exists():
        shutil.copy2(path, backup)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    new = path.with_name(f"{path.name}.sandbox-relay.new")
    new.write_text(text)
    new.chmod(mode)
    new.replace(path)
    return backup if backup.exists() else None


# ---------------------------------------------------------------- the relay


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, counts: list[int], index: int) -> None:
    """Copies one direction until it ends, then ends it on the far side too."""
    try:
        while True:
            chunk = await reader.read(1 << 16)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
            counts[index] += len(chunk)
        if writer.can_write_eof():
            writer.write_eof()
    except OSError:
        writer.close()


async def relay(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, to: tuple[str, int]) -> None:
    started = time.monotonic()
    peer = writer.get_extra_info("peername")
    name = f"port {peer[1]}" if peer else "a connection"
    try:
        upstream = await asyncio.wait_for(asyncio.open_connection(*to, happy_eyeballs_delay=0.25), timeout=10)
    except (OSError, asyncio.TimeoutError) as error:
        log(f"{name}: {joined(to)} didn't answer: {str(error) or 'nothing in 10 s'}")
        writer.close()
        return
    counts = [0, 0]
    tasks = [asyncio.ensure_future(pipe(reader, upstream[1], counts, 0)),
             asyncio.ensure_future(pipe(upstream[0], writer, counts, 1))]
    _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    if pending:
        _, pending = await asyncio.wait(pending, timeout=GRACE)
    for task in pending:
        task.cancel()
    writer.close()
    upstream[1].close()
    log(f"{name}: {counts[0]} bytes to {to[0]}, {counts[1]} back, in {time.monotonic() - started:.1f} s")


async def serve(port: int, to: tuple[str, int]) -> None:
    server = await asyncio.start_server(lambda reader, writer: relay(reader, writer, to), "127.0.0.1", port)
    log(f"Relaying 127.0.0.1:{port} to {joined(to)}")
    async with server:
        await server.serve_forever()


# ---------------------------------------------------------------- checks


def listening(port: int, wait: float = 0) -> bool:
    deadline = time.monotonic() + wait
    while True:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            return True
        except OSError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.2)


def reachable(to: tuple[str, int]) -> str | None:
    """None when this process can connect to it, or else why it can't."""
    try:
        socket.create_connection(to, timeout=5).close()
        return None
    except OSError as error:
        return str(error) or type(error).__name__


def answers(host: str, port: int, alias: str) -> tuple[bool, str, float]:
    """Whether the host answers ssh through the relay, why not if it doesn't, and in how long."""
    started = time.monotonic()
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "HostName=127.0.0.1",
               "-o", f"Port={port}", "-o", f"HostKeyAlias={alias}", host, "true"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return False, "no answer in 30 s", time.monotonic() - started
    errors = result.stderr.strip().splitlines()
    why = errors[-1] if errors else f"ssh exited with {result.returncode}"
    return result.returncode == 0, why, time.monotonic() - started


def installed(host: str) -> tuple[str, int, str] | None:
    """How the relay for the host is installed: its kind, its port and where it relays to."""
    for kind in ("agent", "daemon"):
        try:
            arguments = plistlib.loads(plist_path(host, kind).read_bytes())["ProgramArguments"]
        except (OSError, ValueError, KeyError):
            continue
        options = dict(zip(arguments, arguments[1:]))
        return kind, int(options.get("--port", PORT)), options.get("--to", "?")
    return None


def last_line(path: Path) -> str:
    try:
        lines = path.read_text(errors="replace").strip().splitlines()
    except OSError:
        return "no log"
    return lines[-1] if lines else "nothing logged"


# ---------------------------------------------------------------- the service


def write_plist(host: str, kind: str, port: int, to: tuple[str, int], script: Path, logfile: Path) -> Path:
    plist = {
        "Label": label(host),
        "ProgramArguments": [PYTHON, str(script), "run", "--host", host, "--port", str(port), "--to", joined(to)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": str(logfile),
        "StandardErrorPath": str(logfile),
    }
    path = plist_path(host, kind)
    if kind == "agent":
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(plist))
        return path
    plist["UserName"] = getpass.getuser()
    with tempfile.NamedTemporaryFile(suffix=".plist") as file:
        file.write(plistlib.dumps(plist))
        file.flush()
        subprocess.run(["sudo", "install", "-m", "644", "-o", "root", "-g", "wheel", file.name, str(path)], check=True)
    return path


def load(host: str, kind: str, path: Path) -> None:
    prefix, domain = service(kind)
    subprocess.run([*prefix, "launchctl", "bootout", f"{domain}/{label(host)}"], capture_output=True)
    for _ in range(20):
        result = subprocess.run([*prefix, "launchctl", "bootstrap", domain, str(path)], capture_output=True, text=True)
        if result.returncode == 0:
            return
        # launchd refuses it for a moment while the instance before it is still going away.
        time.sleep(0.5)
    sys.exit(f"sandbox-relay: launchctl bootstrap {domain} {path}: {result.stderr.strip()}")


def unload(host: str, kind: str) -> None:
    prefix, domain = service(kind)
    subprocess.run([*prefix, "launchctl", "bootout", f"{domain}/{label(host)}"], capture_output=True)
    subprocess.run([*prefix, "rm", "-f", str(plist_path(host, kind))], check=True)


# ---------------------------------------------------------------- commands


def run(args: argparse.Namespace) -> int:
    to = args.to or destination(args.host)[:2]
    if to[0] in LOOPBACK and to[1] == args.port:
        sys.exit(f"sandbox-relay: 127.0.0.1:{args.port} would relay to itself")
    if sandboxed() and to[0] not in LOOPBACK:
        say(f"This shell is in Cursor's sandbox, which refuses the local network, so {to[0]} can't be reached from "
            "here: the relay runs outside it, as install sets it up")
    try:
        asyncio.run(serve(args.port, to))
    except OSError as error:
        sys.exit(f"sandbox-relay: can't listen on 127.0.0.1:{args.port}: {error}")
    return 0


def install(args: argparse.Namespace) -> int:
    outside("install")
    kind = "daemon" if args.daemon else "agent"
    name, port, alias = destination(args.host)
    try:
        socket.getaddrinfo(name, port)
    except OSError as error:
        sys.exit(f"sandbox-relay: ssh takes {args.host} to {name}, which doesn't resolve ({error}): give it a "
                 f"Host {args.host} block with its HostName in {SSH_CONFIG}")
    if kind == "daemon":
        say("Your password, for the LaunchDaemon in /Library/LaunchDaemons")
        subprocess.run(["sudo", "-v"], check=True)
    for other in ("agent", "daemon"):
        if other != kind and plist_path(args.host, other).exists():
            unload(args.host, other)
    SUPPORT.mkdir(parents=True, exist_ok=True)
    script = SUPPORT / "sandbox-relay.py"
    if Path(__file__).resolve() != script.resolve():
        shutil.copy2(Path(__file__).resolve(), script)
    LOGS.mkdir(parents=True, exist_ok=True)
    logfile = LOGS / f"{args.host}.log"
    logfile.touch()
    load(args.host, kind, write_plist(args.host, kind, args.port, (name, port), script, logfile))
    if not listening(args.port, wait=5):
        sys.exit(f"sandbox-relay: the relay didn't start; its log ({logfile}) says: {last_line(logfile)}")
    say(f"The relay runs as {kind_name(kind)} ({label(args.host)}), from 127.0.0.1:{args.port} to "
        f"{joined((name, port))}; its log is {logfile}")
    config = SSH_CONFIG.resolve()
    backup = write_config(with_block(config.read_text() if config.exists() else "", args.host, args.port, alias))
    kept = f" (the file as it was is {backup})" if backup else ""
    say(f"{SSH_CONFIG} sends {args.host} to the relay in Cursor's sandbox, and only there{kept}")
    ok, why, took = answers(args.host, args.port, alias)
    if ok:
        say(f"{args.host} answers through the relay ({took:.1f} s), so from the sandbox `ssh {args.host}` and "
            "scripts/build-mac.py reach it")
        return 0
    direct = reachable((name, port))
    if direct:
        say(f"{args.host} doesn't answer from this Mac either ({direct}); once it does, `{sys.argv[0]} status` "
            "checks again")
    elif kind == "agent":
        say(f"{args.host} answers from this Terminal but not through the relay ({last_line(logfile)}). macOS's Local "
            "Network privacy can keep a LaunchAgent off the local network: if macOS asked whether python3 may find "
            f"devices on your local network, allow it and run `{sys.argv[0]} status`; otherwise `{sys.argv[0]} "
            "install --daemon` installs the relay as a system LaunchDaemon, which it doesn't apply to")
    else:
        say(f"{args.host} answers from this Terminal but not through the relay: {why} ({last_line(logfile)})")
    return 1


def uninstall(args: argparse.Namespace) -> int:
    outside("uninstall")
    for kind in ("agent", "daemon"):
        if plist_path(args.host, kind).exists():
            unload(args.host, kind)
            say(f"Stopped the relay for {args.host} and removed {plist_path(args.host, kind)}")
    config = SSH_CONFIG.resolve()
    if config.exists() and markers(args.host)[0] in config.read_text().splitlines():
        write_config(without_block(config.read_text(), args.host))
        say(f"Took the relay's block for {args.host} out of {SSH_CONFIG}")
    others = [*(Path.home() / "Library/LaunchAgents").glob(f"{label('*')}.plist"),
              *Path("/Library/LaunchDaemons").glob(f"{label('*')}.plist")]
    if not others:
        shutil.rmtree(SUPPORT, ignore_errors=True)
    say(f"From the sandbox, {args.host} is out of reach again, and scripts/build-mac.py runs its checks here")
    return 0


def status(args: argparse.Namespace) -> int:
    found = installed(args.host)
    port = found[1] if found else args.port
    if found:
        say(f"The relay for {args.host} is installed as {kind_name(found[0])}, from 127.0.0.1:{port} to {found[2]}")
    else:
        say(f"The relay for {args.host} isn't installed: `{sys.argv[0]} install`, in your own Terminal, sets it up")
    via = resolved(args.host, sandbox=True)
    routed = via.get("hostname") == "127.0.0.1" and via.get("port") == str(port)
    where = "through the relay" if routed else f"to {via.get('hostname')}:{via.get('port')}, not through the relay"
    say(f"In Cursor's sandbox, ssh {args.host} goes {where}")
    if not listening(port):
        say(f"Nothing listens on 127.0.0.1:{port}, so {args.host} can't be reached through it")
        return 1
    ok, why, took = answers(args.host, port, destination(args.host)[2])
    if not ok:
        say(f"The relay runs, but {args.host} doesn't answer through it: {why}")
        return 1
    say(f"{args.host} answers through the relay ({took:.1f} s)")
    return 0 if routed else 1


def main() -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--host", default=HOST, help=f"the host in ~/.ssh/config ({HOST} by default)")
    common.add_argument("--port", type=int, default=PORT, help=f"the relay's port on 127.0.0.1 ({PORT} by default)")
    parser = argparse.ArgumentParser(description="A relay on 127.0.0.1 through which Cursor's sandbox reaches a "
                                                 "host on the local network over SSH (ARC-15).")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", parents=[common], help="whether the relay runs, and the host answers through it")
    installing = commands.add_parser("install", parents=[common], help="run the relay at each login, and send the "
                                     "host to it in the sandbox (in your own Terminal)")
    installing.add_argument("--daemon", action="store_true", help="as a system LaunchDaemon, which macOS's Local "
                            "Network privacy doesn't apply to (asks for your password)")
    commands.add_parser("uninstall", parents=[common], help="stop the relay, and take out what install put in (in "
                        "your own Terminal)")
    running = commands.add_parser("run", parents=[common], help="relay in the foreground, as the service does")
    running.add_argument("--to", type=address, help="HOST:PORT to relay to (the host's SSH, from ~/.ssh/config, by "
                         "default)")
    args = parser.parse_args()
    try:
        return {"status": status, "install": install, "uninstall": uninstall, "run": run}[args.command](args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
