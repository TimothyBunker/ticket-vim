#!/usr/bin/env python3
"""Actual Bash/readline interaction. Fake Pi; generated commands use only temp files."""
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='tt-shell-') as folder:
    work = Path(folder)
    fake = work / 'pi'
    fake.write_text('''#!/usr/bin/env python3
import json, pathlib, sys, time
p = json.load(sys.stdin)
pathlib.Path('request.json').write_text(json.dumps({'prompt': p, 'args': sys.argv[1:]}))
q = p['request']
if q == 'failure':
    print('Example provider failure', file=sys.stderr); sys.exit(1)
if q == 'slow':
    pathlib.Path('slow.pid').write_text(str(__import__('os').getpid()))
    time.sleep(30)
if q == 'bad output':
    print(json.dumps({'command': 'echo ok\\necho bad'})); sys.exit()
print(json.dumps({'command': "printf '%s\\\\n' 'egg salad' > 'result file'"}))
''')
    fake.chmod(0o755)
    rc = work / 'bashrc'
    rc.write_text(f'''PS1='TT-PROMPT> '
PS2='TT-CONTINUE> '
HISTFILE=/dev/null
set +H
PROMPT_COMMAND='printf "%s" "$?" > last-status'
source {shlex.quote(str(ROOT / 'shell/tt.bash'))}
_tt_probe() {{ printf '%s' "$READLINE_LINE" > {shlex.quote(str(work / 'line'))}; }}
for map in emacs-standard vi-insert vi-command; do
  bind -m "$map" -x '"\\C-x\\C-p": _tt_probe'
done
''')
    child, terminal = pty.fork()
    if child == 0:
        os.chdir(work)
        os.environ.update(TERM='xterm', TIM_PI=str(fake), PATH=str(ROOT / 'bin') + ':' + os.environ['PATH'])
        os.execvp('bash', ['bash', '--noprofile', '--rcfile', str(rc), '-i'])
    transcript = bytearray()

    def drain(duration=.1):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            ready, _, _ = select.select([terminal], [], [], max(0, deadline - time.monotonic()))
            if ready:
                try:
                    transcript.extend(os.read(terminal, 65536))
                except OSError:
                    return

    def send(keys):
        os.write(terminal, keys.encode())
        drain()

    def wait(check):
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            drain(.05)
            if check():
                return
        raise AssertionError('Timeout; terminal output:\n' + transcript.decode(errors='replace'))

    def line():
        snapshot = work / 'line'
        snapshot.unlink(missing_ok=True)
        send('\x18\x10')
        wait(snapshot.exists)
        return snapshot.read_text()

    def request(text):
        (work / 'request.json').unlink(missing_ok=True)
        send(text + '\r')
        wait(lambda: (work / 'request.json').exists())

    try:
        wait(lambda: b'TT-PROMPT>' in transcript)
        request('tt "search for \'egg salad\' in lunch menu directory"')
        expected = "printf '%s\\n' 'egg salad' > 'result file'"
        assert line() == expected, line()
        assert not (work / 'result file').exists(), 'A suggestion must never execute on first Enter'
        call = json.loads((work / 'request.json').read_text())
        assert call['prompt']['request'] == "search for 'egg salad' in lunch menu directory"
        assert call['prompt']['cwd'] == str(work)
        for flag in ['--no-tools', '--no-session', '--no-context-files', '--no-extensions', '--no-approve']:
            assert flag in call['args'], call['args']
        # Edit the suggested command using normal readline, then explicitly execute it.
        send("\x01# ")
        assert line() == '# ' + expected
        send('\x01\x04\x04\r')
        wait(lambda: (work / 'result file').exists())
        assert (work / 'result file').read_text() == 'egg salad\n'
        send('\x1b[A')
        assert line() == expected, 'History must contain the actual approved command'
        send('\x15')
        for prompt in ['failure', 'bad output']:
            original = f'tt "{prompt}"'
            request(original)
            assert line() == original, 'Failure must preserve the request'
            send('\x15')
        # Literal shell expansions in the request never execute before generation.
        request('tt "explain $(touch injected) and `touch injected2`"')
        assert line() == expected
        assert not (work / 'injected').exists() and not (work / 'injected2').exists()
        send('\x15')
        # Ctrl-C cancels the subprocess and leaves the shell usable.
        request('tt "slow"')
        wait(lambda: (work / 'slow.pid').exists())
        slow_pid = int((work / 'slow.pid').read_text())
        send('\x03')
        wait(lambda: not Path(f'/proc/{slow_pid}').exists())
        send('\x15')
        send("printf normal > normal\r")
        wait(lambda: (work / 'normal').exists())
        assert (work / 'normal').read_text() == 'normal'
        # Normal multiline Bash input and commands still work.
        send("printf '%s' 'two\rtt literal text\rlines' > multiline\r")
        wait(lambda: (work / 'multiline').exists())
        assert (work / 'multiline').read_text() == 'two\ntt literal text\nlines'
        send('false\r')
        wait(lambda: (work / 'last-status').read_text() == '1')
        send('printf "%s" "$?" > actual-status\r')
        wait(lambda: (work / 'actual-status').exists())
        assert (work / 'actual-status').read_text() == '1'
        # vi insertion mode has the same two-step behavior.
        send('set -o vi\r')
        request('tt "vi mode"')
        assert line() == expected
        send('\x03')
        print('PASS tt: editable replacement, explicit execution, history, errors, quoting, cancellation, multiline, vi mode')
    finally:
        os.kill(child, signal.SIGKILL)
        os.waitpid(child, 0)
        os.close(terminal)
