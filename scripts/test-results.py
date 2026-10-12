#!/usr/bin/env python3
"""Test results from Xcode's result bundles, summarised and compared between runs (ARC-15).

    scripts/test-results.py summary <bundle.xcresult> [--out <file.json>]
    scripts/test-results.py compare <a> <b>

A summary lists each test case by its bundle and identifier, with its result (Passed, Failed,
Skipped or Expected Failure), its time and the message of a skip or a failure, and the Mac that ran
it. The push gate writes one beside its log for each run of the tests
(build/push-gate/logs/<log>.tests.json), and scripts/build-mac.py brings the build Mac's back with
a job's logs (build/build-mac/<job>/tests.json).

compare says how two runs differ: the tests only one of them ran, the results that differ, and
each bundle's count of tests and their time on both. It takes summaries, result bundles or the
regression suite's report.json, and exits 1 when the results differ.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

FORMAT = "app.redlamp.test-results"


def counts(tests: dict) -> dict:
    found: dict[str, int] = {}
    for entry in tests.values():
        found[entry["result"]] = found.get(entry["result"], 0) + 1
    return dict(sorted(found.items()))


def summarise(bundle: Path) -> dict:
    """The test cases in a result bundle, by bundle and identifier, with the Mac that ran them."""
    found = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle),
                            "--format", "json"], capture_output=True, text=True)
    if found.returncode != 0:
        sys.exit(f"test-results: {bundle}: {found.stderr.strip() or 'xcresulttool failed'}")
    data = json.loads(found.stdout)
    tests: dict[str, dict] = {}

    def walk(node: dict, bundle_name: str) -> None:
        kind = node.get("nodeType", "")
        if kind.endswith("test bundle"):
            bundle_name = node.get("name", "?")
        if kind != "Test Case":
            for child in node.get("children", []):
                walk(child, bundle_name)
            return
        children = node.get("children", [])
        entry = {"result": node.get("result", "?"), "seconds": round(node.get("durationInSeconds", 0.0), 4)}
        messages = [child.get("name", "") for child in children if child.get("nodeType") == "Failure Message"]
        if messages and entry["result"] != "Passed":
            entry["message"] = messages[0][:300]
        runs = sum(1 for child in children if child.get("nodeType") == "Arguments")
        if runs:
            entry["runs"] = runs
        tests[f"{bundle_name}/{node.get('nodeIdentifier') or node.get('name')}"] = entry

    for node in data.get("testNodes", []):
        walk(node, "?")
    device = (data.get("devices") or [{}])[0]
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    mac = ", ".join(part for part in (device.get("modelName"), chip, f"macOS {device.get('osVersion')}") if part)
    return {"format": FORMAT, "mac": mac, "counts": counts(tests), "tests": tests}


def load(path: Path) -> dict:
    """The summary of the run at `path`: a summary, a result bundle or a regression suite's report."""
    if path.suffix == ".xcresult":
        return summarise(path)
    data = json.loads(path.read_text())
    if data.get("format") == FORMAT:
        return data
    if data.get("format") == "app.redlamp.e2e-report":
        tests = {}
        for item in data.get("scenarios", []):
            entry = {"result": item["status"].capitalize(), "seconds": item.get("seconds") or 0}
            if item.get("message") and item["status"] != "passed":
                entry["message"] = item["message"][:300]
            tests[item["id"]] = entry
        return {"format": FORMAT, "mac": data.get("machine", "?"), "counts": counts(tests), "tests": tests}
    sys.exit(f"test-results: {path} isn't a summary, a result bundle or a regression suite's report")


def described(summary: dict) -> str:
    total = sum(summary["counts"].values())
    parts = ", ".join(f"{count:,} {result.lower()}" for result, count in summary["counts"].items())
    seconds = sum(entry.get("seconds", 0) for entry in summary["tests"].values())
    return f"{total:,} tests ({parts}), {seconds:,.0f} s of test time"


def group(test: str) -> str:
    """A test's bundle, or a scenario's tier."""
    return test.split("/")[0] if "/" in test else test.split(".")[0]


def compare(first: Path, second: Path) -> int:
    a, b = load(first), load(second)
    print(f"A: {a['mac']}: {described(a)} ({first})")
    print(f"B: {b['mac']}: {described(b)} ({second})")
    groups = sorted({group(test) for test in a["tests"]} | {group(test) for test in b["tests"]})
    width = max([len(name) for name in groups] + [6])
    print(f"\n{'Bundle':<{width}}  {'Tests A':>7}  {'Tests B':>7}  {'Time A':>8}  {'Time B':>8}")
    for name in groups:
        mine = [entry for test, entry in a["tests"].items() if group(test) == name]
        theirs = [entry for test, entry in b["tests"].items() if group(test) == name]
        time_a = sum(entry.get("seconds", 0) for entry in mine)
        time_b = sum(entry.get("seconds", 0) for entry in theirs)
        print(f"{name:<{width}}  {len(mine):>7,}  {len(theirs):>7,}  {time_a:>7,.1f}s  {time_b:>7,.1f}s")
    only_a = sorted(set(a["tests"]) - set(b["tests"]))
    only_b = sorted(set(b["tests"]) - set(a["tests"]))
    differ = sorted(test for test in set(a["tests"]) & set(b["tests"])
                    if a["tests"][test]["result"] != b["tests"][test]["result"])
    for title, tests, summary in (("Only in A", only_a, a), ("Only in B", only_b, b)):
        if tests:
            print(f"\n{title} ({len(tests)}):")
            for test in tests:
                print(f"  {test}: {summary['tests'][test]['result']}")
    if differ:
        print(f"\nResults that differ ({len(differ)}):")
        for test in differ:
            line = f"  {test}: {a['tests'][test]['result']} in A, {b['tests'][test]['result']} in B"
            notes = [f"{side}: {entry['message']}" for side, entry in (("A", a["tests"][test]), ("B", b["tests"][test]))
                     if entry.get("message")]
            print(line + (f" ({'; '.join(notes)})" if notes else ""))
    if not (only_a or only_b or differ):
        print("\nThe same tests, with the same results.")
        return 0
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    summary = commands.add_parser("summary", help="summarise a result bundle")
    summary.add_argument("bundle", type=Path)
    summary.add_argument("--out", type=Path, help="write the summary here and print its counts")
    comparing = commands.add_parser("compare", help="how two runs differ")
    comparing.add_argument("first", type=Path)
    comparing.add_argument("second", type=Path)
    args = parser.parse_args()
    if args.command == "compare":
        return compare(args.first, args.second)
    found = summarise(args.bundle)
    if not args.out:
        print(json.dumps(found, indent=1))
        return 0
    args.out.write_text(json.dumps(found, indent=1) + "\n")
    print(f"Tests: {described(found)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
