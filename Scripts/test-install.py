#!/usr/bin/env python3
"""Exercise installation only in temporary homes, with no real service or signing calls.

The Swift serializer is compiled once. Each installer run receives a private PATH:
Swift builds, codesign and launchctl are strict stubs, and filesystem commands are
restricted to that run's temporary directory. The fixture binary is never run.
"""

import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
LABEL = "com.ajvwhite.MacXeneonEdgeTouchDriver"
BINARY = "MacXeneonEdgeTouchDriver"
NEW_BINARY = b"Installer test fixture; this is not an executable.\n"
OLD_BINARY = b"Previous installer test fixture; this is not an executable.\n"
OLD_CONFIG = (
    b'{\r\n  "focus": {"restorePreviousWindow": false},\r\n'
    b'  "cursor": {"returnToPreviousPosition": false},\r\n'
    b'  "custom": "preserve whitespace, keys and UTF-8: \xe2\x98\x83"\r\n}\r\n'
)

# No lookup in the caller's PATH occurs inside this dispatcher. Only these native
# filesystem utilities can run, and their path arguments must stay in the case.
STUB_SOURCE = r'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import subprocess
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["XE_TEST_ROOT"]).resolve()
log = Path(os.environ["XE_TEST_LOG"])
state_path = Path(os.environ["XE_TEST_STATE"])
state = json.loads(state_path.read_text())
failures = set(json.loads(os.environ.get("XE_TEST_FAILURES", "[]")))
paths = json.loads(os.environ["XE_TEST_PATHS"])

def record(**extra):
    with log.open("a") as output:
        output.write(json.dumps(dict(command=command, args=args, **extra)) + "\n")

def save():
    state_path.write_text(json.dumps(state))

def reject(message, status=97):
    record(rejected=message)
    print("INSTALLER TEST GUARD: " + message, file=sys.stderr)
    sys.exit(status)

def inside(value):
    path = Path(value)
    if not path.is_absolute():
        path = Path.cwd() / path
    resolved = path.resolve()
    if resolved == root or root not in resolved.parents:
        reject("path escapes private test directory: " + str(value))
    return path

def fail(name, status=71):
    if name in failures:
        if name == "publish-plist-write" and "job-reregistered" in failures:
            state["loaded"] = True
            state["active_binary"] = Path(paths["binary"]).read_bytes().decode("utf-8")
            save()
            record(injection="job-reregistered")
        record(failure=name)
        print("injected failure: " + name, file=sys.stderr)
        sys.exit(status)

record()
if command == "swift":
    if len(args) == 5 and args[:4] == ["build", "-c", "release", "--package-path"]:
        package = inside(args[4])
        if package != Path(paths["workspace"]):
            reject("unexpected package build")
        fail("build")
        if "missing-build-output" not in failures:
            binary = package / ".build/release/MacXeneonEdgeTouchDriver"
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b"Installer test fixture; this is not an executable.\n")
        else:
            record(injection="missing-build-output")
        sys.exit(0)
    if len(args) == 6 and args[0] == str(Path(paths["workspace"]) / "Scripts/prepare-install.swift"):
        for value in args:
            inside(value)
        fail("serialization")
        if "serialization-write" in failures:
            # A partial output must never reach the installed files.
            record(injection="serialization-write")
            (Path(args[2]) / "agent.plist").mkdir()
        sys.exit(subprocess.run([os.environ["XE_TEST_SERIALIZER"], *args[1:]], check=False).returncode)
    reject("unexpected swift invocation")
elif command == "codesign":
    binary = inside(args[-1]) if args else reject("missing codesign arguments")
    if binary == Path(paths["binary"]) or binary == Path(paths["workspace"]) / ".build/release/MacXeneonEdgeTouchDriver":
        reject("codesign must operate on the staged binary")
    if "--sign" in args:
        if args[args.index("--sign") + 1] != "Installer Test Identity":
            reject("unexpected signing identity")
        fail("sign")
        state["signed"] = str(binary)
        save()
    elif "--verify" in args:
        if state.get("signed") != str(binary):
            reject("verification must follow staged signing")
        fail("verify")
    else:
        reject("unexpected codesign invocation")
    sys.exit(0)
