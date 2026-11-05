#!/usr/bin/env python3
"""Seeded stress run of a KIDO_STRESS build of Kido.app against a private ko server.

The window stays off screen (KIDO_APP_BACKGROUND=1); see docs/design-app.md, "Stress harness".
"""
import argparse, base64, collections, glob, json, os, random, re, signal, socket, struct, subprocess, sys, tempfile, threading, time

ap = argparse.ArgumentParser()
ap.add_argument('--app', required=True)
ap.add_argument('--ko', required=True)
ap.add_argument('--seed', type=int, default=1)
ap.add_argument('--duration', type=float, default=60)
ap.add_argument('--find', type=int, default=1)
ap.add_argument('--out', required=True)
args = ap.parse_args()

out = os.path.abspath(args.out)
os.makedirs(out + '/config/ko', exist_ok=True)
server = tempfile.mkdtemp(prefix='ko-stress-', dir='/tmp')
try:
    os.unlink(out + '/ui.lock')
except FileNotFoundError:
    pass
rng = random.Random(args.seed)
counts = collections.Counter()
open(out + '/config/ko/config.yaml', 'w').write('server:\n  scrollback: {bytes: 8388608}\n')
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


IMAGE_PROGRAM = r"""
import _posixshmem, base64, mmap, os, sys, time
count = 0
def up(control, pixels):
    global count
    count += 1
    name = "/ko-st-%d-%d" % (os.getpid() % 100000, count % 1000)
    try:
        descriptor = _posixshmem.shm_open(name, os.O_CREAT | os.O_EXCL | os.O_RDWR, mode=0o600)
    except FileExistsError:
        return
    os.ftruncate(descriptor, len(pixels))
    memory = mmap.mmap(descriptor, len(pixels))
    memory[:] = pixels
    memory.close()
    os.close(descriptor)
    sys.stdout.write("\x1b_G%s,t=s,f=32,s=1,v=1,q=2;%s\x1b\\" % (control, base64.b64encode(name.encode()).decode()))
    sys.stdout.flush()
while True:
    up("a=T,i=1,c=2,r=1", bytes([255, 0, 0, 255]))
    up("a=f,i=1,z=40", bytes([0, 255, 0, 255]))
    sys.stdout.write("\x1b_Ga=a,i=1,s=3,q=2\x1b\\")
    up("a=f,i=1,r=1", bytes([0, 0, 255, 255]))
    time.sleep(0.2)
    sys.stdout.write("\x1b[2J\x1b[H")
"""


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
    """Stop the server and reap it if this script started it."""
    log.write(json.dumps(dict(event='ko', command=['kill-server'], uptime=time.monotonic())) + '\n')
    stopper = subprocess.Popen([args.ko, 'kill-server', '--server', server], env=helper_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if server_process is not None:
        reaper = threading.Thread(target=server_process.wait, daemon=True)
        reaper.start()
        reaper.join(timeout=10)
        if reaper.is_alive():
            server_problems.append('the server did not exit')
    try:
        _, stderr = stopper.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        stopper.kill()
        _, stderr = stopper.communicate()
    if stopper.returncode != 0:
        server_problems.append('kill-server did not stop the server: ' + stderr.strip())


def setup(full):
    global server_process
    server_process = subprocess.Popen([args.ko, 'server', '--server', server], env=helper_env, stdout=subprocess.DEVNULL, stderr=open(out + '/server.log', 'a')) if full else None
    deadline = time.monotonic() + 20
    while api('GET', '/version') is None:
        if time.monotonic() > deadline or (server_process is not None and server_process.poll() is not None):
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
    with open(out + '/image.py', 'w') as image_program:
        image_program.write(IMAGE_PROGRAM)
    sessions[0]['windows'].append({'name': 'images', 'tree': pane('exec /usr/bin/python3 -I ' + out + '/image.py')})
    sessions[1]['windows'].append({'name': 'seq', 'tree': pane('seq 2000000; sleep 3600')})
    sessions[2]['windows'].append({'name': 'yes', 'tree': pane('yes | head -50000000; sleep 3600')})
    if api('PUT', '/layout', {'revision': 0, 'layout': {'sessions': sessions}}) is None:
        raise RuntimeError('the stress layout was refused')
    log.write(json.dumps(dict(event='server-started')) + '\n')


def ws_read(sock, count):
    data = b''
    while len(data) < count:
        piece = sock.recv(count - len(data))
        if not piece:
            raise OSError('closed')
        data += piece
    return data


def ws_text(sock):
    """The next text message of the server."""
    while True:
        first, second = ws_read(sock, 2)
        size = second & 0x7f
        if size == 126:
            size = struct.unpack('>H', ws_read(sock, 2))[0]
        elif size == 127:
            size = struct.unpack('>Q', ws_read(sock, 8))[0]
        payload = ws_read(sock, size)
        if first & 0x0f == 1:
            return json.loads(payload)
        if first & 0x0f == 8:
            raise OSError('closed')


def ws_send(sock, message):
    data = json.dumps(message).encode()
    mask = os.urandom(4)
    size = len(data)
    head = bytes([0x81, 0x80 | size]) if size < 126 else b'\x81\xfe' + struct.pack('>H', size)
    sock.sendall(head + mask + bytes(byte ^ mask[at % 4] for at, byte in enumerate(data)))


def client_select(window):
    """A select on a /client socket of its own, true once the server answers with its selected event."""
    version = ko('api', '/version')
    if not isinstance(version, dict):
        return False
    sock = socket.socket(socket.AF_UNIX)
    sock.settimeout(8)
    try:
        sock.connect(server + '/socket')
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((f'GET /client HTTP/1.1\r\nHost: ko\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                      f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
                      f'Ko-Protocol: {version["protocol"]}\r\nKo-Vt: {version["vt"]}\r\n\r\n').encode())
        head = b''
        while not head.endswith(b'\r\n\r\n'):
            head += ws_read(sock, 1)
        if b' 101 ' not in head.split(b'\r\n')[0]:
            return False
        ws_send(sock, {'type': 'hello', 'kind': 'app', 'name': 'stress', 'focused': False, 'size': {'cols': 80, 'rows': 24}})
        while ws_text(sock).get('type') != 'layout':
            pass
        ws_send(sock, {'type': 'select', 'window': window})
        while ws_text(sock).get('type') != 'selected':
            pass
        return True
    except (OSError, ValueError, KeyError):
        return False
    finally:
        sock.close()


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


env = {k: v for k, v in os.environ.items() if not k.startswith('KO_')}
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
            if pick and client_select(pick['id']):
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
            api('POST', '/panes', {'parent': target, 'close': 'on_exit', 'command': {'type': 'argv', 'argv': ['/bin/sleep', '8']}})
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
