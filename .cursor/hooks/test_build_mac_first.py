"""The build Mac's hook (.cursor/hooks/build-mac-first.py): python3 -m unittest discover -s .cursor/hooks"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import unittest
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location("build_mac_first", Path(__file__).resolve().parent / "build-mac-first.py")
hook = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hook)


def reply(command: str, answers: bool = True) -> tuple[dict, mock.Mock]:
    """What the hook tells Cursor about a command, and its check of whether the build Mac answers."""
    output, check = io.StringIO(), mock.Mock(return_value=answers)
    stdin = io.StringIO(json.dumps({"command": command}))
    with mock.patch.object(hook, "answers", check), mock.patch("sys.stdin", stdin), contextlib.redirect_stdout(output):
        hook.main()
    return json.loads(output.getvalue()), check


def asked(command: str, answers: bool = True) -> list[str] | None:
    """The build-mac.py lines the agent is asked to run instead of the command, or None when it runs as it is."""
    answer, _ = reply(command, answers)
    return re.findall(r"`([^`]+)`", answer["user_message"]) if answer["permission"] == "deny" else None


class Refused(unittest.TestCase):
    """While the build Mac answers, tests, the push gate and the regression suite run here are refused, with the
    build-mac.py line that runs the same there."""

    def assertAsked(self, command: str, *lines: str):
        self.assertEqual(asked(command), list(lines), command)

    def test_an_xcodebuild_test_is_sent_with_its_scheme_and_the_tests_it_picks(self):
        self.assertAsked(
            "xcodebuild test -workspace Redlamp.xcworkspace -scheme RedlampEngine -destination 'platform=macOS,arch=arm64'"
            " -derivedDataPath build/DerivedData-x -only-testing:RedlampEngineTests/FooTests",
            "scripts/build-mac.py test --scheme RedlampEngine --only RedlampEngineTests/FooTests",
        )
        self.assertAsked(
            "TEST_RUNNER_FOO=1 xcodebuild test -scheme RedlampEngine -skip-testing:RedlampEngineTests/Slow",
            "TEST_RUNNER_FOO=1 scripts/build-mac.py test --scheme RedlampEngine --skip RedlampEngineTests/Slow",
        )

    def test_a_program_is_found_after_the_runners_before_it(self):
        self.assertAsked("cd x && mise exec -- xcodebuild test -scheme RedlampUI 2>&1 | tail -30",
                         "scripts/build-mac.py test --scheme RedlampUI")
        self.assertAsked("nice -n 10 xcodebuild test -scheme A", "scripts/build-mac.py test --scheme A")
        self.assertAsked("python3 scripts/push-gate.py", "scripts/build-mac.py gate")

    def test_a_command_wrapped_in_timeout_is_sent_without_it(self):
        self.assertAsked("timeout 600 xcodebuild test -scheme RedlampEngine",
                         "scripts/build-mac.py test --scheme RedlampEngine")
        self.assertAsked(
            "gtimeout 10m mise exec -- xcodebuild test -scheme RedlampUI -only-testing:RedlampUITests/ExportSheetTests",
            "scripts/build-mac.py test --scheme RedlampUI --only RedlampUITests/ExportSheetTests",
        )
        self.assertAsked("TEST_RUNNER_FOO=1 timeout -k 10 -s KILL --preserve-status 1.5h xcodebuild test -scheme A",
                         "TEST_RUNNER_FOO=1 scripts/build-mac.py test --scheme A")
        self.assertAsked("timeout --signal=INT 1800 scripts/push-gate.py --suite", "scripts/build-mac.py gate --suite")
        self.assertAsked("timeout 900 python3 scripts/e2e.py --tier full", "scripts/build-mac.py e2e -- --tier full")
        self.assertAsked("timeout 600 bash -c 'xcodebuild test -scheme A'", "scripts/build-mac.py test --scheme A")

    def test_the_push_gate_and_the_regression_suite_are_sent_with_their_arguments(self):
        self.assertAsked("scripts/push-gate.py --suite origin/main", "scripts/build-mac.py gate --suite origin/main")
        self.assertAsked("scripts/e2e.py --tier full", "scripts/build-mac.py e2e -- --tier full")
        self.assertAsked("scripts/push-gate.py && scripts/e2e.py", "scripts/build-mac.py gate", "scripts/build-mac.py e2e")

    def test_a_command_given_to_a_shell_or_to_ssh_is_read_too(self):
        self.assertAsked("bash -c 'cd x; xcodebuild test -scheme A'", "scripts/build-mac.py test --scheme A")
        self.assertAsked("ssh build-mac 'cd src/build-mac/redlamp && xcodebuild test -scheme A'",
                         "scripts/build-mac.py test --scheme A")

    def test_the_agent_is_told_what_to_run_instead(self):
        answer, _ = reply("timeout 600 xcodebuild test -scheme RedlampEngine")
        self.assertIn("Run `scripts/build-mac.py test --scheme RedlampEngine` instead.", answer["agent_message"])


class LetRun(unittest.TestCase):
    """What runs no tests here, or runs what has to stay here, goes ahead."""

    def assertLetRun(self, *commands: str):
        for command in commands:
            self.assertIsNone(asked(command), command)

    def test_builds_and_other_xcodebuild_commands_go_ahead(self):
        self.assertLetRun("xcodebuild -version", "xcodebuild build -workspace Redlamp.xcworkspace -scheme Redlamp",
                          "timeout 600 xcodebuild build -scheme Redlamp")

    def test_a_program_named_rather_than_run_goes_ahead(self):
        self.assertLetRun("cat scripts/push-gate.py", 'rg -n "xcodebuild test" AGENTS.md',
                          'git commit -m "xcodebuild test here"', "cat > /tmp/x.sh <<'EOF'\nxcodebuild test -scheme A\nEOF",
                          "timeout 60 cat scripts/e2e.py")

    def test_runs_that_stay_here_go_ahead(self):
        self.assertLetRun(
            "TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1 xcodebuild test -scheme RedlampEngine",
            "TEST_RUNNER_REDLAMP_RECORD_PROCESS_GOLDEN=1 timeout 600 xcodebuild test -scheme RedlampEngine",
            "xcodebuild test -project Foo.xcodeproj -scheme A",
            "xcodebuild test -scheme A -destination 'platform=iOS Simulator,name=iPhone 16'",
            "scripts/e2e.py --passing-report abc --tier release --focus",
            "scripts/e2e.py --tier performance",
            "timeout 600 scripts/e2e.py --tier performance",
            "scripts/push-gate.py --hook origin https://x",
        )

    def test_build_mac_py_and_the_mise_tasks_go_ahead(self):
        self.assertLetRun("scripts/build-mac.py test --scheme RedlampEngine --only RedlampEngineTests/FooTests",
                          "mise run gate -- --suite")

    def test_a_command_with_nothing_to_send_doesnt_wait_for_the_build_mac(self):
        answer, check = reply("xcodebuild -version")
        self.assertEqual(answer, {"permission": "allow"})
        check.assert_not_called()


class BuildMacAway(unittest.TestCase):
    """When the build Mac doesn't answer, everything runs here as it is."""

    def test_tests_and_the_gate_run_here(self):
        self.assertIsNone(asked("timeout 600 xcodebuild test -scheme RedlampEngine", answers=False))
        self.assertIsNone(asked("scripts/push-gate.py --suite", answers=False))


if __name__ == "__main__":
    unittest.main()
