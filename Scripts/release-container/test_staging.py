"""Exercise staging contracts without compiling the full application."""
import pathlib
import subprocess
import tempfile
import unittest


STAGER = pathlib.Path(__file__).with_name("stage-products.sh")


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.products = self.root / "reported products directory"
        self.products.mkdir()
        self.stage = self.root / "stage"
        executable = self.products / "probe"
        executable.write_text("#!/bin/sh\nprintf 'probe-ok'\n")
        executable.chmod(0o755)

    def bundle(self, name):
        bundle = self.products / name
        bundle.mkdir()
        (bundle / "marker").write_text(name)

    def run_stage(self):
        return subprocess.run(
            ["bash", str(STAGER), str(self.products), str(self.stage), "probe", "Package_Library"],
            capture_output=True, text=True, check=False,
        )

    def test_preserves_both_supported_names_and_dependency_resources(self):
        for suffix in ("bundle", "resources"):
            with self.subTest(suffix=suffix):
                self.bundle(f"Package_Library.{suffix}")
                self.bundle(f"Dependency_Assets.{suffix}")
                result = self.run_stage()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    sorted(path.name for path in self.stage.iterdir()),
                    [f"Dependency_Assets.{suffix}", f"Package_Library.{suffix}", "probe"],
                )
                self.assertEqual(subprocess.check_output([str(self.stage / "probe")], text=True), "probe-ok")
                # Each subtest gets a fresh destination and products directory.
                import shutil
                shutil.rmtree(self.stage)
                shutil.rmtree(self.products / f"Package_Library.{suffix}")
                shutil.rmtree(self.products / f"Dependency_Assets.{suffix}")

    def test_missing_required_bundle_fails_before_staging(self):
        self.assertNotEqual(self.run_stage().returncode, 0)
        self.assertFalse(self.stage.exists())

    def test_ambiguous_bundle_fails_before_staging(self):
        self.bundle("Package_Library.bundle")
        self.bundle("Package_Library.resources")
        self.assertNotEqual(self.run_stage().returncode, 0)
        self.assertFalse(self.stage.exists())

    def test_nonempty_destination_is_preserved(self):
        self.bundle("Package_Library.bundle")
        self.stage.mkdir()
        sentinel = self.stage / "existing"
        sentinel.write_text("preserve")
        self.assertNotEqual(self.run_stage().returncode, 0)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertEqual(list(self.stage.iterdir()), [sentinel])


if __name__ == "__main__":
    unittest.main()
