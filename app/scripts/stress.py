#!/usr/bin/env python3
"""Seeded stress run of a KIDO_STRESS build of Kido.app against a private tmux server.

The window stays off screen (KIDO_APP_BACKGROUND=1); see docs/design-app.md, "Stress harness".
"""
import argparse, collections, glob, json, os, random, signal, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument('--app', required=True)
ap.add_argument('--tmux', required=True)
ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--duration', type=float, default=60)
ap.add_argument('--find', type=int, default=1)
ap.add_argument('--out', required=True)
args = ap.parse_args()

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
out = os.path.abspath(args.out)
os.makedirs(out + '/config/kido', exist_ok=True)
sock = '/tmp/kido-stress-%d-%d.sock' % (os.getuid(), os.getpid())
rng = random.Random(args.seed)
counts = collections.Counter()
open(out + '/config/kido/kido-app.conf', 'w').write('scrollback-limit = 8388608\n')
log = open(out + '/actions.jsonl', 'w', buffering=1)


def t(*a):
    try:
        p = subprocess.run([args.tmux, '-S', sock, *a], capture_output=True, text=True, timeout=8)
        if p.returncode:
            log.write(json.dumps(dict(command=a, error=p.stderr.strip())) + '\n')
        return p.stdout.strip()
    except subprocess.TimeoutExpired:
        return ''


def rows(*a):
    return t(*a).splitlines()


def setup(full):
    t('new-session', '-d', '-s', 's1', '-x', '120', '-y', '40')
    t('set-option', '-g', 'history-limit', '1100000')
    t('set-option', '-g', 'remain-on-exit', 'on')
    for s in range(1, 5):
        if s > 1:
            t('new-session', '-d', '-s', f's{s}')
        for w in range(16 if full else 4):
            wid = t('new-window', '-d', '-P', '-F', '#{window_id}', '-t', f's{s}', '-n', f'w{w}')
            for x in range(2):
                t('split-window', '-d', '-h' if x == 0 else '-v', '-t', wid)
            if w == 0:
                t('send-keys', '-t', wid, 'while :; do date; sleep 0.05; done', 'Enter')
    for name, n in [('log-1m', 1000000), ('log-100k', 100000)]:
        wid = t('new-window', '-d', '-P', '-F', '#{window_id}', '-t', 's1', '-n', name)
        t('send-keys', '-t', wid, f"seq 1 {n}; while :; do printf 'INFO built ERROR %s\\n' $RANDOM; sleep 0.03; done", 'Enter')
        t('new-pane', '-d', '-t', f's1:{name}', '-X', '20', '-Y', '5', '-x', '45', '-y', '15')
    t('new-window', '-d', '-t', 's2', '-n', 'seq', 'seq 2000000')
    t('new-window', '-d', '-t', 's3', '-n', 'yes', 'yes | head -50000000')


def reports():
    return set(glob.glob(os.path.expanduser('~/Library/Logs/DiagnosticReports/Kido*.ips')))


def app_children(pid):
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True).splitlines():
        bits = line.split(None, 2)
        if len(bits) == 3 and int(bits[1]) == pid and 'python' in bits[2]:
            yield int(bits[0])


env = {k: v for k, v in os.environ.items() if not k.startswith('KIDO_AGENT_') and k not in ('TMUX', 'TMUX_PANE')}
env.update(KIDO_APP_BACKGROUND='1', KIDO_APP_SOCKET=sock, KIDO_APP_TMUX=args.tmux,
           KIDO_APP_FEED=root + '/app/scripts/fake-sidebar-feed.sh', XDG_CONFIG_HOME=out + '/config',
           STRESS_SEED=str(args.seed), STRESS_DURATION=str(args.duration))
if not args.find:
    env['STRESS_NO_FIND'] = '1'
if 'ASAN_OPTIONS' not in env:
    env['ASAN_OPTIONS'] = 'use_sigaltstack=0'

