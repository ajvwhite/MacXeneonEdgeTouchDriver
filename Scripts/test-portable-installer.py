#!/usr/bin/env python3
"""Test portable packaging in private fixtures, without signing or installing.

Builds, signatures, notarization, stapling and Gatekeeper checks are simulated.
The private copy of the builder redirects its absolute spctl command to a fixture
stub; no production driver, real keychain or launchd service is touched. Archive
contents and checksums use real ZIP and SHA-256 implementations.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
IDENTITY = "Developer ID Application: Portable Test (TESTTEAM42)"

STUB = r'''#!/usr/bin/python3
import hashlib,json,os
from pathlib import Path
import sys,zipfile
command=Path(sys.argv[0]).name
args=sys.argv[1:]
root=Path(os.environ['XENEON_PACKAGE_TEST_ROOT']).resolve()
log=root/'commands.jsonl'
with log.open('a') as f: f.write(json.dumps({'command':command,'args':args})+'\n')
failure=os.environ.get('XENEON_PACKAGE_TEST_FAILURE','')
def reject(message):
 print('PORTABLE TEST GUARD: '+message,file=sys.stderr);sys.exit(97)
def inside(value):
 p=Path(value)
 if not p.is_absolute(): p=Path.cwd()/p
 resolved=p.resolve()
 if root not in resolved.parents: reject('path escapes fixture: '+str(value))
 return p
def fail(name):
 if failure==name:
  print('injected '+name,file=sys.stderr);sys.exit(71)
def value(flag):
 if flag not in args or args.index(flag)+1>=len(args): reject('missing '+flag)
 return args[args.index(flag)+1]
def fixture_binary(path,name):
 inside(path).parent.mkdir(parents=True,exist_ok=True)
 inside(path).write_text('Portable test fixture '+name+'\n'+(os.environ['HOME']+'/private-file' if failure=='private-path' else ''))
if command=='swift':
 if args[0]!='build':reject('unexpected Swift command')
 package=inside(value('--package-path'))
 scratch=inside(value('--scratch-path'))
 arch=value('--arch')
 if arch not in ['arm64','x86_64']:reject('bad architecture')
 out=scratch/arch/'release'
 if '--show-bin-path' in args: print(out);sys.exit(0)
 if '--product' not in args or value('--product')!='MacXeneonEdgeTouchDriver':reject('unexpected product')
 fail('build')
 fixture_binary(out/'MacXeneonEdgeTouchDriver',arch+' driver')
 sys.exit(0)
if command=='codesign':
 target=inside(args[-1])
 if '--sign' in args:
  fail('sign')
  if value('--sign')!=os.environ['CODESIGN_IDENTITY']:reject('wrong signing identity')
  if value('--sign')=='-':sys.exit(0)
  if not target.exists():reject('signing absent output')
 elif '--verify' in args:
  fail('verify')
  if os.environ['CODESIGN_IDENTITY']=='-':print('not Developer ID',file=sys.stderr);sys.exit(71)
 elif '-d' in args:
  print('TeamIdentifier=TESTTEAM42',file=sys.stderr)
 else:reject('unexpected signing command')
 sys.exit(0)
if command=='xcrun':
 if args==['--sdk','macosx','--show-sdk-path']:
  print(root/'sdk');sys.exit(0)
 if args[0]=='swiftc':
  target=value('-target')
  source=inside(args[-3]); output=inside(value('-o'))
  if source.name=='prepare-install.swift':fail('helper-build')
  else:fail('app-build')
  fixture_binary(output,target+' '+source.name);sys.exit(0)
 if args[0]=='lipo':
  if args[1]!='-create':reject('unexpected lipo command')
  output=inside(value('-output'))
  inputs=args[2:args.index('-output')]
  if len(inputs)!=2:reject('universal output needs two inputs')
  output.parent.mkdir(parents=True,exist_ok=True)
  output.write_bytes(b''.join(inside(x).read_bytes() for x in inputs));sys.exit(0)
 if args[0]=='strip':
  if args[1]!='-S':reject('unexpected stripping command')
  inside(args[-1]);sys.exit(0)
 if args[:2]==['notarytool','submit']:
  archive=inside(args[2]);
  if not archive.is_file():reject('notarization archive missing')
  if value('--keychain-profile')!='Portable Profile':reject('unexpected profile')
  count_path=root/'submissions.json'
  submissions=json.loads(count_path.read_text()) if count_path.exists() else []
  with zipfile.ZipFile(archive) as z: entries=z.namelist()
  submissions.append({'archive':str(archive),'entries':entries})
  count_path.write_text(json.dumps(submissions))
  fail('notary-'+str(len(submissions)))
  if failure=='notary-rejected-'+str(len(submissions)):
   print(json.dumps({'status':'Invalid'}));sys.exit(0)
  if failure=='notary-malformed-'+str(len(submissions)):
   print('not JSON');sys.exit(0)
  print(json.dumps({'status':'Accepted','id':'fixture-notary-'+str(len(submissions))}));sys.exit(0)
 if args[0]=='stapler':
  if args[1] not in ['staple','validate']:reject('unexpected staple command')
  inside(args[-1]);fail(args[1]);sys.exit(0)
 reject('unexpected xcrun command')
if command=='ditto':
 fail('archive')
 source=inside(args[-2]); destination=inside(args[-1])
 if not source.is_dir():reject('archive source must be directory')
 destination.parent.mkdir(parents=True,exist_ok=True)
 with zipfile.ZipFile(destination,'w') as z:
  for p in sorted(source.rglob('*')):
   if p.is_file():z.write(p,p.relative_to(source.parent))
 sys.exit(0)
if command=='spctl':
 inside(args[-1]);fail('assess');sys.exit(0)
if command=='shasum':
 if args[:2]!=['-a','256']:reject('unexpected checksum arguments')
 for name in args[2:]:
  p=inside(name)
  print(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+name)
 sys.exit(0)
reject('unknown stub tool')
'''


class PortableInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xeneon-portable-test.")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / "source with spaces"
        self.tools = self.root / "tools"
        self.home = self.root / "private home"
        self.tmp = self.root / "scratch"
        for p in (self.workspace / "Scripts", self.tools, self.home, self.tmp):
            p.mkdir(parents=True)
        for relative in (
            "Scripts/build-portable-installer.sh", "Scripts/install.sh",
            "Scripts/uninstall.sh", "Scripts/prepare-install.swift", "Scripts/PortableInstaller.swift",
            "Resources/com.ajvwhite.MacXeneonEdgeTouchDriver.plist.template",
            "Resources/PortableInstaller/Info.plist", "Resources/PortableInstaller/START-HERE.txt", "LICENSE",
        ):
            destination = self.workspace / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        # A private fixture redirects only the absolute Gatekeeper executable.
        # Production continues to use the system command at its fixed path.
        script = self.workspace / "Scripts/build-portable-installer.sh"
        script.write_text(script.read_text().replace("/usr/sbin/spctl", str(self.tools / "spctl")))
        for name in ("swift", "xcrun", "codesign", "ditto", "shasum", "spctl"):
            tool = self.tools / name
            tool.write_text(STUB)
            tool.chmod(0o755)
        self.env = {
            "PATH": str(self.tools) + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home), "TMPDIR": str(self.tmp),
            "CODESIGN_IDENTITY": IDENTITY, "XENEON_PACKAGE_TEST_ROOT": str(self.root),
        }

    def run_builder(self, *args, failure=None, notarize=False, identity=IDENTITY):
        env = dict(self.env)
        if identity is None:
            env.pop("CODESIGN_IDENTITY", None)
        else:
            env["CODESIGN_IDENTITY"] = identity
        if failure:
            env["XENEON_PACKAGE_TEST_FAILURE"] = failure
        if notarize:
            env["NOTARIZATION_PROFILE"] = "Portable Profile"
        return subprocess.run(
            ["/bin/sh", str(self.workspace / "Scripts/build-portable-installer.sh"), *args],
            env=env, cwd=self.workspace, capture_output=True, text=True, timeout=30,
        )

    def commands(self):
        log = self.root / "commands.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def output(self, arch="universal", directory=None):
        return (directory or self.workspace / "artifacts") / ("MacXeneonEdgeTouchDriver-Installer-" + arch + ".zip")

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("PORTABLE TEST GUARD", result.stdout + result.stderr)

    def assert_clean_scratch(self):
        self.assertEqual(list(self.tmp.iterdir()), [])
        artifacts = self.workspace / "artifacts"
        if artifacts.exists():
            self.assertEqual(list(artifacts.glob(".portable.*")), [])

    def test_help_does_not_require_identity_or_build(self):
        self.assert_success(self.run_builder("--help", identity=None))
        self.assertEqual(self.commands(), [])

    def test_missing_identity_fails_before_build(self):
        result = self.run_builder(identity=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CODESIGN_IDENTITY", result.stderr)
        self.assertEqual(self.commands(), [])

    def test_invalid_arguments_fail_before_build(self):
        for args in (("--arch", "mips"), ("--arch",), ("--output",), ("--unknown",)):
            with self.subTest(args=args):
                self.assertNotEqual(self.run_builder(*args).returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_universal_builds_both_processors_and_combines_every_executable(self):
        self.assert_success(self.run_builder())
        commands = self.commands()
        builds = [c["args"] for c in commands if c["command"] == "swift" and "--product" in c["args"]]
        self.assertEqual([a[a.index("--arch") + 1] for a in builds], ["arm64", "x86_64"])
        compiles = [c["args"] for c in commands if c["command"] == "xcrun" and c["args"][0] == "swiftc"]
        self.assertEqual(len(compiles), 4)
        self.assertEqual(len([c for c in commands if c["command"] == "xcrun" and c["args"][0] == "lipo"]), 3)
        self.assert_clean_scratch()

    def test_single_processor_builds_skip_lipo(self):
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch):
                before = len(self.commands())
                self.assert_success(self.run_builder("--arch", arch))
                commands = self.commands()[before:]
                builds = [c["args"] for c in commands if c["command"] == "swift" and "--product" in c["args"]]
                self.assertEqual([a[a.index("--arch") + 1] for a in builds], [arch])
                self.assertFalse(any(c["command"] == "xcrun" and c["args"][0] == "lipo" for c in commands))
                self.assertTrue(self.output(arch).is_file())

    def test_output_directory_with_spaces(self):
        directory = self.root / "portable output with spaces"
        self.assert_success(self.run_builder("--output", str(directory)))
        self.assertTrue(self.output(directory=directory).is_file())
        self.assertFalse((self.workspace / "artifacts").exists())

    def test_archive_contains_only_portable_app_and_instructions(self):
        (self.workspace / "private-key.p12").write_text("must never be packaged")
        (self.workspace / "config.json").write_text('{"private":"must never be packaged"}')
        (self.workspace / "README.md").write_text("source-only development note")
        self.assert_success(self.run_builder("--arch", "arm64"))
        prefix = "MacXeneonEdgeTouchDriver-Installer-arm64/"
        with zipfile.ZipFile(self.output("arm64")) as z:
            files = set(z.namelist())
            expected = {
                prefix + "START HERE.txt",
                prefix + "Install Xeneon Touch.app/Contents/Info.plist",
                prefix + "Install Xeneon Touch.app/Contents/MacOS/XeneonTouchInstaller",
                prefix + "Install Xeneon Touch.app/Contents/Helpers/MacXeneonEdgeTouchDriver",
                prefix + "Install Xeneon Touch.app/Contents/Helpers/PrepareInstall",
                prefix + "Install Xeneon Touch.app/Contents/Resources/Scripts/install.sh",
                prefix + "Install Xeneon Touch.app/Contents/Resources/Scripts/uninstall.sh",
                prefix + "Install Xeneon Touch.app/Contents/Resources/com.ajvwhite.MacXeneonEdgeTouchDriver.plist.template",
                prefix + "Install Xeneon Touch.app/Contents/Resources/START HERE.txt",
                prefix + "Install Xeneon Touch.app/Contents/Resources/LICENSE.txt",
            }
            self.assertEqual(files, expected)
            installer = z.read(prefix + "Install Xeneon Touch.app/Contents/Resources/Scripts/install.sh")
            self.assertIn(b"--prebuilt", installer)
            plist = plistlib.loads(z.read(prefix + "Install Xeneon Touch.app/Contents/Info.plist"))
            self.assertEqual(plist["CFBundleExecutable"], "XeneonTouchInstaller")
            self.assertNotIn(b"must never be packaged", b"".join(z.read(name) for name in files))

    def test_checksum_matches_the_final_zip(self):
        self.assert_success(self.run_builder())
        archive = self.output()
        checksum = archive.with_name(archive.name + ".sha256").read_text()
        self.assertEqual(checksum.split()[0], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertIn(archive.name, checksum)

    def test_prefix_remapping_and_stripping_requested(self):
        self.assert_success(self.run_builder("--arch", "arm64"))
        commands = self.commands()
        builds = [c["args"] for c in commands if c["command"] == "swift" and "--product" in c["args"]]
        self.assertTrue(all("-file-prefix-map" in a and "-debug-prefix-map" in a for a in builds))
        self.assertEqual(len([c for c in commands if c["command"] == "xcrun" and c["args"][0] == "strip"]), 3)

    def test_failed_steps_preserve_previous_archive_and_checksum(self):
        for failure in ("build", "helper-build", "app-build", "sign", "verify", "archive", "notary-1", "notary-2", "notary-rejected-1", "notary-rejected-2", "notary-malformed-1", "private-path", "staple", "validate", "assess"):
            with self.subTest(failure=failure):
                archive = self.output()
                archive.parent.mkdir(exist_ok=True)
                archive.write_bytes(b"previous portable installer")
                checksum = archive.with_name(archive.name + ".sha256")
                checksum.write_bytes(b"previous checksum")
                submissions = self.root / "submissions.json"
                if submissions.exists():
                    submissions.unlink()
                result = self.run_builder(failure=failure, notarize=failure.startswith("notary") or failure in ("staple", "validate", "assess"))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(archive.read_bytes(), b"previous portable installer")
                self.assertEqual(checksum.read_bytes(), b"previous checksum")
                self.assert_clean_scratch()

    def test_ad_hoc_identity_cannot_make_a_portable_installer(self):
        self.assertNotEqual(self.run_builder(identity="-").returncode, 0)
        self.assertFalse(self.output().exists())
        self.assert_clean_scratch()

    def test_notarization_approves_payload_then_app_and_rebuilds_after_stapling(self):
        self.assert_success(self.run_builder(notarize=True))
        submissions = json.loads((self.root / "submissions.json").read_text())
        self.assertEqual(len(submissions), 2)
        self.assertFalse(any(".app/" in name for name in submissions[0]["entries"]), submissions[0])
        self.assertTrue(any(".app/" in name for name in submissions[1]["entries"]), submissions[1])
        commands = self.commands()
        submit_indices = [i for i,c in enumerate(commands) if c["command"] == "xcrun" and c["args"][:2] == ["notarytool", "submit"]]
        app_sign_index = next(i for i,c in enumerate(commands) if c["command"] == "codesign" and "--sign" in c["args"] and c["args"][-1].endswith(".app"))
        staple_index = next(i for i,c in enumerate(commands) if c["command"] == "xcrun" and c["args"][:2] == ["stapler", "staple"])
        archive_indices = [i for i,c in enumerate(commands) if c["command"] == "ditto"]
        self.assertLess(submit_indices[0], app_sign_index)
        self.assertLess(app_sign_index, submit_indices[1])
        self.assertLess(submit_indices[1], staple_index)
        self.assertLess(staple_index, archive_indices[-1])
        self.assertEqual(commands[-2]["command"], "spctl")
        self.assertEqual(commands[-1]["command"], "shasum")
        self.assertTrue(self.output().exists())
        self.assert_clean_scratch()

    def test_signed_only_build_does_not_contact_notary_or_staple(self):
        result = self.run_builder()
        self.assert_success(result)
        self.assertIn("Signed only", result.stdout)
        self.assertFalse(any(c["command"] == "xcrun" and c["args"][0] in ("notarytool", "stapler") for c in self.commands()))


if __name__ == "__main__":
    unittest.main()
