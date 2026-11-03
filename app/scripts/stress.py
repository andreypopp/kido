#!/usr/bin/env python3
"""Seeded stress run of a KIDO_STRESS build of Kido.app against a private ko server.

The window stays off screen (KIDO_APP_BACKGROUND=1); see docs/design-app.md, "Stress harness".
"""
import argparse, base64, collections, glob, json, os, random, re, signal, subprocess, sys, tempfile, threading, time

ap = argparse.ArgumentParser()
ap.add_argument('--app', required=True)
ap.add_argument('--ko', required=True)
ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--duration', type=float, default=60)
ap.add_argument('--find', type=int, default=1)
ap.add_argument('--out', required=True)
args = ap.parse_args()

out = os.path.abspath(args.out)
os.makedirs(out + '/config/kido', exist_ok=True)
server = tempfile.mkdtemp(prefix='ko-stress-', dir='/tmp')
try:
    os.unlink(out + '/ui.lock')
except FileNotFoundError:
    pass
rng = random.Random(args.seed)
counts = collections.Counter()
open(out + '/config/kido/kido-app.conf', 'w').write('scrollback-limit = 8388608\n')
actions = open(out + '/actions.jsonl', 'w', buffering=1)


class log:
    """actions.jsonl, echoed to stdout as each action happens."""
    @staticmethod
    def write(line):
        actions.write(line)
        sys.stdout.write(line)
        sys.stdout.flush()


def ko(*a, body=None):
    """One request to the private server; the parsed answer, or None when it failed."""
    command = [args.ko, *a, '--server', server]
    log.write(json.dumps(dict(event='ko', command=a, body=body, uptime=time.monotonic())) + '\n')
    if body is not None:
        path = server + '/stress-body.json'
        open(path, 'w').write(json.dumps(body))
        command += ['--input', path]
    try:
        p = subprocess.run(command, capture_output=True, text=True, timeout=8, env=helper_env)
    except subprocess.TimeoutExpired:
        log.write(json.dumps(dict(command=a, error='timeout')) + '\n')
        return None
    if p.returncode:
        log.write(json.dumps(dict(command=a, error=p.stderr.strip())) + '\n')
        return None
    try:
        return json.loads(p.stdout) if p.stdout.strip() else {}
    except ValueError:
        return p.stdout


def api(method, path, body=None):
    return ko('api', '-X', method, path, body=body) if method != 'GET' else ko('api', path)


def typed(text):
    return {'type': 'text', 'data': base64.b64encode(text.encode()).decode()}


def pane(command=None):
    return {'pane': {'new': {'command': {'type': 'shell', 'command': command}} if command else {}}}


def edit(change):
    """One layout edit through ko, applied again by the core after a revision conflict; what it answers, or None."""
    return ko('layout', 'edit', json.dumps(change))


def windows():
    current = api('GET', '/layout')
    return [(s, w) for s in current['layout']['sessions'] for w in s['windows']] if isinstance(current, dict) and 'layout' in current else []


def panes():
    listed = api('GET', '/panes')
    return [p['id'] for p in listed] if isinstance(listed, list) else []


def leaves(tree):
    return [tree['pane']] if 'pane' in tree else [p for c in tree['children'] for p in leaves(c)]


server_process = None
server_problems = []


