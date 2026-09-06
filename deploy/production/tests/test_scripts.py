#!/usr/bin/env python3
"""Exercise real rollout scripts with isolated state and fake external services."""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OLD = 'ghcr.io/donaldfilimon/abbeybot@sha256:' + '1' * 64
NEW = 'ghcr.io/donaldfilimon/abbeybot@sha256:' + '2' * 64
CADDY = 'ghcr.io/donaldfilimon/abbeybot-caddy@sha256:' + '3' * 64
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, tarfile, io
args=sys.argv[1:]; root=pathlib.Path(os.environ['FAKE_STATE'])
with (root/'calls').open('a') as f: f.write(json.dumps([pathlib.Path(sys.argv[0]).name]+args)+'\n')
fail=os.environ.get('FAIL','')
if pathlib.Path(sys.argv[0]).name=='restic':
    if fail=='upload' and 'backup' in args: sys.exit(1)
    if fail=='repository' and 'cat' in args: sys.exit(1)
    print('{}'); sys.exit(0)
if args[:2]==['compose','version'] or args==['info']: sys.exit(0)
if args[0]=='pull':
    if fail=='pull': sys.exit(1)
    sys.exit(0)
if args[:2]==['volume','ls']:
    if os.environ.get('EXISTING','1')=='1': print('abbeybot_quasar')
    sys.exit(0)
if args[:2]==['volume','create']: print(args[-1]); sys.exit(0)
if args[:2]==['image','inspect']:
    digit=args[-1][-1]; print('sha256:'+{'1':'a','2':'b','3':'c','4':'d'}[digit]*64); sys.exit(0)
if args[0]=='inspect':
    if args[2]=='{{.State.Running}} {{.Image}}':
        print('true sha256:'+('a' if args[-1]=='abbey-container' else 'c')*64); sys.exit(0)
    if fail=='application-health-always' and args[-1]=='abbey-container':
        print('unhealthy'); sys.exit(0)
    if (fail=='health' or (fail=='application-health' and args[-1]=='abbey-container')) and not (root/'health-failed').exists():
        (root/'health-failed').touch(); print('unhealthy')
    else: print('healthy')
    sys.exit(0)
if args[0]=='compose':
    args=args[args.index('--file')+2:]
    if args[0]=='pull' and fail=='pull': sys.exit(1)
    if args[0]=='config' and fail=='config': sys.exit(1)
    if args[0]=='ps': print(args[-1]+'-container') if os.environ.get('EXISTING','1')=='1' or (root/'started').exists() else None
    if args[0]=='up': (root/'started').touch()
    if args[0]=='exec':
        command=args[-1]
        if 'pg_dump' in command: sys.stdout.write('checkpoint database')
        if 'pg_restore' in command:
            data=sys.stdin.read(); (root/'live-db').write_text(data)
            if fail=='all-restores': sys.exit(1)
            if fail=='restore' and not (root/'restore-failed').exists():
                (root/'restore-failed').touch(); sys.exit(1)
    sys.exit(0)
if args[0]=='run':
    if '--detach' in args: print('validation-container'); sys.exit(0)
    mounts=[args[i+1] for i,a in enumerate(args) if a=='--volume']
    backup=next((x.split(':')[0] for x in mounts if ':/backup' in x),None)
    if '-czf' in args:
        state=any('abbeybot_state:' in x for x in mounts)
        name='state.tar.gz' if state else 'quasar.tar.gz'
        with tarfile.open(pathlib.Path(backup)/name,'w:gz') as t:
            b=b'checkpoint Abbey state' if state else b'checkpoint workspace'; h=tarfile.TarInfo('state' if state else 'site/data'); h.size=len(b); t.addfile(h,io.BytesIO(b))
    if any(':/restore' in x for x in mounts):
        state=any('abbeybot_state:' in x for x in mounts)
        with tarfile.open(pathlib.Path(backup)/('state.tar.gz' if state else 'quasar.tar.gz')) as t:
            (root/('live-state' if state else 'live-quasar')).write_bytes(t.extractfile('state' if state else 'site/data').read())
        if state and fail=='state-extract' and not (root/'state-failed').exists():
            (root/'state-failed').touch(); sys.exit(1)
    sys.exit(0)
