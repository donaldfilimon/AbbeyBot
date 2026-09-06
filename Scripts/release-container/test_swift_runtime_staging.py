"""Exercise Swift runtime discovery without a toolchain or a container.

The container build can only be verified in CI, so the discovery contract is
pinned here: each source of truth is exercised in isolation with a fake `ldd`
and `swiftc` on PATH, and the failure path is required to name the real layout
rather than exiting silently.
"""
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest


STAGER = pathlib.Path(__file__).with_name("stage-swift-runtime.sh")
CORE = "libswiftCore.so"


class SwiftRuntimeStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.bin = self.root / "fake-bin"
        self.bin.mkdir()
        self.stage = self.root / "stage-runtime"
        self.executable = self.root / "AbbeyBot"
        self.executable.write_text("#!/bin/sh\nprintf 'abbey-ok'\n")
        self.executable.chmod(0o755)

    def runtime_tree(self, name="swift-linux"):
        """A runtime directory with the core library and a versioned symlink."""
        directory = self.root / name
        directory.mkdir()
        (directory / CORE).write_text("core")
        (directory / "libFoundation.so").write_text("foundation")
        (directory / "libswiftCore.so.6").symlink_to(CORE)
        return directory

    def shim(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def run_stage(self, path_first=True):
        env = dict(os.environ)
        # Shims must win over any real toolchain on this host.
        env["PATH"] = f"{self.bin}{os.pathsep}{env['PATH']}" if path_first else str(self.bin)
        return subprocess.run(
            ["bash", str(STAGER), str(self.executable), str(self.stage)],
            capture_output=True, text=True, check=False, env=env,
        )

    def assert_staged(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.stage / CORE).is_file())
        self.assertTrue((self.stage / "libFoundation.so").is_file())
        # The loader follows versioned symlinks; staging must keep them as links.
        self.assertTrue((self.stage / "libswiftCore.so.6").is_symlink())

    def test_prefers_the_directory_the_executable_actually_resolved(self):
        resolved = self.runtime_tree("resolved")
        decoy = self.runtime_tree("decoy-reported")
        self.shim("ldd", f"printf '\\t{CORE} => {resolved}/{CORE} (0x0)\\n'\n")
        # swiftc reports a different tree; ldd is authoritative and must win.
        self.shim("swiftc", f'printf \'{{"paths":{{"runtimeLibraryPaths":["{decoy}"]}}}}\\n\'\n')
        result = self.run_stage()
        self.assert_staged(result)
        self.assertIn(str(resolved), result.stdout)

    def test_falls_back_to_the_toolchain_report_when_ldd_is_uninformative(self):
        reported = self.runtime_tree("reported")
        self.shim("ldd", "printf '\\tstatically linked\\n'\n")
        self.shim(
            "swiftc",
            "printf '{\\n  \"paths\": {\\n    \"runtimeLibraryPaths\": [\\n"
            f'      \\"{reported}\\"\\n' "    ]\\n  }\\n}\\n'\n",
        )
        result = self.run_stage()
        self.assert_staged(result)
        self.assertIn(str(reported), result.stdout)

    def test_reports_the_real_layout_instead_of_failing_silently(self):
        self.shim("ldd", "printf '\\tstatically linked\\n'\n")
        self.shim("swiftc", "printf '{\"paths\":{\"runtimeLibraryPaths\":[\"/nowhere\"]}}\\n'\n")
        result = self.run_stage()
        self.assertEqual(result.returncode, 1)
        self.assertIn(CORE, result.stderr)
        # A build that fails here must say where it looked, or the next CI round
        # trip learns nothing.
        self.assertIn("searched toolchain trees", result.stderr)
        self.assertIn("swiftc", result.stderr)

    def test_rejects_an_executable_with_unresolved_libraries(self):
        resolved = self.runtime_tree("resolved")
        self.shim(
            "ldd",
            f"printf '\\t{CORE} => {resolved}/{CORE} (0x0)\\n"
            "\\tlibmissing.so => not found\\n'\n",
        )
        result = self.run_stage()
        self.assertEqual(result.returncode, 1)
        self.assertIn("libmissing.so", result.stderr)

    def test_refuses_a_non_empty_stage_directory(self):
        self.runtime_tree("resolved")
        self.stage.mkdir()
        (self.stage / "leftover").write_text("stale")
        self.shim("ldd", f"printf '\\t{CORE} => {self.root}/resolved/{CORE} (0x0)\\n'\n")
        result = self.run_stage()
        self.assertEqual(result.returncode, 1)
        self.assertIn("must be empty", result.stderr)

    def test_requires_both_arguments(self):
        result = subprocess.run(
            ["bash", str(STAGER), str(self.executable)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
