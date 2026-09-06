import pathlib
import subprocess
import tempfile
import unittest


class BundleRootTests(unittest.TestCase):
    helper = pathlib.Path(__file__).with_name('bundle-root.sh')

    def locate(self, root, module='AbbeyQuasarKit'):
        return subprocess.run(['sh', str(self.helper), module, str(root)],
                              capture_output=True, text=True)

    def test_packaged_resource_layouts(self):
        for layout in ['.resources', '.bundle', '.bundle/Contents/Resources']:
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temporary:
                expected = pathlib.Path(temporary) / ('AbbeyBot_AbbeyQuasarKit' + layout)
                expected.mkdir(parents=True)
                (expected / 'next-site.manifest.json').write_text('{}')
                result = self.locate(temporary)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), str(expected))

    def test_missing_payload_and_unknown_module_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            (pathlib.Path(temporary) / 'AbbeyBot_AbbeyQuasarKit.bundle').mkdir()
            self.assertNotEqual(self.locate(temporary).returncode, 0)
            self.assertNotEqual(self.locate(temporary, '../Other').returncode, 0)

    def test_ambiguous_bundles_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            for suffix in ['bundle', 'resources']:
                root = pathlib.Path(temporary) / ('AbbeyBot_AbbeyQuasarKit.' + suffix)
                root.mkdir()
                (root / 'next-site.manifest.json').write_text('{}')
            self.assertNotEqual(self.locate(temporary).returncode, 0)


if __name__ == '__main__':
    unittest.main()
