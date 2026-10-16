import assert from 'node:assert/strict';
import test from 'node:test';
import { commandFromResponse, readPrompt } from '../shell/command.mjs';

test('readline request quoting is decoded without evaluating shell code', () => {
  assert.equal(readPrompt(`tt "search for 'egg salad' in lunch menu directory"`),
    "search for 'egg salad' in lunch menu directory");
  assert.equal(readPrompt(`tt 'find it'\\''s menu'`), "find it's menu");
  assert.equal(readPrompt('  tt search lunch\\ menu  '), 'search lunch menu');
  assert.equal(readPrompt('tt "explain $(touch nope) and `whoami` and $HOME"'),
    'explain $(touch nope) and `whoami` and $HOME');
  assert.equal(readPrompt('tt "literal \\q"'), 'literal \\q');
  assert.throws(() => readPrompt('tt "unfinished'), /Finish/);
  assert.throws(() => readPrompt('tt search; touch nope'), /quotes/);
  assert.throws(() => readPrompt('tt $(touch nope)'), /quotes/);
});

test('only a single printable command can reach the editable line', () => {
  const good = "grep -RnF -- 'egg salad' 'lunch menu'";
  assert.equal(commandFromResponse(JSON.stringify({ command: good })), good);
  assert.equal(commandFromResponse('{"command":"echo café"}'), 'echo café');
  for (const value of ['', ' ', 'echo ok\necho bad', 'echo ok\recho bad',
    'echo\tbad', 'echo \u001b[31m', 'echo \u0000', 'echo\u0085bad', '```sh echo ok```', 'x'.repeat(8193), null, 42]) {
    assert.throws(() => commandFromResponse(JSON.stringify({ command: value })));
  }
  assert.throws(() => commandFromResponse('Here is your command: echo ok'));
  assert.throws(() => commandFromResponse('{"command":"echo ok"}\nextra'));
});