elif command == "launchctl":
    service = "gui/501/com.ajvwhite.MacXeneonEdgeTouchDriver"
    if args == ["print", "gui/501"]:
        fail("domain-print", 5)
        sys.exit(0)
    if args == ["print", service]:
        fail("job-print", 5)
        if state.get("activation_failed"):
            fail("rollback-job-print", 5)
        if not state["loaded"]:
            print("Could not find service", file=sys.stderr)
            sys.exit(113)
        print(service)
        sys.exit(0)
    if args == ["bootout", service]:
        state["bootout_count"] += 1
        save()
        fail("bootout", 5)
        if state.get("activation_failed"):
            fail("rollback-bootout", 5)
        if not state["loaded"]:
            reject("bootout attempted for an absent test job")
        state["loaded"] = False
        save()
        fail("bootout-partial", 5)
        sys.exit(0)
    if len(args) == 3 and args[:2] == ["bootstrap", "gui/501"]:
        plist = inside(args[2])
        if plist != Path(paths["plist"]):
            reject("unexpected bootstrap plist")
        state["bootstrap_count"] += 1
        if state["bootstrap_count"] == 1 and ("bootstrap" in failures or "bootstrap-partial" in failures):
            state["activation_failed"] = True
            state["loaded"] = "bootstrap-partial" in failures
            save()
            fail("bootstrap", 5)
            fail("bootstrap-partial", 5)
        if state["bootstrap_count"] > 1 and "rollback-bootstrap" in failures:
            save()
            fail("rollback-bootstrap", 6)
        if not plist.is_file() or not Path(paths["binary"]).is_file():
            reject("bootstrap did not receive a complete fixture installation")
        state["loaded"] = True
        state["active_binary"] = Path(paths["binary"]).read_bytes().decode("utf-8")
        save()
        sys.exit(0)
    reject("unexpected launchctl invocation; enable, disable and execution are forbidden")
elif command == "id":
    if args != ["-u"]:
        reject("unexpected id invocation")
    print("501")
    sys.exit(0)

utilities = {
    "cat": "/bin/cat", "chmod": "/bin/chmod", "cmp": "/usr/bin/cmp", "cp": "/bin/cp",
    "dirname": "/usr/bin/dirname", "install": "/usr/bin/install",
    "mkdir": "/bin/mkdir", "mktemp": "/usr/bin/mktemp", "mv": "/bin/mv",
    "rm": "/bin/rm", "rmdir": "/bin/rmdir", "touch": "/usr/bin/touch",
    "plutil": "/usr/bin/plutil",
}
if command not in utilities:
    reject("command is not allowlisted: " + command)

# Options with non-path operands used by the installer.
skip_next = False
values = []
for argument in args:
    if skip_next:
        skip_next = False
        continue
    if argument in ["-m", "-o", "-g"] and command == "install":
        skip_next = True
        continue
    if argument.startswith("-"):
        continue
    if command == "chmod" and not values and argument.isdigit():
        continue
    values.append(argument)
    inside(argument)

if command in ["cp", "install", "mv"] and values:
    destination = values[-1]
    if "/install-backups/" in destination:
        fail("backup-write")
    if Path(destination).name in ["binary", "next-binary"]:
        fail("stage-binary-write")
    if Path(destination).name == "next-plist":
        fail("stage-plist-write")
    if Path(destination).name == "next-config":
        fail("stage-config-write")
    for kind in ["binary", "plist", "config"]:
        if destination == paths[kind]:
            if state.get("activation_failed") or Path(values[0]).name.startswith("previous-"):
                fail("rollback-" + kind + "-write")
            else:
                fail("publish-" + kind + "-write")
