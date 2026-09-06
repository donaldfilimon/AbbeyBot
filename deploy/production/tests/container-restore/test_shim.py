import importlib.util
import pathlib
import os
from unittest.mock import patch
import unittest

class MappingTests(unittest.TestCase):
    def setUp(self):
        path = pathlib.Path(__file__).with_name('shim.py')
        self.assertTrue(path.is_file(), 'the isolation shim must exist')
        spec = importlib.util.spec_from_file_location('shim', path)
        self.shim = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.shim)
        self.env = {'RESTORE_GATE_ROOT':'/private/gate', 'RESTORE_GATE_ID':'restore-test',
                    'RESTORE_GATE_ABBEY_IMAGE':'release:tested', 'RESTORE_GATE_CADDY_IMAGE':'caddy:tested'}
    def test_fixed_production_volume_isolated_without_changing_mount_flags(self):
        self.assertEqual(self.shim.map_argument('abbeybot_state:/restore:ro',self.env),'restore-test_state:/restore:ro')
        self.assertEqual(self.shim.map_argument('abbeybot_quasar:/source:ro',self.env),'restore-test_quasar:/source:ro')
    def test_digest_alias_maps_to_tested_image_only(self):
        ref='ghcr.io/donaldfilimon/abbeybot@sha256:'+'1'*64
        self.assertEqual(self.shim.map_argument(ref,self.env),'release:tested')
        with self.assertRaises(ValueError): self.shim.map_argument(ref[:-1]+'2',self.env)
    def test_disposable_probe_names_remain_gate_scoped(self):
        self.assertEqual(self.shim.map_argument('abbey-restore-check-123:/validation',self.env),'restore-test-abbey-restore-check-123:/validation')
    def test_unknown_production_volume_refused(self):
        with self.assertRaises(ValueError): self.shim.map_argument('abbeybot_postgres:/source',self.env)
    def test_other_mount_paths_unchanged(self):
        self.assertEqual(self.shim.map_argument('/private/gate/backup:/backup:ro',self.env),'/private/gate/backup:/backup:ro')
    def test_hostile_inherited_compose_project_name_cannot_select_production(self):
        env=dict(self.env, RESTORE_GATE_REAL_DOCKER='/usr/bin/docker', COMPOSE_PROJECT_NAME='production')
        args=['docker','compose','--project-directory','/private/gate/production',
              '--env-file','/private/gate/production/.env','--file','/private/gate/production/compose.yml','ps']
        with patch.dict(os.environ, env), patch.object(self.shim.sys, 'argv', args), patch.object(self.shim.subprocess, 'call', return_value=0) as docker:
            self.assertEqual(self.shim.main(),0)
        self.assertEqual(docker.call_args.kwargs['env']['COMPOSE_PROJECT_NAME'],'restore-test')
    def test_foreign_compose_project_refused(self):
        with self.assertRaises(ValueError):
            self.shim.validate_compose(['compose','--project-directory','/production','ps'],self.env)

if __name__ == '__main__': unittest.main(verbosity=2)
