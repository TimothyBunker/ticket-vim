#!/usr/bin/env python3
"""Deterministic RPC fixture; production code never depends on Python."""
import json
import os
from pathlib import Path
import sys
import threading
import time

args = sys.argv[1:]
session = Path(args[args.index('--session') + 1])
session.parent.mkdir(parents=True, exist_ok=True)
entries = []
if session.exists():
    entries = [json.loads(line) for line in session.read_text().split('\n') if line]
    entries = [entry for entry in entries if entry.get('type') != 'session']
lock = threading.Lock()
active = False
timer = None


def emit(value, fragment=False):
    raw = json.dumps(value, ensure_ascii=False) + '\n'
    with lock:
        if fragment:
            middle = len(raw) // 2
            sys.stdout.write(raw[:middle]); sys.stdout.flush()
            time.sleep(0.01)
            sys.stdout.write(raw[middle:]); sys.stdout.flush()
        else:
            sys.stdout.write(raw); sys.stdout.flush()


def entry(role, text, stop=None, extra=None):
    value = {'type': 'message', 'id': f'entry-{len(entries) + 1}',
             'parentId': entries[-1]['id'] if entries else None,
             'timestamp': '2026-09-19T19:00:00Z',
             'message': {'role': role, 'content': [{'type': 'text', 'text': text}]}}
    if stop:
        value['message']['stopReason'] = stop
    if extra:
        value['message'].update(extra)
    entries.append(value)
    with session.open('a') as file:
        file.write(json.dumps(value, ensure_ascii=False) + '\n')
    return value


def finish(failed=False, review=False, review_task=False, empty=False, structured=False, fix=False):
    global active
    if not active:
        return
    response = 'Consider @[src/example.py]:2. Unicode stays intact: Ω\u2028tail.'
    if review:
        response = 'Check @[helper.py]:2 for the boundary case.\n\nThe current issue is @[example.py]:1.\n\n```diff\n--- a/example.py\n+++ b/example.py\n@@ -1,2 +1,2 @@\n-alpha Ωmega end\n+alpha fixed end\n tail text\n```'
    if review_task:
        response = response.replace('Consider @[src/example.py]:2.', 'Comment: @[src/example.py]:2 Consider this location.').replace('Check @[helper.py]:2 for the boundary case.', 'Comment: @[helper.py]:2 Check the boundary case.').replace('The current issue is @[example.py]:1.', 'Comment: @[example.py]:1 The current issue is here.')
    if structured or fix:
        def publish(kind, params):
            ident = f'tool-{len(entries)+1}'
            name = 'editor_comment' if kind == 'comment' else 'editor_propose_diff'
            emit({'type': 'tool_execution_start', 'toolCallId': ident, 'toolName': name})
            details = {'tim': {'version': 1, 'id': ident, 'kind': kind, **params}}
            entry('toolResult', 'Published', extra={'toolCallId': ident, 'toolName': name, 'details': details, 'isError': False})
            emit({'type': 'tool_execution_end', 'toolCallId': ident, 'toolName': name, 'result': {'details': details}})
            return ident
        if structured:
            publish('comment', {'path': 'helper.py', 'line_start': 2, 'body': 'Check this boundary case.'})
            target = publish('comment', {'path': 'example.py', 'line_start': 1, 'body': 'The first line needs a fix.'})
        else:
            target = next((e['message']['details']['tim']['id'] for e in reversed(entries)
                           if e['message'].get('toolName') == 'editor_comment' and e['message']['details']['tim']['path'] == 'example.py'), None)
        params = {'title': 'Fix the first line', 'diff': '--- a/example.py\n+++ b/example.py\n@@ -1,2 +1,2 @@\n-alpha Ωmega end\n+alpha fixed end\n tail text'}
        if target:
            params['comment_id'] = target
        publish('proposal', params)
        response = 'I published the findings and proposed fix. See @[example.py]:1 and @[helper.py]:2.'
    if empty:
        response = ''
    if failed:
        response = 'Provider request failed.'
    emit({'type': 'message_update', 'assistantMessageEvent': {'type': 'text_delta', 'delta': response}}, True)
    assistant = entry('assistant', response, 'error' if failed else 'stop')
    emit({'type': 'message_end', 'message': assistant['message']})
    emit({'type': 'agent_end'})
    active = False
    emit({'type': 'agent_settled'})


for line in sys.stdin:
    command = json.loads(line)
    kind = command['type']
    response = {'type': 'response', 'id': command.get('id'), 'command': kind, 'success': True}
    if kind == 'get_state':
        response['data'] = {'sessionFile': str(session), 'isStreaming': active}
    elif kind == 'get_entries':
        response['data'] = {'entries': entries, 'leafId': entries[-1]['id'] if entries else None}
    elif kind == 'prompt':
        prompt = command['message']
        if '[reject]' in prompt:
            response.update(success=False, error='Fixture rejected prompt')
        else:
            entry('user', prompt)
            if '[crash]' in prompt:
                os._exit(7)
            active = True
            emit(response, True)
            emit({'type': 'agent_start'})
            if '[slow]' not in prompt:
                if '[retry]' in prompt:
                    emit({'type': 'agent_end', 'willRetry': True})
                timer = threading.Timer(0.15, finish, kwargs={'structured': '[structured-review]' in prompt, 'fix': '[structured-fix]' in prompt, 'empty': '[empty]' in prompt, 'failed': '[error]' in prompt, 'review': '[workspace-review]' in prompt, 'review_task': 'User explicitly started Review.' in prompt})
                timer.start()
            continue
    elif kind == 'abort':
        if timer:
            timer.cancel()
        if active:
            assistant = entry('assistant', 'Cancelled.', 'aborted')
            emit({'type': 'message_end', 'message': assistant['message']})
        active = False
        emit(response)
        emit({'type': 'agent_settled'})
        continue
    emit(response, True)