result = subprocess.run([utilities[command], *args], check=False)
sys.exit(result.returncode)
'''


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin":
            raise unittest.SkipTest("installer tests require the macOS Swift Foundation toolchain")
        source = (ROOT / "Scripts/install.sh").read_text()
        # PATH isolation cannot intercept absolute tool paths or a reset PATH.
        # Fail closed if an edit would bypass the service/signing/build stubs.
        unsafe = re.compile(r"/(?:launchctl|codesign|swift)\b|\bPATH\s*=|\bunset\s+PATH\b|\bcommand\s+-p\b")
        if unsafe.search(source):
            raise AssertionError("installer could bypass the private stub PATH")
        cls.compiler_temp = tempfile.TemporaryDirectory(prefix="xeneon-installer-compiler-")
        cls.addClassCleanup(cls.compiler_temp.cleanup)
        compiler_root = Path(cls.compiler_temp.name)
        cls.serializer = compiler_root / "prepare-install"
        compiler_home = compiler_root / "home"
        compiler_home.mkdir()
        compiler_env = dict(os.environ, HOME=str(compiler_home))
        compiler_env.pop("CODESIGN_IDENTITY", None)
        compiled = subprocess.run(
            ["/usr/bin/swiftc", "-module-cache-path", str(compiler_root / "module-cache"),
             str(ROOT / "Scripts/prepare-install.swift"), "-o", str(cls.serializer)],
            env=compiler_env, capture_output=True, text=True,
        )
        if compiled.returncode:
            raise AssertionError("serializer compilation failed:\n" + compiled.stdout + compiled.stderr)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "compiler_temp"):
            cls.compiler_temp.cleanup()

    def setUp(self):
        self.case_temp = tempfile.TemporaryDirectory(prefix="xeneon-installer-test-")
        self.addCleanup(self.case_temp.cleanup)
        self.case = Path(self.case_temp.name).resolve()

    def prepare(self, suffix="ordinary", existing=True, loaded=True):
        self.home = self.case / ("home-" + suffix)
        self.workspace = self.case / ("workspace-" + suffix)
        for directory in [self.home, self.workspace / "Scripts", self.workspace / "Resources"]:
            directory.mkdir(parents=True)
        for relative in ["Scripts/install.sh", "Scripts/prepare-install.swift", "Resources/" + LABEL + ".plist.template"]:
            shutil.copyfile(ROOT / relative, self.workspace / relative)
        self.support = self.home / "Library/Application Support" / BINARY
        self.binary = self.support / "bin" / BINARY
        self.config = self.support / "config.json"
        self.plist = self.home / "Library/LaunchAgents" / (LABEL + ".plist")
        self.logs = self.home / "Library/Logs" / BINARY
        self.old_plist = plistlib.dumps({"Label": LABEL, "ProgramArguments": [str(self.binary)], "PreviousVersion": True}) if existing else b""
        if existing:
            self.binary.parent.mkdir(parents=True)
            self.plist.parent.mkdir(parents=True)
            self.binary.write_bytes(OLD_BINARY)
            self.config.write_bytes(OLD_CONFIG)
            self.plist.write_bytes(self.old_plist)
        self.log_initial = {}
        if existing:
            self.logs.mkdir(parents=True)
            for name in ["driver.log", "stdout.log", "stderr.log"]:
                log_file = self.logs / name
                log_file.write_bytes(b"Previous log contents\n")
                os.utime(log_file, ns=(1_000_000_000, 1_000_000_000))
                self.log_initial[str(log_file)] = (log_file.read_bytes(), log_file.stat().st_mtime_ns)
        self.initial = {str(path): path.read_bytes() if path.exists() else None for path in [self.binary, self.config, self.plist]}
        self.state_file = self.case / "state.json"
        self.state_file.write_text(json.dumps({
            "loaded": bool(existing and loaded), "bootout_count": 0, "bootstrap_count": 0,
            "active_binary": OLD_BINARY.decode() if existing and loaded else None,
        }))
        self.command_log = self.case / "commands.jsonl"
        self.stub_bin = self.case / "stub-bin"
        self.stub_bin.mkdir()
        for name in ["swift", "codesign", "launchctl", "id", "cat", "chmod", "cmp", "cp", "dirname", "install", "mkdir", "mktemp", "mv", "rm", "rmdir", "touch", "plutil"]:
            stub = self.stub_bin / name
            stub.write_text(STUB_SOURCE)
            stub.chmod(0o755)
        self.tmp = self.case / "tmp"
        self.tmp.mkdir()

    def run_installer(self, failures=(), signing=False):
        env = {
            "HOME": str(self.home), "PATH": str(self.stub_bin), "TMPDIR": str(self.tmp) + "/",
            "LC_ALL": "en_US.UTF-8", "XE_TEST_ROOT": str(self.case),
            "XE_TEST_LOG": str(self.command_log), "XE_TEST_STATE": str(self.state_file),
            "XE_TEST_FAILURES": json.dumps(list(failures)), "XE_TEST_SERIALIZER": str(self.serializer),
            "XE_TEST_PATHS": json.dumps({
                "workspace": str(self.workspace), "binary": str(self.binary),
                "plist": str(self.plist), "config": str(self.config),
            }),
        }
        if signing:
            env["CODESIGN_IDENTITY"] = "Installer Test Identity"
        result = subprocess.run(
            ["/bin/sh", str(self.workspace / "Scripts/install.sh")], env=env,
            cwd=self.workspace, capture_output=True, text=True, timeout=30,
        )
        self.output = result.stdout + result.stderr
        self.calls = [json.loads(line) for line in self.command_log.read_text().splitlines()] if self.command_log.exists() else []
        self.state = json.loads(self.state_file.read_text())
        self.assertNotIn("INSTALLER TEST GUARD", self.output, self.output)
        for failure in failures:
            self.assertTrue(
                any(call.get("failure") == failure or call.get("injection") == failure for call in self.calls),
                "Requested failure was not exercised: " + failure + "\n" + self.output,
            )
        for name, expected in self.log_initial.items():
            path = Path(name)
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), expected, name)
        return result.returncode

    def assert_unchanged(self):
        for name, expected in self.initial.items():
            path = Path(name)
            actual = path.read_bytes() if path.exists() else None
            self.assertEqual(actual, expected, name + "\n" + self.output)

    def assert_no_job_change(self):
        self.assertEqual(self.state["bootout_count"], 0, self.output)
        self.assertEqual(self.state["bootstrap_count"], 0, self.output)

    def assert_preflight_failure(self, failures=(), signing=False):
        self.assertNotEqual(self.run_installer(failures, signing), 0, self.output)
        self.assert_unchanged()
        self.assert_no_job_change()
        self.assertNotIn("Installed " + BINARY, self.output)

    def assert_new_installation(self, preserved=True):
        self.assertEqual(self.binary.read_bytes(), NEW_BINARY)
        plist = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(plist["Label"], LABEL)
        self.assertEqual(plist["ProgramArguments"], [str(self.binary)])
        self.assertEqual(plist["StandardOutPath"], str(self.logs / "stdout.log"))
        self.assertEqual(plist["StandardErrorPath"], str(self.logs / "stderr.log"))
        if preserved:
            self.assertEqual(self.config.read_bytes(), OLD_CONFIG)
        else:
            config = json.loads(self.config.read_bytes())
            self.assertIs(config["focus"]["restorePreviousWindow"], True)
            self.assertIs(config["cursor"]["returnToPreviousPosition"], True)
            self.assertEqual(config["diagnostics"]["fileLogPath"], str(self.logs / "driver.log"))
        self.assertTrue(self.state["loaded"], self.output)

    def backup_directories(self):
        return list((self.support / "install-backups").glob("transaction.*"))

    def test_successful_upgrade_retains_originals(self):
        self.prepare()
        self.assertEqual(self.run_installer(), 0, self.output)
        self.assert_new_installation()
        self.assertEqual(self.state["bootout_count"], 1)
        self.assertEqual(self.state["bootstrap_count"], 1)
        backups = self.backup_directories()
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "binary").read_bytes(), OLD_BINARY)
        self.assertEqual((backups[0] / "agent.plist").read_bytes(), self.old_plist)
        self.assertEqual((backups[0] / "config.json").read_bytes(), OLD_CONFIG)
        self.assertIn(str(backups[0]), self.output)

    def test_paths_roundtrip_in_xml_and_json(self):
        for suffix in ["ordinary", "with spaces", "amp&ersand", "less<than", "quotes'\"", "back\\slash", "Unicode-雪-☃", "line\nbreak", "carriage\rreturn", "tab\tstop"]:
            with self.subTest(path=suffix):
                # Use a separate parent for each path variant within this case.
                original_case = self.case
                self.case = original_case / ("variant-" + str(len(list(original_case.iterdir()))))
                self.case.mkdir()
                self.prepare(suffix, existing=False)
                self.assertEqual(self.run_installer(), 0, self.output)
                self.assert_new_installation(preserved=False)
                self.case = original_case

    def test_sign_and_verify_staged_binary_before_job_changes(self):
        self.prepare()
        self.assertEqual(self.run_installer(signing=True), 0, self.output)
        self.assert_new_installation()
        sign_calls = [index for index, call in enumerate(self.calls) if call["command"] == "codesign"]
        self.assertEqual(len(sign_calls), 2)
        bootout = next(index for index, call in enumerate(self.calls) if call["command"] == "launchctl" and call["args"][0] == "bootout")
        self.assertLess(max(sign_calls), bootout)

    def test_preflight_failure_leaves_old_files_and_job(self):
        for failure in ["build", "missing-build-output", "serialization", "serialization-write", "sign", "verify", "backup-write", "stage-binary-write", "stage-plist-write", "domain-print", "job-print"]:
            with self.subTest(failure=failure):
                original_case = self.case
                self.case = original_case / failure
                self.case.mkdir()
                self.prepare()
                self.assert_preflight_failure([failure], signing=failure in ["sign", "verify"])
                self.case = original_case

    def test_new_config_staging_failure_leaves_installation_absent(self):
        self.prepare(existing=False)
        self.assert_preflight_failure(["stage-config-write"])

    def test_invalid_template_is_preflight_failure(self):
        self.prepare()
        (self.workspace / "Resources" / (LABEL + ".plist.template")).write_text("<not-a-plist>&</not-a-plist>")
        self.assert_preflight_failure()

    def test_xml_forbidden_path_character_is_preflight_failure(self):
        self.prepare("control-\x01-character", existing=False)
        self.assert_preflight_failure()

    def test_wrong_prior_plist_label_is_preflight_failure(self):
        original_case = self.case
        for index, prior_label in enumerate(["another.application", LABEL + "\n", {LABEL: True}]):
            with self.subTest(label=prior_label):
                self.case = original_case / ("label-" + str(index))
                self.case.mkdir()
                self.prepare()
                self.plist.write_bytes(plistlib.dumps({"Label": prior_label, "ProgramArguments": [str(self.binary)]}))
                self.initial[str(self.plist)] = self.plist.read_bytes()
                self.assert_preflight_failure()
        self.case = original_case

    def test_wrong_template_type_is_preflight_failure(self):
        self.prepare()
        template = self.workspace / "Resources" / (LABEL + ".plist.template")
        content = plistlib.loads(template.read_bytes())
        content["RunAtLoad"] = "true"
        template.write_bytes(plistlib.dumps(content))
        self.assert_preflight_failure()

    def test_wrong_template_label_is_preflight_failure(self):
        self.prepare()
        template = self.workspace / "Resources" / (LABEL + ".plist.template")
        template.write_text(template.read_text().replace(LABEL, "wrong.label"))
        self.assert_preflight_failure()

    def test_invalid_existing_config_is_preserved_on_rejection(self):
        self.prepare()
        self.config.write_bytes(b"{invalid JSON\xff\n")
        self.initial[str(self.config)] = self.config.read_bytes()
        self.assert_preflight_failure()

    def test_symlinked_existing_config_is_preserved_on_rejection(self):
        self.prepare()
        target = self.case / "user-config.json"
        self.config.rename(target)
        self.config.symlink_to(target)
        self.assert_preflight_failure()
        self.assertTrue(self.config.is_symlink())
        self.assertEqual(target.read_bytes(), OLD_CONFIG)

    def test_bootout_failure_leaves_files_and_job(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["bootout"]), 0, self.output)
        self.assert_unchanged()
        self.assertTrue(self.state["loaded"])
        self.assertEqual(self.state["bootstrap_count"], 0)

    def test_bootout_failure_after_unloading_restores_previous_job(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["bootout-partial"]), 0, self.output)
        self.assert_unchanged()
        self.assertTrue(self.state["loaded"])
        self.assertEqual(self.state["bootstrap_count"], 1)
        self.assertEqual(self.state["active_binary"], OLD_BINARY.decode())

    def test_publish_failure_restores_files_and_previous_job(self):
        for failure in ["publish-binary-write", "publish-plist-write"]:
            with self.subTest(failure=failure):
                original_case = self.case
                self.case = original_case / failure
                self.case.mkdir()
                self.prepare()
                self.assertNotEqual(self.run_installer([failure]), 0, self.output)
                self.assert_unchanged()
                self.assertTrue(self.state["loaded"], self.output)
                self.assertEqual(self.state["active_binary"], OLD_BINARY.decode())
                self.case = original_case

    def test_job_reregistered_during_publication_requires_manual_recovery(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["publish-plist-write", "job-reregistered"]), 0, self.output)
        self.assertEqual(self.binary.read_bytes(), NEW_BINARY)
        self.assertEqual(self.plist.read_bytes(), self.old_plist)
        self.assertEqual(self.config.read_bytes(), OLD_CONFIG)
        self.assertTrue(self.state["loaded"])
        self.assertEqual(self.state["bootstrap_count"], 0)
        self.assertEqual((self.backup_directories()[0] / "binary").read_bytes(), OLD_BINARY)
        self.assertIn("Rollback incomplete", self.output)
        self.assertIn(str(self.backup_directories()[0]), self.output)

    def test_failed_bootstrap_restores_previous_files_and_job(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["bootstrap"]), 0, self.output)
        self.assert_unchanged()
        self.assertTrue(self.state["loaded"], self.output)
        self.assertEqual(self.state["bootstrap_count"], 2)
        self.assertEqual(self.state["active_binary"], OLD_BINARY.decode())
        self.assertIn("rollback", self.output.lower())
        self.assertNotIn("Installed " + BINARY, self.output)

    def test_failed_partial_bootstrap_stops_replacement_before_restoring(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["bootstrap-partial"]), 0, self.output)
        self.assert_unchanged()
        self.assertEqual(self.state["bootout_count"], 2)
        self.assertTrue(self.state["loaded"], self.output)
        self.assertEqual(self.state["active_binary"], OLD_BINARY.decode())

    def test_failed_rollback_bootstrap_reports_failure(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["bootstrap", "rollback-bootstrap"]), 0, self.output)
        self.assert_unchanged()
        self.assertFalse(self.state["loaded"])
        self.assertRegex(self.output.lower(), r"rollback[\s\S]*(failed|incomplete)|(?:failed|incomplete)[\s\S]*rollback")
        self.assertIn(str(self.backup_directories()[0]), self.output)

    def test_failed_rollback_write_retains_backups_and_reports_failure(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["bootstrap", "rollback-binary-write"]), 0, self.output)
        self.assertEqual(self.binary.read_bytes(), NEW_BINARY)
        self.assertEqual(self.config.read_bytes(), OLD_CONFIG)
        self.assertEqual(self.plist.read_bytes(), self.old_plist)
        self.assertFalse(self.state["loaded"])
        self.assertEqual((self.backup_directories()[0] / "binary").read_bytes(), OLD_BINARY)
        self.assertRegex(self.output.lower(), r"rollback[\s\S]*(failed|incomplete)|(?:failed|incomplete)[\s\S]*rollback")
        self.assertIn(str(self.backup_directories()[0]), self.output)

    def test_failed_rollback_bootout_does_not_replace_files_under_live_job(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["bootstrap-partial", "rollback-bootout"]), 0, self.output)
        self.assertEqual(self.binary.read_bytes(), NEW_BINARY)
        self.assertEqual(self.config.read_bytes(), OLD_CONFIG)
        self.assertTrue(self.state["loaded"])
        self.assertEqual(self.state["bootstrap_count"], 1)
        self.assertRegex(self.output.lower(), r"rollback[\s\S]*(failed|incomplete)|(?:failed|incomplete)[\s\S]*rollback")

    def test_rollback_query_failure_reports_unknown_state(self):
        self.prepare()
        self.assertNotEqual(self.run_installer(["bootstrap", "rollback-job-print"]), 0, self.output)
        self.assertEqual(self.binary.read_bytes(), NEW_BINARY)
        self.assertEqual(self.config.read_bytes(), OLD_CONFIG)
        self.assertEqual(self.state["bootstrap_count"], 1)
        self.assertIn("Rollback incomplete", self.output)
        self.assertIn(str(self.backup_directories()[0]), self.output)

    def test_first_install_config_publish_failure_removes_new_files(self):
        self.prepare(existing=False)
        self.assertNotEqual(self.run_installer(["publish-config-write"]), 0, self.output)
        self.assert_unchanged()
        self.assertFalse(self.state["loaded"])
        self.assertEqual(self.state["bootstrap_count"], 0)

    def test_first_install_bootstrap_failure_removes_new_files(self):
        self.prepare(existing=False)
        self.assertNotEqual(self.run_installer(["bootstrap"]), 0, self.output)
        self.assert_unchanged()
        self.assertFalse(self.state["loaded"])
        self.assertEqual(self.state["bootstrap_count"], 1)

    def test_unloaded_existing_job_is_not_restarted_by_rollback(self):
        self.prepare(loaded=False)
        self.assertNotEqual(self.run_installer(["bootstrap"]), 0, self.output)
        self.assert_unchanged()
        self.assertFalse(self.state["loaded"])
        self.assertEqual(self.state["bootout_count"], 0)
        self.assertEqual(self.state["bootstrap_count"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