before = reports()
setup(True)
errlog = open(out + '/stderr.log', 'w')
start = time.time()
p = subprocess.Popen([args.app], env=env, stdout=errlog, stderr=errlog)
steps = int(args.duration / 0.4)
try:
    for i in range(steps):
        if p.poll() is not None:
            break
        c = rng.choice(rows('list-clients', '-F', '#{client_name}') or [None])
        ws = rows('list-windows', '-a', '-F', '#{session_name}:#{window_index}')
        target = rng.choice(rows('list-panes', '-a', '-F', '#{pane_id}') or [None])
        a = 0 if i % 100 < 35 else rng.randrange(22)
        counts[a] += 1
        log.write(json.dumps(dict(i=i, elapsed=time.time() - start, action=a, pane=target, client=c)) + '\n')
        if i in (steps * 2 // 5, steps * 4 // 5):
            t('kill-server')
            setup(False)
        elif a == 0 and c:
            t('switch-client', '-c', c, '-t', 's1:log-1m' if (i // 100) % 2 else 's1:log-100k')
        elif a in (1, 2, 3) and c and ws:
            t('switch-client', '-c', c, '-t', rng.choice(ws))
        elif a == 4 and target:
            t('split-window', '-d', '-t', target)
        elif a == 5 and target:
            t('kill-pane', '-t', target)
        elif a == 6 and ws:
            t('kill-window', '-t', rng.choice(ws))
        elif a == 7 and target:
            t('resize-pane', '-Z', '-t', target)
        elif a == 8 and target:
            t('resize-pane', '-' + rng.choice('LRUD'), str(rng.randrange(1, 10)), '-t', target)
        elif a == 9 and target:
            t('send-keys', '-t', target, 'seq 100000', 'Enter')
        elif a in (10, 11) and ws:
            t('new-pane', '-d', '-t', 's1:log-1m', '-X', '30', '-Y', '12', '-x', '45', '-y', '15')
        elif a == 12 and target:
            t('move-pane', '-t', target, '-X', str(rng.randrange(150)), '-Y', str(rng.randrange(50)))
        elif a == 13 and target:
            t('resize-pane', '-t', target, '-x', str(rng.randrange(10, 80)), '-y', str(rng.randrange(5, 40)))
        elif a == 14 and c:
            t('refresh-client', '-c', c, '-C', f'{rng.randrange(90, 190)},{rng.randrange(30, 70)}')
        elif a == 15:
            for pid in app_children(p.pid):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        elif a == 17 and c and i > 200:
            current = t('display-message', '-c', c, '-p', '#{session_name}')
            if current != 's1':
                t('kill-session', '-t', current)
        elif a == 18:
            for s in ('s2', 's3', 's4'):
                if s not in t('list-sessions', '-F', '#{session_name}'):
                    t('new-session', '-d', '-s', s)
        elif a == 19 and target:
            t('clear-history', '-t', target)
        elif a == 20 and target:
            t('select-pane', '-t', target)
        elif a == 21 and ws:
            t('new-window', '-d', '-t', rng.choice(ws).split(':')[0])
        due = start + (i + 1) * 0.4
        time.sleep(max(0, due - time.time()))
    try:
        p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        p.terminate()
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=5)
finally:
    if p.poll() is None:
        p.kill()
        p.wait(timeout=5)
    t('kill-server')

lines = open(out + '/stderr.log', errors='replace').read().splitlines()
app = []
for l in lines:
    try:
        app.append(json.loads(l))
    except ValueError:
        pass
done = next((l for l in app if l.get('done')), None)
steps_logged = [l for l in app if 'step' in l]
bad = [l for l in lines if any(w in l for w in ('Sanitizer', 'SUMMARY:', 'panic', 'Fatal error', 'Assertion failed'))]
shown = [l for l in steps_logged if l['visible'] or l['key'] or l['main'] or l['active'] or l['onScreenWindows']]
new = sorted(reports() - before)
problems = []
if bad:
    problems.append(f'{len(bad)} sanitizer/panic lines, first: {bad[0]}')
if p.returncode != 0 or not done:
    problems.append(f'app exit {p.returncode}, finished={bool(done)}')
if new:
    problems.append('new crash reports: ' + ', '.join(new))
if shown:
    problems.append(f'{len(shown)} steps saw the window visible, key, main, active or on screen: {shown[0]}')
summary = dict(seed=args.seed, find=args.find, duration=time.time() - start, exit=p.returncode,
               tmux_actions=dict(counts), app_actions=done and done['counts'], app_steps=len(steps_logged),
               window_never_visible_key_main_active=not shown, out=out, problems=problems)
open(out + '/summary.json', 'w').write(json.dumps(summary, indent=2))
print(json.dumps(summary))
if problems:
    print('FAIL; replay: make %s SEED=%d DURATION=%d FIND=%d' % (os.environ.get('KIDO_STRESS_TARGET', 'stress'),
                                                                  args.seed, args.duration, args.find), file=sys.stderr)
    sys.exit(1)
