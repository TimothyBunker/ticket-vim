#!/usr/bin/env python3
"""Exercise real Neovim input/focus in its event loop, using a fake Pi."""
import json
import os
import fcntl
import struct
import termios
import threading
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
NVIM = os.environ.get('TIM_NVIM', str(ROOT / '.tools/neovim/bin/nvim'))

with tempfile.TemporaryDirectory(prefix='tim-interaction-') as folder:
    work = Path(folder)
    source = work / 'example.py'
    source.write_text('alpha Ωmega end\ntail text\nthird line\nfourth line\n')
    (work / 'helper.py').write_text('helper first\nboundary case\n')
    sock = str(work / 'nvim.sock')
    env = dict(os.environ, TIM_INSTALL_DIR=str(ROOT), TIM_SESSION_NAME='test',
               TIM_DATA_DIR=str(work / 'data'), NVIM_APPNAME='tim',
               XDG_STATE_HOME=str(work / 'state'), XDG_CACHE_HOME=str(work / 'cache'))
    setup = "lua vim.o.mousetime=0; vim.opt.rtp:prepend(vim.env.TIM_INSTALL_DIR); require('tim').opts.pi_command = {'python3', vim.env.TIM_INSTALL_DIR .. '/tests/fake_pi.py'}"
    log = (work / 'editor.log').open('w+')
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    env['TERM'] = 'xterm-256color'
    editor = subprocess.Popen([NVIM, '-i', 'NONE', '--listen', sock,
                               '--cmd', setup, '-u', str(ROOT / 'config/init.lua'), str(source)],
                              cwd=work, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    def drain():
        try:
            while True:
                data = os.read(master, 65536)
                if not data:
                    break
                log.write(data.decode(errors='replace')); log.flush()
        except OSError:
            pass
    reader = threading.Thread(target=drain, daemon=True)
    reader.start()

    def remote(*args):
        result = subprocess.run([NVIM, '--server', sock, *args], env=env,
                                text=True, capture_output=True, timeout=5)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    def expr(lua):
        return json.loads(remote('--remote-expr', 'luaeval(' + json.dumps('vim.json.encode(' + lua + ')') + ')'))

    def keys(value):
        remote('--remote-send', value)

    def until(check):
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            if check():
                return
            time.sleep(.03)
        raise AssertionError('Timed out waiting for editor state')

    def click(buffer_expr, row, col):
        lua = "(function() local b=" + buffer_expr + "; local w=vim.fn.bufwinid(b); local p=vim.fn.screenpos(w," + str(row) + "," + str(col) + "); assert(p.row>0); vim.api.nvim_input_mouse('left','press','',0,p.row-1,p.col-1); vim.api.nvim_input_mouse('left','release','',0,p.row-1,p.col-1); return true end)()"
        remote('--remote-expr', 'luaeval(' + json.dumps(lua) + ')')

    def chrome(buffer_expr, label, footer=False):
        until(lambda: label in expr("vim.wo[vim.fn.bufwinid(" + buffer_expr + ")]." + ('statusline' if footer else 'winbar')))
        lua = "(function() local w=vim.fn.bufwinid(" + buffer_expr + "); local text=vim.api.nvim_eval_statusline(vim.wo[w]." + ('statusline' if footer else 'winbar') + ",{winid=w,maxwidth=vim.api.nvim_win_get_width(w),use_winbar=" + ('false' if footer else 'true') + "}).str; local at=assert(text:find('" + label + "',1,true)); local p=vim.api.nvim_win_get_position(w); local row=p[1]; " + ("row=vim.fn.screenpos(w,1,1).row-1+vim.api.nvim_win_get_height(w); " if footer else '') + "local col=p[2]+vim.fn.strdisplaywidth(text:sub(1,at-1)); vim.api.nvim_input_mouse('left','press','',0,row,col); vim.api.nvim_input_mouse('left','release','',0,row,col); return true end)()"
        remote('--remote-expr', 'luaeval(' + json.dumps(lua) + ')')

    def tab(label, close=False):
        lua = "(function() local text=vim.api.nvim_eval_statusline(vim.o.tabline,{use_tabline=true,maxwidth=vim.o.columns}).str; local at=assert(text:find('" + label + "',1,true)); local col=vim.fn.strdisplaywidth(text:sub(1,at-1))" + ("+" + str(len(label) + 1) if close else '') + "; vim.api.nvim_input_mouse('left','press','',0,0,col); vim.api.nvim_input_mouse('left','release','',0,0,col); return true end)()"
        remote('--remote-expr', 'luaeval(' + json.dumps(lua) + ')')

    def control(label, col=2):
        until(lambda: any(line.startswith(label) for line in expr("vim.api.nvim_buf_get_lines(require('tim').ui.transcript,0,-1,false)")))
        lines = expr("vim.api.nvim_buf_get_lines(require('tim').ui.transcript,0,-1,false)")
        row = next(i + 1 for i, line in enumerate(lines) if line.startswith(label))
        click("require('tim').ui.transcript", row, col)

    def state():
        return expr("{mode=vim.fn.mode(), input=vim.api.nvim_get_current_buf()==require('tim').ui.draft, busy=require('tim').app.busy, requests=#require('tim').app.state.requests, notes=#require('tim').app.state.notes}")

    def panel():
        return expr("vim.api.nvim_buf_get_lines(require('tim').ui.transcript,0,-1,false)")

    def button(label):
        token = '[' + label + ']'
        until(lambda: any(token in line for line in panel()))
        row, line = next((i + 1, line) for i, line in enumerate(panel()) if token in line)
        remote('--remote-expr', 'luaeval(' + json.dumps("(function() local w=vim.fn.bufwinid(require('tim').ui.transcript); vim.api.nvim_win_set_cursor(w,{" + str(row) + ",0}); vim.api.nvim_win_call(w,function() vim.cmd('normal! zz') end); return true end)()") + ')')
        click("require('tim').ui.transcript", row, line.index(token) + 2)

    def view(name):
        chrome("require('tim').ui.transcript", name)
        until(lambda: expr("require('tim').ui.view") == name.lower())

    def input_text(text):
        keys('<Esc>')
        until(lambda: state()['mode'] == 'n')
        keys('A' if state()['input'] else '<C-g>')
        until(lambda: state()['input'] and state()['mode'] == 'i')
        keys('<End><C-u>' + text)

    try:
        until(lambda: Path(sock).exists())
        until(lambda: expr("require('tim').app ~= nil"))
        assert expr('#vim.api.nvim_list_wins()') == 3
        assert expr('{vim.bo.tabstop, vim.bo.shiftwidth, vim.bo.softtabstop, vim.bo.expandtab}') == [2, 2, 2, True]
        keys('i<Tab><Esc>')
        until(lambda: expr('vim.api.nvim_get_current_line()') == '  alpha Ωmega end')
        keys('u')
        until(lambda: expr('vim.api.nvim_get_current_line()') == 'alpha Ωmega end')
        keys('<C-g>Explain this file<CR>')
        until(lambda: state()['requests'] == 1 and not state()['busy'])
        keys('Keep this message')
        view('Comments'); view('Diffs'); view('Chat')
        assert expr("require('tim').app.state.draft.text") == 'Keep this message'
        keys('<Esc>0wve<Esc>')
        until(lambda: expr("#require('tim').app.state.draft.references") == 1)
        assert expr('#vim.api.nvim_list_wins()') == 3
        assert expr("require('tim').app.state.draft.references[1].selection_text") == 'Ωmega'
        view('Comments'); button('Save note')
        until(lambda: state()['notes'] == 1)
        assert state()['requests'] == 1
        chrome("require('tim').ui.draft", 'Review')
        until(lambda: expr("require('tim').app.state.draft.intent") == 'review')
        assert expr('#vim.api.nvim_list_wins()') == 3  # Review uses the shared input.
        keys('Keep these instructions')
        chrome("require('tim').ui.draft", 'Cancel review')
        assert expr("require('tim').app.state.draft.text") == 'Keep these instructions'
        input_text(''); keys('<Esc>0wve<Esc>')
        until(lambda: expr("#require('tim').app.state.draft.references") == 1)
        chrome("require('tim').ui.draft", 'Review')
        keys('[structured-review]<CR>')
        until(lambda: state()['requests'] == 2 and not state()['busy'])
        assert expr("require('tim').app.state.requests[2].scope") == 'selection'
        assert expr("#require('tim').app.annotations") == 2
        assert expr("#require('tim').app.all_proposals") == 1
        keys('<Esc>')
        until(lambda: expr("require('tim').ui.proposal_rows[1] ~= nil"))
        # Click the green sign; it navigates to Diffs without opening a float.
        remote('--remote-expr', 'luaeval(' + json.dumps("(function() local t=require('tim'); local w=vim.fn.bufwinid(t.app.source_buf); local p=vim.fn.screenpos(w,1,1); local col=vim.api.nvim_win_get_position(w)[2]+3; assert(vim.fn.screenstring(p.row,col)=='◆'); assert(vim.fn.screenattr(p.row,col)~=vim.fn.screenattr(p.row,col-2)); vim.api.nvim_input_mouse('left','press','',0,p.row-1,col-1); vim.api.nvim_input_mouse('left','release','',0,p.row-1,col-1); return true end)()") + ')')
        until(lambda: expr("require('tim').ui.view") == 'diffs')
        assert expr('#vim.api.nvim_list_wins()') == 3
        assert any('[Apply]' in line for line in panel())
        assert source.read_text().startswith('alpha Ωmega')
        view('Comments')
        assert any('proposal ready' in line for line in panel())
        button('Diffs')
        click("require('tim').app.source_buf", 1, 1); keys('A!<Esc>')
        until(lambda: any('outdated' in line.lower() for line in panel()))
        assert not any('[Apply]' in line for line in panel())
        view('Comments')
        assert any('outdated' in line for line in panel())
        button('Refresh')
        until(lambda: state()['input'] and state()['mode'] == 'i')
        assert expr("require('tim').app.state.draft.intent") == 'review'
        assert 'Re-check' in expr("require('tim').app.state.draft.text")
        chrome("require('tim').ui.draft", 'Cancel review')
        input_text(''); keys('<Esc>u')
        until(lambda: expr('vim.api.nvim_get_current_line()') == 'alpha Ωmega end')
        view('Diffs'); button('Reject')
        until(lambda: expr("require('tim').app.all_proposals[1].status") == 'rejected')
        assert source.read_text().startswith('alpha Ωmega')
        view('Chat'); input_text('propose a solution [structured-fix]<CR>')
        until(lambda: state()['requests'] == 3 and not state()['busy'])
        assert state()['notes'] == 1
        assert expr("#require('tim').app.all_proposals") == 2
        # Busy, cancel and retry are explicit, and newer input survives them.
        input_text('[slow] wait<CR>')
        until(lambda: expr("require('tim').app.state.requests[4].status") == 'running')
        keys('Keep the next message')
        chrome("require('tim').ui.draft", 'Cancel')
        until(lambda: not state()['busy'])
        assert expr("require('tim').app.state.draft.text") == 'Keep the next message'
        chrome("require('tim').ui.draft", 'Retry')
        until(lambda: state()['requests'] == 5 and state()['busy'])
        chrome("require('tim').ui.draft", 'Cancel')
        until(lambda: not state()['busy'])
        input_text(''); keys('<Esc>')
        view('Diffs')
        # Select the pending second proposal, then inspect/approve/undo/reapply.
        assert expr("require('tim').ui.selected_proposal == require('tim').app.all_proposals[2].id")
        button('1. Fix the first line · rejected')
        button('2. Fix the first line · ready')
        button('Apply')
        until(lambda: expr("vim.api.nvim_buf_get_lines(require('tim').app.source_buf,0,1,false)[1]") == 'alpha fixed end')
        assert source.read_text().startswith('alpha Ωmega')
        button('Undo')
        until(lambda: expr("vim.api.nvim_buf_get_lines(require('tim').app.source_buf,0,1,false)[1]") == 'alpha Ωmega end')
        button('Apply')
        until(lambda: expr("require('tim').app.all_proposals[2].status") == 'applied')
        click("require('tim').app.source_buf", 1, 1); keys(':w<CR>')
        until(lambda: source.read_text().startswith('alpha fixed'))
        keys(':q<CR>'); editor.wait(timeout=5)
        assert editor.returncode == 0
        reader.join(timeout=2); os.close(master)
        # Reopen the same session and verify durable approval and safe undo.
        sock = str(work / 'reopened.sock')
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        editor = subprocess.Popen([NVIM, '-i', 'NONE', '--listen', sock, '--cmd', setup, '-u', str(ROOT / 'config/init.lua'), str(source)], cwd=work, env=env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave); reader = threading.Thread(target=drain, daemon=True); reader.start()
        until(lambda: Path(sock).exists())
        until(lambda: expr("require('tim').app ~= nil"))
        assert state()['requests'] == 5
        view('Diffs')
        assert any('applied' in line for line in panel())
        button('Undo')
        until(lambda: expr("vim.api.nvim_buf_get_lines(require('tim').app.source_buf,0,1,false)[1]") == 'alpha Ωmega end')
        assert source.read_text().startswith('alpha fixed')
        click("require('tim').app.source_buf", 1, 1); keys(':q<CR>c')
        until(lambda: state()['mode'] == 'n')
        assert editor.poll() is None and expr('vim.bo.modified')
        keys(':q<CR>n'); editor.wait(timeout=5)
        assert editor.returncode == 0
        print('PASS real UI: one input, Chat/Comments/Diffs, structured actions, stale Refresh, Reject, Cancel/Retry, Apply/Undo/save/reopen, quit')
    finally:
        if editor.poll() is None:
            editor.terminate()
            editor.wait(timeout=5)
        reader.join(timeout=2)
        os.close(master)
        log.seek(0)
        output = log.read()
        if editor.returncode != 0:
            print(output[-2000:])
        log.close()
