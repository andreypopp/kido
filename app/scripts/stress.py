#!/usr/bin/env python3
"""Seeded stress run of a KIDO_STRESS build of Kido.app against a private tmux server.

The window stays off screen (KIDO_APP_BACKGROUND=1); see docs/design-app.md, "Stress harness".
"""
import argparse, collections, glob, json, os, random, signal, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument('--app', required=True)
ap.add_argument('--tmux', required=True)
ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--duration', type=float, default=60)
ap.add_argument('--find', type=int, default=1)
ap.add_argument('--out', required=True)
args = ap.parse_args()

out = os.path.abspath(args.out)
os.makedirs(out + '/config/kido', exist_ok=True)
server = tempfile.mkdtemp(prefix='kido-stress-', dir='/tmp')
sock = server + '/socket'
try:
    os.unlink(out + '/ui.lock')
except FileNotFoundError:
    pass
rng = random.Random(args.seed)
counts = collections.Counter()
open(out + '/config/kido/kido-app.conf', 'w').write('scrollback-limit = 8388608\n')
log = open(out + '/actions.jsonl', 'w', buffering=1)


def t(*a):
    server_pid = t('display-message', '-p', '#{pid}') if a[0] == 'kill-server' else ''
    if a[0] in ('kill-pane', 'kill-window', 'kill-session', 'kill-server'):
        if a[0] == 'kill-pane':
            victims = [a[-1]]
        elif a[0] == 'kill-window':
            victims = rows('list-panes', '-t', a[-1], '-F', '#{pane_id}')
        elif a[0] == 'kill-session':
            victims = rows('list-panes', '-s', '-t', a[-1], '-F', '#{pane_id}')
        else:
            victims = rows('list-panes', '-a', '-F', '#{pane_id}')
        log.write(json.dumps(dict(event='panes-killed', panes=victims, command=a)) + '\n')
    try:
        p = subprocess.run([args.tmux, '-S', sock, *a], capture_output=True, text=True, timeout=8, env=helper_env)
        if p.returncode:
            log.write(json.dumps(dict(command=a, error=p.stderr.strip())) + '\n')
        if a[0] == 'kill-server' and server_pid.isdecimal():
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                try:
                    os.kill(int(server_pid), 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            else:
                raise RuntimeError('private tmux server did not exit after kill-server')
        return p.stdout.strip()
    except subprocess.TimeoutExpired:
        return ''


def rows(*a):
    return t(*a).splitlines()


def setup(full):
    kido = os.path.join(os.path.dirname(args.tmux), 'kido')
    endpoint = subprocess.run([kido, 'server', '--server', server], capture_output=True, text=True, timeout=20, env=helper_env)
    if endpoint.returncode:
        raise RuntimeError('private server launch failed: ' + endpoint.stdout + endpoint.stderr)
    log.write(json.dumps(dict(event='server-started', endpoint=json.loads(endpoint.stdout))) + '\n')
    initial = rows('list-sessions', '-F', '#{session_id}')
    t('new-session', '-d', '-s', 's1', '-x', '120', '-y', '40')
    for session in initial:
        t('kill-session', '-t', session)
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


def report_matches(text, pid):
    for part in text.split('\n', 1):
        try:
            if json.loads(part).get('pid') == pid:
                return True
        except ValueError:
            pass
    return False


def app_children(pid):
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,args='], text=True).splitlines():
        bits = line.split(None, 2)
        if len(bits) == 3 and int(bits[1]) == pid and 'rpc' in bits[2].split():
            yield int(bits[0])


env = {k: v for k, v in os.environ.items() if not k.startswith('KIDO_AGENT_') and k not in ('TMUX', 'TMUX_PANE', 'KIDO_STATE_DIR', 'KIDO_TMUX')}
os.makedirs(out + '/home', exist_ok=True)
os.makedirs(out + '/tmp', exist_ok=True)
env.update(HOME=out + '/home', XDG_STATE_HOME=out + '/state', TMUX_TMPDIR=out + '/tmp', KIDO_APP_BACKGROUND='1', KIDO_APP_SERVER=server, KIDO_APP_TMUX=args.tmux,
           KIDO_APP_DEBUG='1', STRESS_UI_LOCK=out + '/ui.lock', XDG_CONFIG_HOME=out + '/config',
           STRESS_SEED=str(args.seed), STRESS_DURATION=str(args.duration))
if not args.find:
    env['STRESS_NO_FIND'] = '1'
if 'ASAN_OPTIONS' not in env:
    env['ASAN_OPTIONS'] = 'use_sigaltstack=0'

checker = None
if env.get('KIDO_MTC_VERIFY') == '1':
    checker = os.path.join(env.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'),
                           'usr/lib/libMainThreadChecker.dylib')
    if not os.path.isfile(checker):
        raise RuntimeError('Main Thread Checker not found: ' + checker)
    env.update(DYLD_INSERT_LIBRARIES=checker, MTC_RESET_INSERT_LIBRARIES='1')

helper_env = {k: v for k, v in env.items() if k not in ('DYLD_INSERT_LIBRARIES', 'MTC_RESET_INSERT_LIBRARIES')}
before = reports()
setup(True)
errlog = open(out + '/stderr.log', 'w')
start = time.time()
p = subprocess.Popen([args.app], env=env, stdout=errlog, stderr=errlog)
mtc_mapped = not checker
if checker:
    helper_env = {k: v for k, v in os.environ.items() if k not in ('DYLD_INSERT_LIBRARIES', 'MTC_RESET_INSERT_LIBRARIES')}
    deadline = time.monotonic() + 15
    with open(out + '/mapped-images.log', 'w') as images:
        while time.monotonic() < deadline and p.poll() is None:
            result = subprocess.run(['/usr/bin/vmmap', '-w', str(p.pid)], env=helper_env, capture_output=True, text=True, timeout=5)
            images.write(f'PID {p.pid} vmmap exit={result.returncode}\n{result.stdout}{result.stderr}\n')
            if 'libMainThreadChecker.dylib' in result.stdout:
                mtc_mapped = True
                break
            time.sleep(0.1)
steps = int(args.duration / 0.4)
previous = set()
feed_pending = None
feed_restart_failed = False
try:
    for i in range(steps):
        if p.poll() is not None:
            break
        if feed_pending:
            killed, deadline = feed_pending
            if any(pid != killed for pid in app_children(p.pid)):
                counts['feed-restarted'] += 1
                feed_pending = None
            elif time.monotonic() > deadline:
                feed_restart_failed = True
                feed_pending = None
        c = rng.choice(rows('list-clients', '-F', '#{client_name}') or [None])
        ws = rows('list-windows', '-a', '-F', '#{session_name}:#{window_index}')
        panes = rows('list-panes', '-a', '-F', '#{pane_id}')
        current = set(panes)
        if previous - current:
            log.write(json.dumps(dict(event='panes-gone', panes=sorted(previous - current))) + '\n')
        previous = current
        target = rng.choice(panes or [None])
        if os.path.exists(out + '/ui.lock'):
            time.sleep(0.1)
            continue
        a = 0 if i % 100 < 35 else rng.randrange(25)
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
        elif a == 15 and feed_pending is None:
            for pid in app_children(p.pid):
                try:
                    log.write(json.dumps(dict(event='feed-killed', pid=pid, app_pid=p.pid)) + '\n')
                    os.kill(pid, signal.SIGTERM)
                    counts['feed-killed'] += 1
                    feed_pending = (pid, time.monotonic() + 10)
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
        elif a == 22 and ws:
            t('rename-window', '-t', rng.choice(ws), f'renamed-{i}')
            counts['rename-window'] += 1
        elif a == 23 and len(ws) > 1:
            source, dest = rng.sample(ws, 2)
            t('swap-window', '-d', '-s', source, '-t', dest)
            counts['swap-window'] += 1
        elif a == 24 and target:
            kido = os.path.join(os.path.dirname(args.tmux), 'kido')
            t('send-keys', '-t', target, 'C-c')
            t('send-keys', '-t', target, f'{kido} tool async_bash --name stress-child-{i} -- sleep 8', 'Enter')
            counts['child-window-attempted'] += 1
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
bad = [l for l in lines if any(w in l for w in ('Sanitizer', 'SUMMARY:', 'panic', 'Fatal error', 'Assertion failed', 'Main Thread Checker:', 'UI API called on a background thread'))]
shown = [l for l in steps_logged if l['visible'] or l['key'] or l['main'] or l['active'] or l['onScreenWindows']]
new = sorted(path for path in reports() - before
             if report_matches(open(path).read(), p.pid))
problems = []
if feed_restart_failed:
    problems.append('rpc did not restart within 10 seconds')
if not mtc_mapped:
    problems.append('Main Thread Checker not mapped in app pid ' + str(p.pid))
floating = False
collapsed_size = None
last_size = None
floating_probes = 0
floating_deferred = 0
for line in lines:
    try:
        event = json.loads(line)
    except ValueError:
        event = {}
    if event.get('floating-probe') == 'begin':
        floating = True
        collapsed_size = event.get('collapsed-size')
    elif event.get('floating-probe') == 'end':
        floating = False
        floating_probes += 1
    elif 'client-size-send ' in line:
        size = line.rsplit('client-size-send ', 1)[1].strip()
        if floating and size not in (last_size, collapsed_size):
            problems.append('floating changed terminal size via refresh-client -C: ' + line)
        elif floating:
            floating_deferred += 1
        last_size = size
    if event.get('verification') and not event.get('passed'):
        problems.append('UI verification failed: ' + line)
if done:
    done['counts']['floating-no-refresh-verified'] = floating_probes
    done['counts']['floating-deferred-or-redundant-refresh'] = floating_deferred
    counts['child-window'] = done['counts'].get('child-window-seen', 0)
    if counts['child-window-attempted'] and not counts['child-window']:
        problems.append('async child windows were sent but never observed in the feed')
    for action in ('tabs', 'sidebar-jump', 'sidebar-search', 'sidebar-fold', 'sidebar-mode'):
        if not done['counts'].get(action + '-delivered'):
            problems.append('UI action never delivered: ' + action)
    for kind in ('displayed-window', 'tab-order', 'shortcut-order', 'one-switch-client', 'search-escape', 'floating-frame', 'floating-dismiss', 'floating-no-refresh'):
        if not done['counts'].get(kind + '-verified'):
            problems.append('UI verification never ran: ' + kind)
gone = {event['detail'] for event in app if event.get('event') == 'drag-killed'}
for line in open(out + '/actions.jsonl'):
    event = json.loads(line)
    if event.get('event') in ('panes-killed', 'panes-gone'):
        gone.update(event['panes'])
killed_race = 0
for event in app:
    if event.get('event') == 'pane-command-failed':
        detail = event['detail']
        if detail.startswith("can't find pane: ") and detail.removeprefix("can't find pane: ") in gone:
            killed_race += 1
        else:
            problems.append('pane command failed: ' + detail)
if done:
    done['counts']['killed_race'] = killed_race
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
