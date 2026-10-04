#!/usr/bin/env python3
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path(__file__).resolve().parents[2]
prefix = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'kido'
scratch = root / 'app/build/bundle'
scratch.mkdir(parents=True, exist_ok=True)
with (scratch / 'install.lock').open('w') as lock:
    deadline = time.monotonic() + 600
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise RuntimeError('Timed out waiting for kido install')
            time.sleep(0.1)
    shutil.rmtree(prefix, ignore_errors=True)
    env = {key: os.environ[key] for key in ('HOME', 'PATH', 'TMPDIR', 'DEVELOPER_DIR') if key in os.environ}
    xcode = str(Path(env['DEVELOPER_DIR']).parent) + '/'
    env['PATH'] = ':'.join(path for path in env['PATH'].split(':')
                           if not path.startswith((xcode, '/var/run/com.apple.security.cryptexd/mnt/')))
    subprocess.run(['make', 'install', f'PREFIX={prefix}', 'SELF_CONTAINED=1'], cwd=root, env=env, check=True, timeout=600)
    (prefix / 'BUILD-ID').write_bytes(subprocess.check_output([prefix / 'bin/kido', '--version']))
    for binary in (prefix / 'bin').iterdir():
        subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
