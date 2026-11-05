#!/usr/bin/env python3
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path(__file__).resolve().parents[2]
ko = Path(os.environ['KO_CHECKOUT'])
prefix = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'ko'
release = os.environ['CONFIGURATION'] == 'Release'
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
    targets = ['build', 'build-linux', 'check-static', 'LINUX_ARCHS=aarch64'] if release else ['build']
    subprocess.run(['make', '-C', str(ko), *targets], env=env, check=True, timeout=900)
    digest = hashlib.sha256(os.environ['CONFIGURATION'].encode())
    digest.update(identity.encode())
    digest.update(Path(__file__).read_bytes())
    for source in sorted((ko / 'build/ko').rglob('*')):
        relative = source.relative_to(ko / 'build/ko')
        if 'linux' in relative.parts and (not release or relative.parts[:4] != ('share', 'ko', 'linux', 'aarch64')):
            continue
        digest.update(str(relative).encode() + b'\0')
        digest.update(str(source.lstat().st_mode).encode() + b'\0')
        if source.is_symlink():
            digest.update(os.readlink(source).encode())
        elif source.is_file():
            digest.update(source.read_bytes())
    stamp = scratch / (hashlib.sha256(str(prefix).encode()).hexdigest() + '.sha256')
    fingerprint = digest.hexdigest()
    if prefix.is_dir() and stamp.is_file() and stamp.read_text() == fingerprint:
        raise SystemExit(0)
    shutil.rmtree(prefix, ignore_errors=True)
    shutil.copytree(ko / 'build/ko', prefix, symlinks=True, ignore=shutil.ignore_patterns('linux'))
    if release:
        shutil.copytree(ko / 'build/ko/share/ko/linux/aarch64',
                        prefix / 'share/ko/linux/aarch64', symlinks=True)
    (prefix / 'BUILD-ID').write_bytes(subprocess.check_output([prefix / 'bin/ko', 'version']))
    for binary in prefix.rglob('*'):
        if binary.is_file() and not binary.is_symlink():
            kind = subprocess.check_output(['file', '--brief', str(binary)], text=True)
            if 'Mach-O' in kind:
                subprocess.run(['codesign', '--force', '--sign', identity, str(binary)], check=True)
    stamp.write_text(fingerprint)
