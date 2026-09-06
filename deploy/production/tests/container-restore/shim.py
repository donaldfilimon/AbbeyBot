#!/usr/bin/env python3
"""Test boundary only: isolate Docker resources; delegate data/SQL/archive operations unchanged.

The restic command uses an encrypted local Docker-backed repository, never R2.
Production scripts are copied byte-for-byte; GHCR aliases represent unpublished CI images.
"""
import os
from pathlib import Path
import subprocess
import sys

ALIASES = {
    'ghcr.io/donaldfilimon/abbeybot@sha256:'+'1'*64: 'RESTORE_GATE_ABBEY_IMAGE',
    'ghcr.io/donaldfilimon/abbeybot-caddy@sha256:'+'2'*64: 'RESTORE_GATE_CADDY_IMAGE',
}


def map_argument(value, env):
    if value in ALIASES:
        return env[ALIASES[value]]
    if value.startswith('ghcr.io/donaldfilimon/') and '@sha256:' in value:
        raise ValueError('unexpected registry digest outside this fixture')
    prefix, separator, suffix = value.partition(':')
    if prefix in ('abbeybot_quasar', 'abbeybot_state'):
        return env['RESTORE_GATE_ID'] + '_' + prefix.removeprefix('abbeybot_') + separator + suffix
    if prefix.startswith('abbeybot_'):
        raise ValueError('unexpected production volume outside this fixture')
    if prefix.startswith('abbey-restore-check-'):
        return env['RESTORE_GATE_ID'] + '-' + value
    return value


def validate_compose(args, env):
    if args[:2] == ['compose', 'version']:
        return
    for flag, expected in [('--project-directory', env['RESTORE_GATE_ROOT']+'/production'),
                           ('--env-file', env['RESTORE_GATE_ROOT']+'/production/.env'),
                           ('--file', env['RESTORE_GATE_ROOT']+'/production/compose.yml')]:
        if flag not in args or args[args.index(flag)+1] != expected:
            raise ValueError('refusing Compose outside disposable restore fixture')


def main():
    args = sys.argv[1:]
    env = dict(os.environ)
    root = Path(env['RESTORE_GATE_ROOT'])
    real_docker = env['RESTORE_GATE_REAL_DOCKER']
    if Path(sys.argv[0]).name == 'restic':
        # Ignore the deliberately synthetic R2 credentials supplied by production preflight.
        # Restic really encrypts, checks and restores its repository on disposable local disk.
        command = [real_docker, 'run', '--rm', '--network', 'none', '--hostname', 'abbey-restore-gate',
                   '--user', f'{os.getuid()}:{os.getgid()}', '--volume', f'{root}:{root}',
                   '--env', 'RESTIC_PASSWORD=synthetic-local-release-password',
                   env['RESTORE_GATE_RESTIC_IMAGE'], '--no-cache', '--repo', str(root/'local-restic'), *args]
        return subprocess.call(command)
    if not args:
        raise ValueError('missing Docker operation')
    if args[0] == 'compose':
        validate_compose(args, env)
        # Shell project selection outranks compose.yml's name; pin it even when inherited.
        env.update(COMPOSE_PROJECT_NAME=env['RESTORE_GATE_ID'],
                   ABBEYBOT_IMAGE=env['RESTORE_GATE_ABBEY_IMAGE'],
                   ABBEY_CADDY_IMAGE=env['RESTORE_GATE_CADDY_IMAGE'])
        if 'stop' in args:
            with (root/'stop-events').open('a') as handle:
                handle.write('stop\n')
    if args[0] == 'pull' and args[1] in ALIASES:
        # Images were built by the release gate and have not been pushed yet.
        return subprocess.call([real_docker, 'image', 'inspect', '--format', '{{.Id}}', map_argument(args[1],env)])
    inject_after_state = args[0] == 'run' and 'abbeybot_state:/restore' in args and (root/'fail-state-once').exists()
    result = subprocess.call([real_docker, *[map_argument(arg,env) for arg in args]], env=env)
    if result == 0 and inject_after_state:
        (root/'fail-state-once').unlink()
        print('RESTORE_GATE_INJECTED: failure after real state extraction', file=sys.stderr)
        return 97
    return result


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyError, ValueError) as error:
        sys.exit(f'RESTORE_GATE_SHIM_FAIL: {error}')
