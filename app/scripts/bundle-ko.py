#!/usr/bin/env python3
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path(__file__).resolve().parents[2]
ko = Path(os.environ['KO_CHECKOUT'])
prefix = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'ko'
identity = os.environ['EXPANDED_CODE_SIGN_IDENTITY']
if not identity:
    raise RuntimeError('No code signing identity selected')
scratch = root / 'app/build/bundle'
scratch.mkdir(parents=True, exist_ok=True)
with (scratch / 'ko-install.lock').open('w') as lock:
    deadline = time.monotonic() + 900
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise RuntimeError('Timed out waiting for the ko build')
            time.sleep(0.1)
    env = {key: os.environ[key] for key in ('HOME', 'PATH', 'TMPDIR', 'DEVELOPER_DIR') if key in os.environ}
    xcode = str(Path(env['DEVELOPER_DIR']).parent) + '/'
    env['PATH'] = ':'.join(path for path in env['PATH'].split(':')
                           if not path.startswith((xcode, '/var/run/com.apple.security.cryptexd/mnt/')))
    subprocess.run(['make', '-C', str(ko), 'build-ko'], env=env, check=True, timeout=900)
    shutil.rmtree(prefix, ignore_errors=True)
    shutil.copytree(ko / 'build/ko', prefix, symlinks=True)
    (prefix / 'BUILD-ID').write_bytes(subprocess.check_output([prefix / 'bin/ko', 'version']))
    for binary in prefix.rglob('*'):
        if binary.is_file() and not binary.is_symlink():
            kind = subprocess.check_output(['file', '--brief', str(binary)], text=True)
            if 'Mach-O' in kind:
                subprocess.run(['codesign', '--force', '--sign', identity, str(binary)], check=True)