if args[0]=='exec':
    if 'pg_restore' in ' '.join(args):
        sys.stdin.read()
        if fail=='validate': sys.exit(1)
    sys.exit(0)
if args[0] in ['rm','volume']: sys.exit(0)
sys.exit('unsupported fake Docker invocation: '+repr(args))
'''

class RolloutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.deploy = self.base / 'production'
        shutil.copytree(ROOT, self.deploy, ignore=shutil.ignore_patterns('.env', '.backup.env', 'backups', '__pycache__'))
        self.bin = self.base/'bin'; self.bin.mkdir()
        for name in ['docker', 'restic']:
            file=self.bin/name; file.write_text(FAKE); file.chmod(0o755)
        # macOS also runs this suite; flock is a Linux runtime prerequisite.
        flock=self.bin/'flock'; flock.write_text('#!/bin/sh\nexit 0\n'); flock.chmod(0o755)
        (self.deploy/'.env').write_text(f'ABBEYBOT_IMAGE={OLD}\nABBEY_CADDY_IMAGE={CADDY}\n')
        self.password=self.base/'password'; self.password.write_text('synthetic-test-password'); self.password.chmod(0o600)
        self.backup_env=self.deploy/'.backup.env'
        self.backup_env.write_text(f'RESTIC_REPOSITORY=s3:https://account.r2.cloudflarestorage.com/bucket/abbey\nRESTIC_PASSWORD_FILE={self.password}\nAWS_ACCESS_KEY_ID=test-id\nAWS_SECRET_ACCESS_KEY=test-secret\n')
        self.backup_env.chmod(0o600)
        self.env=dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'], FAKE_STATE=str(self.base))
        self.archive=self.base/'archive'; self.archive.mkdir()
        (self.archive/'postgres.dump').write_text('requested database')
        with tarfile.open(self.archive/'quasar.tar.gz','w:gz') as t:
            b=b'requested workspace'; h=tarfile.TarInfo('site/data'); h.size=len(b); t.addfile(h,io.BytesIO(b))
        with tarfile.open(self.archive/'state.tar.gz','w:gz') as t:
            b=b'requested Abbey state'; h=tarfile.TarInfo('state'); h.size=len(b); t.addfile(h,io.BytesIO(b))
        (self.archive/'manifest.env').write_text(f'ABBEYBOT_IMAGE={NEW}\nABBEY_CADDY_IMAGE={CADDY}\n')
        self.checksums()
    def tearDown(self): self.tmp.cleanup()
    def checksums(self):
        import hashlib
        (self.archive/'SHA256SUMS').write_text(''.join(hashlib.sha256((self.archive/n).read_bytes()).hexdigest()+'  '+n+'\n' for n in ['postgres.dump','quasar.tar.gz','state.tar.gz','manifest.env']))
    def run_script(self, script, *args, **env):
        return subprocess.run(['bash',str(self.deploy/'scripts'/script),*map(str,args)], env=dict(self.env,**env),text=True,capture_output=True,timeout=20)
    def calls(self):
        p=self.base/'calls'; return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []
    def stopped(self): return any('stop' in c for c in self.calls())
    def assert_image_mismatch_refused(self, script, service):
        file=self.deploy/'.env'
        file.write_text(file.read_text().replace(OLD,NEW) if service=='abbey' else file.read_text().replace(CADDY,'ghcr.io/donaldfilimon/abbeybot-caddy@sha256:'+'4'*64))
        args={'backup.sh':(), 'deploy.sh':(NEW,CADDY), 'restore.sh':(self.archive,)}[script]
        result=self.run_script(script,*args)
        self.assertNotEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.stopped())
        self.assertFalse((self.deploy/'backups').exists())
        self.assertFalse(any('pg_dump' in ' '.join(c) for c in self.calls()))
    def test_backup_rejects_abbey_image_mismatch(self): self.assert_image_mismatch_refused('backup.sh','abbey')
    def test_backup_rejects_caddy_image_mismatch(self): self.assert_image_mismatch_refused('backup.sh','caddy')
    def test_upgrade_rejects_abbey_image_mismatch(self): self.assert_image_mismatch_refused('deploy.sh','abbey')
    def test_upgrade_rejects_caddy_image_mismatch(self): self.assert_image_mismatch_refused('deploy.sh','caddy')
    def test_restore_rejects_abbey_image_mismatch(self): self.assert_image_mismatch_refused('restore.sh','abbey')
    def test_restore_rejects_caddy_image_mismatch(self): self.assert_image_mismatch_refused('restore.sh','caddy')
    def test_matching_running_images_label_checkpoint_correctly(self):
        result=self.run_script('backup.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        manifest=next((self.deploy/'backups').glob('*/manifest.env')).read_text()
        self.assertIn('ABBEYBOT_IMAGE='+OLD,manifest)
        self.assertIn('ABBEY_CADDY_IMAGE='+CADDY,manifest)
        self.assertEqual(sum(c[:3]==['docker','image','inspect'] for c in self.calls()),2)
    def test_failed_rollback_health_keeps_ingress_stopped(self):
        result=self.run_script('deploy.sh',NEW,CADDY,FAIL='application-health-always')
        self.assertNotEqual(result.returncode,0)
        calls=self.calls(); last_health=max(i for i,c in enumerate(calls) if 'inspect' in c)
        self.assertTrue(any('stop' in c for c in calls[last_health+1:]))
    def test_invalid_compose_configuration_refuses_before_interruption(self):
        result=self.run_script('backup.sh',FAIL='config')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_partial_state_restore_failure_rolls_back_all_three_stores(self):
        result=self.run_script('restore.sh',self.archive,FAIL='state-extract')
        self.assertNotEqual(result.returncode,0)
        for name, expected in [('live-db','checkpoint database'),('live-quasar','checkpoint workspace'),('live-state','checkpoint Abbey state')]:
            self.assertEqual((self.base/name).read_text(),expected)
    def test_missing_abbey_state_archive_refuses_before_interruption(self):
        (self.archive/'state.tar.gz').unlink()
        result=self.run_script('restore.sh',self.archive)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_nonprivate_backup_config_refuses_before_interruption(self):
        self.backup_env.chmod(0o644)
        result=self.run_script('backup.sh')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_repository_init_is_explicit_and_never_stops_service(self):
        result=self.run_script('backup-store.sh','init',FAIL='repository')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(any(c[0]=='restic' and 'init' in c for c in self.calls()))
        self.assertFalse(self.stopped())
    def test_remote_fetch_refuses_existing_destination(self):
        result=self.run_script('backup-store.sh','fetch','latest',self.archive)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[0]=='restic' and 'restore' in c for c in self.calls()))
    def test_unhealthy_backup_restart_reports_failure(self):
        result=self.run_script('backup.sh',FAIL='application-health')
        self.assertNotEqual(result.returncode,0)
        self.assertTrue(list((self.deploy/'backups').glob('*/SHA256SUMS')))
    def test_upgrade_health_failure_restores_data_and_image(self):
        result=self.run_script('deploy.sh',NEW,CADDY,FAIL='application-health')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.base/'live-db').read_text(),'checkpoint database')
        self.assertEqual((self.base/'live-quasar').read_text(),'checkpoint workspace')
        self.assertEqual((self.base/'live-state').read_text(),'checkpoint Abbey state')
        self.assertIn(OLD,(self.deploy/'.env').read_text())
    def test_rollback_failure_leaves_application_stopped(self):
        result=self.run_script('restore.sh',self.archive,FAIL='all-restores')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('rollback failed',result.stderr)
        calls=self.calls(); last_restore=max(i for i,c in enumerate(calls) if 'pg_restore' in ' '.join(c))
        self.assertFalse(any('up' in c and 'abbey' in c for c in calls[last_restore+1:]))
    def test_backup_does_not_overwrite_existing_directory(self):
        result=self.run_script('backup.sh',self.archive)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.archive/'postgres.dump').read_text(),'requested database')
        self.assertFalse(self.stopped())
    def test_unavailable_remote_repository_refuses_before_stop(self):
        result=self.run_script('backup.sh',FAIL='repository')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_backup_secrets_never_enter_docker_arguments(self):
        result=self.run_script('backup.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(any(c[0]=='restic' and 'backup' in c for c in self.calls()))
        self.assertNotIn('test-secret',json.dumps(self.calls()))
    def test_symbolic_link_archive_rejected_before_interruption(self):
        with tarfile.open(self.archive/'quasar.tar.gz','w:gz') as t:
            h=tarfile.TarInfo('site/escape'); h.type=tarfile.SYMTYPE; h.linkname='/etc'; t.addfile(h)
        self.checksums()
        result=self.run_script('restore.sh',self.archive)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_pull_failure_never_interrupts_service(self):
        result=self.run_script('deploy.sh',NEW,CADDY,FAIL='pull')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped(),result.stderr)
        self.assertIn(OLD,(self.deploy/'.env').read_text())
    def test_missing_backup_config_refuses_before_stop(self):
        self.backup_env.unlink()
        result=self.run_script('backup.sh')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_bootstrap_requires_empty_storage(self):
        result=self.run_script('deploy.sh','--bootstrap',NEW,CADDY)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_bootstrap_empty_install_skips_dump(self):
        result=self.run_script('deploy.sh','--bootstrap',NEW,CADDY,EXISTING='0')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any('pg_dump' in ' '.join(c) for c in self.calls()))
        self.assertIn(NEW,(self.deploy/'.env').read_text())
    def test_invalid_dump_rejected_before_interruption(self):
        result=self.run_script('restore.sh',self.archive,FAIL='validate')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_restore_failure_recovers_both_checkpoint_stores(self):
        result=self.run_script('restore.sh',self.archive,FAIL='restore')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.base/'live-db').read_text(),'checkpoint database')
        self.assertEqual((self.base/'live-quasar').read_text(),'checkpoint workspace')
        self.assertEqual((self.base/'live-state').read_text(),'checkpoint Abbey state')
        self.assertIn(OLD,(self.deploy/'.env').read_text())
    def test_upload_failure_keeps_checkpoint_and_restarts_without_restore(self):
        result=self.run_script('restore.sh',self.archive,FAIL='upload')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.base/'live-db').exists())
        self.assertTrue(list((self.deploy/'backups').glob('*/SHA256SUMS')))
        self.assertTrue(any('up' in c for c in self.calls()))
    def test_path_traversal_archive_rejected_before_docker_restore(self):
        with tarfile.open(self.archive/'quasar.tar.gz','w:gz') as t:
            h=tarfile.TarInfo('../outside'); h.size=1; t.addfile(h,io.BytesIO(b'x'))
        self.checksums()
        result=self.run_script('restore.sh',self.archive)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.stopped())
    def test_successful_restore_keeps_checkpoint_and_offhost_copy(self):
        result=self.run_script('restore.sh',self.archive)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.base/'live-db').read_text(),'requested database')
        self.assertEqual((self.base/'live-quasar').read_text(),'requested workspace')
        self.assertEqual((self.base/'live-state').read_text(),'requested Abbey state')
        calls=self.calls(); self.assertTrue(any(c[0]=='restic' and 'backup' in c for c in calls))
        upload=next(i for i,c in enumerate(calls) if c[0]=='restic' and 'backup' in c)
        drop=next(i for i,c in enumerate(calls) if 'dropdb' in ' '.join(c))
        self.assertLess(upload,drop)
        stop=next(i for i,c in enumerate(calls) if 'stop' in c)
        self.assertFalse(any('up' in c and ('abbey' in c or 'caddy' in c) for c in calls[stop+1:drop]))

if __name__=='__main__': unittest.main(verbosity=2)
