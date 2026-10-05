#!/usr/bin/env python3
"""Exercise uninstall in owned temporary homes with fake launchctl and guarded removal.

No installed driver, real launchctl, process signalling, hardware, or input is used.
The stub models command results; it does not establish macOS launchd semantics.
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
LABEL = "com.ajvwhite.MacXeneonEdgeTouchDriver"
BINARY = "MacXeneonEdgeTouchDriver"

STUB_SOURCE = r'''
import json
import os
from pathlib import Path
import shutil
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["XE_TEST_ROOT"]).resolve()
state_path = root / "state.json"
log_path = root / "calls.jsonl"
state = json.loads(state_path.read_text())
paths = {key: Path(value) for key, value in json.loads(os.environ["XE_TEST_PATHS"]).items()}


def record(**extra):
    with log_path.open("a") as stream:
        stream.write(json.dumps(dict(command=command, args=args, **extra)) + "\n")


def save():
    state_path.write_text(json.dumps(state))


def reject(message):
    record(rejected=message)
    print("UNINSTALL TEST GUARD: " + message, file=sys.stderr)
    sys.exit(97)


def error(message, status):
    print(message, file=sys.stderr)
    sys.exit(status)


record()
if command == "id":
    if args != ["-u"]:
        reject("unexpected id arguments")
    print("501")
    sys.exit(0)
if command == "launchctl":
    service = "gui/501/com.ajvwhite.MacXeneonEdgeTouchDriver"
    if args == ["print", "gui/501"]:
        state["domain_queries"] += 1
        save()
        status = state["domain_status"] if state["domain_queries"] == 1 else state["verify_domain_status"]
        if status:
            error("injected domain query error", status)
        print("domain diagnostic output; never parse me")
        sys.exit(0)
    if args == ["print", service]:
        state["service_queries"] += 1
        if state["service_queries"] > 1 and state["job_appears"]:
            state["loaded"] = True
        save()
        status = state["query_status"] if state["service_queries"] == 1 else state["verify_query_status"]
        if status:
            error("injected ambiguous query error", status)
        if state["loaded"]:
            print("service diagnostic output; never parse me")
            sys.exit(0)
        # Existing install.sh convention; stubs cannot validate the host API.
        state["removal_confirmed"] = state["service_queries"] > 1
        save()
        error("non-English arbitrary absence diagnostic", 113)
    if args == ["bootout", service]:
        state["bootout_count"] += 1
        if state["bootout_status"]:
            if state["partial_bootout"]:
                state["loaded"] = False
            save()
            error("injected bootout error", state["bootout_status"])
        if not state["loaded"]:
            save()
            error("arbitrary absent-service bootout diagnostic", 3)
        state["loaded"] = state["bootout_keeps_registered"]
        state["removal_confirmed"] = False
        save()
        sys.exit(0)
    reject("unexpected launchctl call; no plist fallback, bootstrap, or enable/disable allowed")
if command == "cat":
    if args:
        reject("cat may only copy its fixture stdin")
    sys.stdout.write(sys.stdin.read())
    sys.exit(0)
if command == "rm":
    if args == ["-f", str(paths["plist"])]:
        path = paths["plist"]
        kind = "plist"
    elif args == ["-rf", str(paths["support"])]:
        path = paths["support"]
        kind = "support"
    else:
        reject("removal outside the two exact installation targets")
    resolved = path.resolve()
    if resolved == root or root not in resolved.parents:
        reject("removal escaped the owned temporary case")
    if state["loaded"] or not state["removal_confirmed"]:
        reject("file removal before confirmed launchd definition removal")
    if state["remove_failure"] == kind:
        if kind == "support" and state["partial_remove"]:
            (path / "bin" / "MacXeneonEdgeTouchDriver").unlink()
        error("injected " + kind + " removal error", 1)
    if path.exists():
        if kind == "plist":
            path.unlink()
        else:
            shutil.rmtree(path)
    sys.exit(0)
reject("command is not allowlisted: " + command)
'''


class UninstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "Scripts/uninstall.sh").read_text()
        unsafe = re.compile(r"/(?:launchctl|rm|id)\b|\bPATH\s*=|\bunset\s+PATH\b|\bcommand\s+-p\b")
        if unsafe.search(source):
            raise AssertionError("uninstaller could bypass the private stub PATH")

    def setUp(self):
        self.owned = tempfile.TemporaryDirectory(prefix="xeneon-uninstall-test-")
        self.addCleanup(self.owned.cleanup)
        self.case = Path(self.owned.name).resolve()
        self.home = self.case / "home with spaces & Unicode 雪"
        self.workspace = self.case / "workspace with spaces"
        self.workspace.mkdir()
        self.script = self.workspace / "uninstall.sh"
        shutil.copyfile(ROOT / "Scripts/uninstall.sh", self.script)
        self.support = self.home / "Library/Application Support" / BINARY
        self.binary = self.support / "bin" / BINARY
        self.config = self.support / "config.json"
        self.backup = self.support / "install-backups/transaction.fixture/binary"
        self.plist = self.home / "Library/LaunchAgents" / (LABEL + ".plist")
        self.log = self.home / "Library/Logs" / BINARY / "driver.log"
        self.unrelated = self.home / "Library/Application Support/Unrelated/config.json"
        for index, path in enumerate([self.binary, self.config, self.backup, self.plist, self.log, self.unrelated]):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("Harmless fixture %d\n" % index).encode())
        self.initial = {str(path): path.read_bytes() for path in self.home.rglob("*") if path.is_file()}
        self.stub_bin = self.case / "stub-bin"
        self.stub_bin.mkdir()
        for name in ["id", "launchctl", "rm", "cat"]:
            stub = self.stub_bin / name
            stub.write_text("#!" + sys.executable + "\n" + STUB_SOURCE)
            stub.chmod(0o755)
        self.state_path = self.case / "state.json"
        self.state = dict(loaded=True, domain_status=0, query_status=0, bootout_status=0,
                          bootout_count=0, partial_bootout=False, removal_confirmed=False,
                          remove_failure=None, partial_remove=False, domain_queries=0,
                          service_queries=0, verify_domain_status=0, verify_query_status=0,
                          job_appears=False, bootout_keeps_registered=False)

    def run_uninstaller(self, **state_changes):
        self.state.update(state_changes)
        self.state_path.write_text(json.dumps(self.state))
        env = {
            "HOME": str(self.home), "PATH": str(self.stub_bin), "LC_ALL": "C",
            "XE_TEST_ROOT": str(self.case),
            "XE_TEST_PATHS": json.dumps({"plist": str(self.plist), "support": str(self.support)}),
        }
        result = subprocess.run(["/bin/sh", str(self.script)], cwd=self.workspace, env=env,
                                capture_output=True, text=True, timeout=10)
        self.output = result.stdout + result.stderr
        self.calls = [json.loads(line) for line in (self.case / "calls.jsonl").read_text().splitlines()]
        self.state = json.loads(self.state_path.read_text())
        self.assertNotIn("UNINSTALL TEST GUARD", self.output, self.output)
        self.assertFalse(any(call.get("rejected") for call in self.calls), self.calls)
        for path in [self.log, self.unrelated]:
            self.assertEqual(path.read_bytes(), self.initial[str(path)])
        return result.returncode

    def assert_preserved(self):
        for name, contents in self.initial.items():
            self.assertEqual(Path(name).read_bytes(), contents, name + "\n" + self.output)
        self.assertFalse(any(call["command"] == "rm" for call in self.calls))
        self.assertNotIn("Uninstalled " + BINARY, self.output)

    def test_registered_success_removes_only_intended_paths_with_spaces(self):
        self.assertEqual(self.run_uninstaller(), 0, self.output)
        self.assertFalse(self.plist.exists())
        self.assertFalse(self.support.exists())
        self.assertFalse(self.state["loaded"])
        self.assertTrue(self.state["removal_confirmed"])
        self.assertEqual(self.state["bootout_count"], 1)
        self.assertIn("Uninstalled " + BINARY, self.output)
        self.assertEqual([call["args"] for call in self.calls if call["command"] == "rm"],
                         [["-f", str(self.plist)], ["-rf", str(self.support)]])

    def test_absent_job_removes_files_only_after_two_successful_domain_checks(self):
        self.assertEqual(self.run_uninstaller(loaded=False), 0, self.output)
        self.assertEqual(self.state["bootout_count"], 0)
        self.assertEqual(self.state["domain_queries"], 2)
        self.assertEqual(self.state["service_queries"], 2)
        self.assertFalse(self.plist.exists())
        self.assertFalse(self.support.exists())

    def test_absent_files_and_job_are_idempotent(self):
        self.plist.unlink()
        shutil.rmtree(self.support)
        self.assertEqual(self.run_uninstaller(loaded=False), 0, self.output)
        self.assertEqual(self.state["bootout_count"], 0)

    def test_successful_bootout_without_unregistration_preserves_files(self):
        self.assertNotEqual(self.run_uninstaller(bootout_keeps_registered=True), 0, self.output)
        self.assertTrue(self.state["loaded"])
        self.assert_preserved()

    def test_domain_disappearing_after_bootout_preserves_files(self):
        self.assertNotEqual(self.run_uninstaller(verify_domain_status=5), 0, self.output)
        self.assertFalse(self.state["loaded"])
        self.assert_preserved()

    def test_ambiguous_verification_query_preserves_files(self):
        self.assertNotEqual(self.run_uninstaller(verify_query_status=5), 0, self.output)
        self.assertFalse(self.state["loaded"])
        self.assert_preserved()

    def test_job_appearing_after_absent_preflight_preserves_files(self):
        self.assertNotEqual(self.run_uninstaller(loaded=False, job_appears=True), 0, self.output)
        self.assertEqual(self.state["bootout_count"], 0)
        self.assertTrue(self.state["loaded"])
        self.assert_preserved()

    def test_unknown_statuses_never_mean_absent(self):
        for status in [1, 3, 5, 64, 112, 114, 126, 127, 255]:
            with self.subTest(status=status):
                self.setUp()
                self.assertNotEqual(self.run_uninstaller(query_status=status), 0, self.output)
                self.assertEqual(self.state["bootout_count"], 0)
                self.assert_preserved()

    def test_missing_domain_status_113_does_not_mean_absent(self):
        self.assertNotEqual(self.run_uninstaller(domain_status=113), 0, self.output)
        self.assertEqual(self.state["bootout_count"], 0)
        self.assert_preserved()

    def test_bootout_failure_preserves_files_without_plist_fallback(self):
        self.assertNotEqual(self.run_uninstaller(bootout_status=5), 0, self.output)
        self.assertTrue(self.state["loaded"])
        self.assertEqual(self.state["bootout_count"], 1)
        self.assert_preserved()

    def test_bootout_service_not_found_status_does_not_override_failed_stop(self):
        self.assertNotEqual(self.run_uninstaller(bootout_status=113), 0, self.output)
        self.assertTrue(self.state["loaded"])
        self.assertEqual(self.state["bootout_count"], 1)
        self.assert_preserved()

    def test_missing_launchctl_preserves_files(self):
        (self.stub_bin / "launchctl").unlink()
        self.assertNotEqual(self.run_uninstaller(), 0, self.output)
        self.assertEqual(self.state["bootout_count"], 0)
        self.assert_preserved()

    def test_partial_bootout_failure_still_preserves_files(self):
        self.assertNotEqual(self.run_uninstaller(bootout_status=5, partial_bootout=True), 0, self.output)
        self.assertFalse(self.state["loaded"])
        self.assert_preserved()

    def test_domain_query_failure_preserves_files_before_bootout(self):
        self.assertNotEqual(self.run_uninstaller(domain_status=5), 0, self.output)
        self.assertEqual(self.state["bootout_count"], 0)
        self.assert_preserved()

    def test_ambiguous_service_query_failure_preserves_files_before_bootout(self):
        self.assertNotEqual(self.run_uninstaller(query_status=5), 0, self.output)
        self.assertEqual(self.state["bootout_count"], 0)
        self.assert_preserved()

    def test_registered_job_with_missing_plist_still_uses_exact_service_target(self):
        self.plist.unlink()
        self.assertEqual(self.run_uninstaller(), 0, self.output)
        self.assertFalse(self.support.exists())
        self.assertEqual(self.state["bootout_count"], 1)

    def test_plist_removal_failure_preserves_support_and_reports_incomplete(self):
        self.assertNotEqual(self.run_uninstaller(remove_failure="plist"), 0, self.output)
        self.assertFalse(self.state["loaded"])
        self.assertTrue(self.plist.exists())
        self.assertEqual(self.binary.read_bytes(), self.initial[str(self.binary)])
        self.assertEqual(self.config.read_bytes(), self.initial[str(self.config)])
        self.assertFalse(any(call["args"] == ["-rf", str(self.support)] for call in self.calls))
        self.assertIn("incomplete", self.output)
        self.assertNotIn("Uninstalled " + BINARY, self.output)

    def test_partial_support_removal_reports_no_false_success_or_rollback(self):
        self.assertNotEqual(self.run_uninstaller(remove_failure="support", partial_remove=True), 0, self.output)
        self.assertFalse(self.state["loaded"])
        self.assertFalse(self.plist.exists())
        self.assertFalse(self.binary.exists())
        self.assertEqual(self.config.read_bytes(), self.initial[str(self.config)])
        self.assertEqual(self.backup.read_bytes(), self.initial[str(self.backup)])
        self.assertIn("incomplete", self.output)
        self.assertIn("partially removed", self.output)
        self.assertNotIn("Uninstalled " + BINARY, self.output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