def stop_server():
    """kill-server while this script reaps the server: it is our child, and a zombie looks alive to kill-server."""
    log.write(json.dumps(dict(event='ko', command=['kill-server'], uptime=time.monotonic())) + '\n')
    reaper = threading.Thread(target=server_process.wait, daemon=True)
    reaper.start()
    stopper = subprocess.Popen([args.ko, 'kill-server', '--server', server], env=helper_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        _, stderr = stopper.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        stopper.kill()
        _, stderr = stopper.communicate()
    reaper.join(timeout=10)
    if stopper.returncode != 0 or reaper.is_alive():
        server_problems.append('kill-server did not stop the server: ' + stderr.strip())


def setup(full):
    global server_process
    server_process = started = subprocess.Popen([args.ko, 'server', '--server', server], env=helper_env, stdout=subprocess.DEVNULL, stderr=open(out + '/server.log', 'a'))
    deadline = time.monotonic() + 20
    while api('GET', '/version') is None:
        if time.monotonic() > deadline or started.poll() is not None:
            raise RuntimeError('private server did not start')
        time.sleep(0.05)
    sessions = []
    for s in range(1, 5):
        ws = []
        for w in range(16 if full else 4):
            first = pane('while :; do date; sleep 0.05; done') if w == 0 else pane()
            ws.append({'name': f'w{w}', 'tree': {'split': 'h', 'children': [first, {'split': 'v', 'children': [pane(), pane()]}]}})
        sessions.append({'name': f's{s}', 'windows': ws})
    for name, n in [('log-1m', 1000000), ('log-100k', 100000)]:
        sessions[0]['windows'].append({'name': name, 'tree': pane(f"seq 1 {n}; while :; do printf 'INFO built ERROR %s\\n' $RANDOM; sleep 0.03; done"),
                                       'floats': [{'x': 20, 'y': 5, 'cols': 45, 'rows': 15, **pane()}]})
    sessions[1]['windows'].append({'name': 'seq', 'tree': pane('seq 2000000; sleep 3600')})
    sessions[2]['windows'].append({'name': 'yes', 'tree': pane('yes | head -50000000; sleep 3600')})
    if api('PUT', '/layout', {'revision': 0, 'layout': {'sessions': sessions}}) is None:
        raise RuntimeError('the stress layout was refused')
    log.write(json.dumps(dict(event='server-started')) + '\n')


def app_client():
    """The app's client id, as the KIDO_STRESS build logs it at each welcome."""
    found = re.findall(r'^kido-app stress client (client_\d+)$', open(out + '/stderr.log', errors='replace').read(), re.M)
    return found[-1] if found else None


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


def app_descendants(pid):
    processes = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,stat=,args='], text=True, errors='replace').splitlines():
        bits = line.split(None, 3)
        if len(bits) == 4:
            processes[int(bits[0])] = (int(bits[1]), bits[2], bits[3])
    owned = {pid}
    while True:
        children = {child for child, (parent, _, _) in processes.items() if parent in owned}
        if children <= owned:
            return {child: processes[child][2] for child in owned if child != pid}
        owned.update(children)


env = {k: v for k, v in os.environ.items() if not k.startswith('KIDO_AGENT_') and k not in ('TMUX', 'TMUX_PANE', 'KIDO_STATE_DIR', 'KO_PANE', 'KO_SERVER')}
os.makedirs(out + '/home', exist_ok=True)
env.update(HOME=out + '/home', XDG_STATE_HOME=out + '/state', KIDO_APP_BACKGROUND='1', KIDO_APP_SERVER=server,
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
try:
    setup(True)
except Exception:
    stop_server()
    subprocess.run(['rm', '-rf', server], timeout=10)
    raise
errlog = open(out + '/stderr.log', 'w')
start = time.time()
p = subprocess.Popen([args.app], env=env, stdout=errlog, stderr=errlog)
mtc_mapped = not checker
if checker:
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
known_helpers = {}
unreaped_helpers = []
try:
    for i in range(steps):
        known_helpers.update(app_descendants(p.pid))
        if p.poll() is not None:
            break
        if os.path.exists(out + '/ui.lock'):
            time.sleep(0.1)
            continue
        current = set(panes())
        if previous - current:
            log.write(json.dumps(dict(event='panes-gone', panes=sorted(previous - current))) + '\n')
        previous = current
        target = rng.choice(sorted(current) or [None])
        ws = windows()
        a = 0 if i % 100 < 35 else rng.randrange(20)
        counts[a] += 1
        log.write(json.dumps(dict(i=i, elapsed=time.time() - start, uptime=time.monotonic(), action=a, pane=target)) + '\n')
        if i in (steps * 2 // 5, steps * 4 // 5):
            stop_server()
            log.write(json.dumps(dict(event='panes-killed', panes=sorted(current))) + '\n')
            setup(False)
            counts['server-restarted'] += 1
        elif a in (0, 1, 2, 3) and ws:
            name = 'log-1m' if (i // 100) % 2 else 'log-100k'
            pick = next((w for s, w in ws if w['name'] == name), None) if a == 0 else rng.choice(ws)[1]
            client = app_client()
            if pick and client and api('POST', f'/clients/{client}/select', {'window': pick['id']}) is not None:
                counts['client-select'] += 1
        elif a == 4 and target:
            edit({'type': 'split', 'pane': target, 'axis': rng.choice('hv'), 'new': {}})
        elif a == 5 and target:
            log.write(json.dumps(dict(event='panes-killed', panes=[target])) + '\n')
            api('DELETE', f'/panes/{target}')
        elif a == 6 and len(ws) > 4:
            _, w = rng.choice(ws)
            log.write(json.dumps(dict(event='panes-killed', panes=leaves(w['tree']) + [f['pane'] for f in w.get('floats', [])])) + '\n')
            api('DELETE', f'/windows/{w["id"]}')
        elif a == 7 and target:
            edit({'type': 'toggle_zoom', 'pane': target})
        elif a == 8 and target:
            api('POST', f'/panes/{target}/input', typed('seq 100000\r'))
        elif a in (9, 10) and ws:
            host = next((w for _, w in ws if w['name'] == 'log-1m'), None)
            made = host and edit({'type': 'split', 'pane': leaves(host['tree'])[0], 'axis': 'h', 'new': {}})
            if isinstance(made, dict) and made.get('created', {}).get('type') == 'pane':
                edit({'type': 'float', 'pane': made['created']['pane'], 'x': rng.randrange(60), 'y': rng.randrange(20), 'cols': 45, 'rows': 15})
        elif a == 11:
            floats = [f['pane'] for _, w in ws for f in w.get('floats', [])]
            if floats:
                edit({'type': 'float', 'pane': rng.choice(floats), 'x': rng.randrange(150), 'y': rng.randrange(50)})
        elif a == 12 and i > 200:
            sessions = sorted({s['id'] for s, _ in ws})
            if len(sessions) > 1:
                dropped = rng.choice(sessions[1:])
                log.write(json.dumps(dict(event='panes-killed', panes=[p for s, w in ws if s['id'] == dropped for p in leaves(w['tree']) + [f['pane'] for f in w.get('floats', [])]])) + '\n')
                api('DELETE', f'/sessions/{dropped}')
        elif a == 13:
            if len({s['id'] for s, _ in ws}) < 4:
                edit({'type': 'add_session', 'name': f's-{i}', 'new': {}})
        elif a == 14 and target:
            api('POST', f'/panes/{target}/clear_history')
        elif a == 15 and ws:
            session, window = rng.choice(ws)
            edit({'type': 'add_window', 'session': session['id'], 'after': window['id'], 'new': {}})
        elif a == 16 and ws:
            edit({'type': 'rename_window', 'window': rng.choice(ws)[1]['id'], 'name': f'renamed-{i}'})
            counts['rename-window'] += 1
        elif a == 17 and len(ws) > 1:
            session = rng.choice(ws)[0]
            order = [w['id'] for w in session['windows']]
            if len(order) > 1:
                x, y = rng.sample(range(len(order)), 2)
                order[x], order[y] = order[y], order[x]
                edit({'type': 'reorder_windows', 'session': session['id'], 'order': order})
                counts['swap-window'] += 1
        elif a == 18 and target:
            api('POST', f'/panes/{target}/input', typed(f'\x03{args.ko} run --name stress-child-{i} -- sleep 8\r'))
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
    known_helpers.update(app_descendants(p.pid))
    if p.poll() is None:
        p.kill()
        p.wait(timeout=5)
    for pid, command in known_helpers.items():
        current = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat=,args='], capture_output=True, text=True, timeout=3).stdout.strip().split(None, 1)
        if len(current) == 2 and not current[0].startswith('Z') and current[1] == command:
            unreaped_helpers.append(pid)
            os.kill(pid, signal.SIGKILL)
    if unreaped_helpers:
        log.write(json.dumps(dict(event='helpers-survived-app', pids=unreaped_helpers, app_exit=p.returncode)) + '\n')
    stop_server()
    subprocess.run(['rm', '-rf', server], timeout=10)

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
problems = list(server_problems)
if not mtc_mapped:
    problems.append('Main Thread Checker not mapped in app pid ' + str(p.pid))
floating = False
collapsed_size = None
last_size = None
floating_probes = 0
floating_interrupted = 0
floating_errors = []
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
        problems.extend(floating_errors)
        floating_errors.clear()
    elif event.get('floating-probe') == 'interrupted':
        floating = False
        floating_interrupted += 1
        floating_errors.clear()
    elif 'client-size-send ' in line:
        size = line.rsplit('client-size-send ', 1)[1].strip()
        if floating and size not in (last_size, collapsed_size):
            floating_errors.append('floating changed the terminal size: ' + line)
        elif floating:
            floating_deferred += 1
        last_size = size
    if event.get('verification') and not event.get('passed'):
        problems.append('UI verification failed: ' + line)
problems.extend(floating_errors)
if done:
    done['counts']['floating-no-refresh-verified'] = floating_probes
    done['counts']['floating-no-refresh-interrupted'] = floating_interrupted
    done['counts']['floating-deferred-or-redundant-refresh'] = floating_deferred
    counts['child-window'] = done['counts'].get('child-window-seen', 0)
    if counts['child-window-attempted'] and not counts['child-window']:
        problems.append('async child windows were sent but never observed in the feed')
    for action in ('tabs', 'sidebar-jump', 'sidebar-mode'):
        if not done['counts'].get(action + '-delivered'):
            problems.append('UI action never delivered: ' + action)
    for kind in ('displayed-window', 'tab-order', 'shortcut-order', 'jump-selects', 'floating-frame', 'floating-dismiss', 'floating-no-refresh'):
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
if unreaped_helpers:
    problems.append(f'app left helper processes: {unreaped_helpers}')
if p.returncode != 0 or not done:
    problems.append(f'app exit {p.returncode}, finished={bool(done)}')
if new:
    problems.append('new crash reports: ' + ', '.join(new))
if shown:
    problems.append(f'{len(shown)} steps saw the window visible, key, main, active or on screen: {shown[0]}')
summary = dict(seed=args.seed, find=args.find, duration=time.time() - start, exit=p.returncode,
               server_actions=dict(counts), app_actions=done and done['counts'], app_steps=len(steps_logged),
               window_never_visible_key_main_active=not shown, out=out, problems=problems)
open(out + '/summary.json', 'w').write(json.dumps(summary, indent=2))
print(json.dumps(summary))
if problems:
    print('FAIL; replay: make %s SEED=%d DURATION=%d FIND=%d' % (os.environ.get('KIDO_STRESS_TARGET', 'stress'),
                                                                  args.seed, args.duration, args.find), file=sys.stderr)
    sys.exit(1)
