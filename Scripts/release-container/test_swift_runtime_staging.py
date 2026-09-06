"""Exercise Swift runtime discovery without a toolchain or a container.

The container build can only be verified in CI, so the discovery contract is
pinned here: each source of truth is exercised in isolation with a fake `ldd`
and `swiftc` on PATH, and the failure path is required to name the real layout
rather than exiting silently.

Fixture text is written from Python and read back by `cat`, never embedded in
the shim's shell source. `/bin/sh` is dash on Debian and bash on macOS, and
their `printf` disagree about backslash escapes; the first version of this file
built shim output with `printf` and escaped quotes, passed on macOS, and failed
on the Linux runner because dash emitted literal backslashes into the JSON.
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

    def shim(self, name, output):
        """Put a stand-in for `name` on PATH that prints `output` verbatim."""
        fixture = self.bin / (name + ".fixture")
        fixture.write_text(output)
        path = self.bin / name
        path.write_text('#!/bin/sh\ncat "' + str(fixture) + '"\n')
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def ldd_output(self, runtime_directory, extra=""):
        return "\t" + CORE + " => " + str(runtime_directory / CORE) + " (0x0)\n" + extra

    def target_info(self, *paths, pretty=True):
        quoted = ",\n      ".join('"' + str(path) + '"' for path in paths)
        if pretty:
            return '{\n  "paths": {\n    "runtimeLibraryPaths": [\n      ' + quoted + "\n    ]\n  }\n}\n"
        return '{"paths":{"runtimeLibraryPaths":[' + ",".join('"' + str(p) + '"' for p in paths) + "]}}\n"

    def run_stage(self):
        env = dict(os.environ)
        # Shims must win over any real toolchain on the host or the runner.
        env["PATH"] = str(self.bin) + os.pathsep + env["PATH"]
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
        self.shim("ldd", self.ldd_output(resolved))
        # swiftc reports a different tree; ldd is authoritative and must win.
        self.shim("swiftc", self.target_info(decoy))
        result = self.run_stage()
        self.assert_staged(result)
        self.assertIn(str(resolved), result.stdout)
        self.assertNotIn(str(decoy), result.stdout)

    def test_falls_back_to_the_toolchain_report_when_ldd_is_uninformative(self):
        reported = self.runtime_tree("reported")
        self.shim("ldd", "\tstatically linked\n")
        self.shim("swiftc", self.target_info(reported))
        result = self.run_stage()
        self.assert_staged(result)
        self.assertIn(str(reported), result.stdout)

    def test_reads_a_compact_toolchain_report_and_skips_paths_without_the_core(self):
        reported = self.runtime_tree("reported")
        empty = self.root / "empty"
        empty.mkdir()
        self.shim("ldd", "\tstatically linked\n")
        # The first reported path exists but ships no core library.
        self.shim("swiftc", self.target_info(empty, reported, pretty=False))
        result = self.run_stage()
        self.assert_staged(result)
        self.assertIn(str(reported), result.stdout)

    def test_reports_the_real_layout_instead_of_failing_silently(self):
        self.shim("ldd", "\tstatically linked\n")
        self.shim("swiftc", self.target_info("/nowhere", pretty=False))
        result = self.run_stage()
        self.assertEqual(result.returncode, 1)
        self.assertIn(CORE, result.stderr)
        # A build that fails here must say where it looked, or the next CI round
        # trip learns nothing.
        self.assertIn("searched toolchain trees", result.stderr)
        self.assertIn("runtimeLibraryPaths", result.stderr)

    def test_rejects_an_executable_with_unresolved_libraries(self):
        resolved = self.runtime_tree("resolved")
        self.shim("ldd", self.ldd_output(resolved, "\tlibmissing.so => not found\n"))
        result = self.run_stage()
        self.assertEqual(result.returncode, 1)
        self.assertIn("libmissing.so", result.stderr)

    def test_refuses_a_non_empty_stage_directory(self):
        resolved = self.runtime_tree("resolved")
        self.stage.mkdir()
        (self.stage / "leftover").write_text("stale")
        self.shim("ldd", self.ldd_output(resolved))
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
