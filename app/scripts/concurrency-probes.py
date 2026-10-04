#!/usr/bin/env python3
import os, pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(__file__).resolve().parents[1]
app, probe, name = sys.argv[1:]
out = root / 'build/deadlock-impl' / name
out.mkdir(parents=True, exist_ok=True)
helper_env = {k:v for k,v in os.environ.items() if k not in ('DYLD_INSERT_LIBRARIES', 'MTC_RESET_INSERT_LIBRARIES')}
revision = subprocess.check_output([str(root.parent/'scripts/install-tmux-fork.sh'), '--print-revision'], env=helper_env, text=True, timeout=5).strip()
tmux = root.parent / 'build/tmux-fork' / revision / 'bin/kido-tmux'
server = tempfile.mkdtemp(prefix='kido-probe-', dir='/tmp')
sock = server + '/socket'
def t(*args):
    return subprocess.run([str(tmux), '-S', sock, *args], env=helper_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
p = None
try:
    result = t('new-session', '-d', '-s', 'probe', '-x', '120', '-y', '40', 'for i in $(seq 0 499); do printf "row%s\\n" "$i"; done; sleep 180')
    if result.returncode:
        raise RuntimeError(result.stderr.decode())
    config = out / 'config/kido'
    config.mkdir(parents=True, exist_ok=True)
    (config / 'kido-app.conf').write_text('scrollback-limit = 8388608\n')
    env = {k:v for k,v in helper_env.items() if not k.startswith('KIDO_AGENT_') and k not in ('TMUX', 'TMUX_PANE', 'KIDO_STATE_DIR')}
    env.update(KIDO_APP_BACKGROUND='1', KIDO_APP_SERVER=server, KIDO_APP_TMUX=str(tmux), KIDO_APP_FEED=str(root/'scripts/fake-sidebar-feed.sh'), XDG_CONFIG_HOME=str(out/'config'), ASAN_OPTIONS='use_sigaltstack=0', **{probe:'1'})
    mtc = os.environ.get('KIDO_MTC_VERIFY') == '1'
    if mtc:
        checker = pathlib.Path(os.environ['DEVELOPER_DIR']) / 'usr/lib/libMainThreadChecker.dylib'
        if not checker.is_file():
            raise RuntimeError(f'Main Thread Checker missing: {checker}')
        env.update(DYLD_INSERT_LIBRARIES=str(checker), MTC_RESET_INSERT_LIBRARIES='1')
    with (out/'stderr.log').open('w') as log:
        deadline = time.monotonic() + 25
        p = subprocess.Popen([app], env=env, stdout=log, stderr=log)
        try:
            if mtc:
                with (out/'mapped-images.log').open('w') as images:
                    while p.poll() is None:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise subprocess.TimeoutExpired([app], 25)
                        result = subprocess.run(['/usr/bin/vmmap', '-w', str(p.pid)], env=helper_env, capture_output=True, text=True, timeout=min(5, remaining))
                        images.write(f'PID {p.pid} vmmap exit={result.returncode}\n{result.stdout}{result.stderr}\n')
                        if p.poll() is None and result.returncode == 0 and any('__TEXT' in line and line.rstrip().endswith('/libMainThreadChecker.dylib') for line in result.stdout.splitlines()):
                            break
                        time.sleep(min(0.05, max(0, deadline - time.monotonic())))
                    else:
                        raise RuntimeError('Kido exited before Main Thread Checker mapping was verified')
            p.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            p.kill(); p.wait(timeout=5)
            print('FAIL process deadline 25s', out)
            sys.exit(1)
    text = (out/'stderr.log').read_text()
    if p.returncode or '"passed"' not in text or any(s in text for s in ('WARNING: ThreadSanitizer', 'ERROR: AddressSanitizer', 'Main Thread Checker:', '"failed"')):
        print('FAIL', p.returncode, out, text[-3000:]); sys.exit(1)
    print('PASS', probe, out)
finally:
    if p and p.poll() is None:
        p.kill(); p.wait(timeout=5)
    t('kill-session', '-t', 'probe')
