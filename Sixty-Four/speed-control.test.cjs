'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { setImmediate: nextTurn } = require('node:timers/promises');
const { startSpeedControl } = require('./speed-control.cjs');
function fixture(invoke = async () => {}) {
  const child = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter(); child.kill = () => child.emit('exit');
  const calls = [], spawns = [], logs = [];
  const control = startSpeedControl({ config: { speedControl: { enabled: true, helperPath: 'guard.exe', gameExe: 'game.exe', dllPath: 'speedpatch.dll' } }, parentPid: 42,
    spawnProcess(...args) { spawns.push(args); return child; }, invoke: async (...args) => { calls.push(args); return invoke(...args); }, report: value => logs.push(value) });
  const send = value => child.stdout.emit('data', Buffer.from(JSON.stringify(value) + '\n'));
  return { child, calls, spawns, logs, control, send };
}
const status = (enabled = true, factor = 100) => ({ ok: true, enabled, factor, processes: [{ pid: 42, isolated: true }] });
test('native guard runs hidden and authoritative enabled state alone selects the simulation factor', async () => {
  const f = fixture(); assert.equal(f.spawns[0][2].windowsHide, true);
  assert.deepEqual(f.spawns[0][1], ['--apply', '--watch', '--game', 'game.exe', '--dll', 'speedpatch.dll', '--parent', '42']);
  f.send(status()); await nextTurn(); f.send(status(false)); await nextTurn();
  assert.deepEqual(f.calls, [['syncSpeed', { enabled: true, factor: 100 }], ['syncSpeed', { enabled: false, factor: 1 }]]);
});
test('unisolated processes, helper errors and invalid output fail closed', async () => {
  const f = fixture();
  f.send({ ...status(), processes: [{ isolated: false }] }); await nextTurn();
  f.child.stdout.emit('data', Buffer.from('invalid\n')); await nextTurn();
  f.child.emit('error', new Error('stopped')); await nextTurn();
  f.child.emit('exit'); await nextTurn();
  assert.ok(f.calls.length >= 4); assert.ok(f.calls.every(([, args]) => args.enabled === false && args.factor === 1));
});
test('speed delivery coalesces while renderer is busy, without concurrent writes or stale queued factors', async () => {
  let resolve;
  const f = fixture(() => new Promise(done => { resolve = done; }));
  f.send(status(true, 100)); f.send(status(true, 300)); f.send(status(false, 300));
  assert.equal(f.calls.length, 1); resolve(); await nextTurn();
  assert.equal(f.calls.length, 2); assert.deepEqual(f.calls[1][1], { enabled: false, factor: 1 }); resolve(); await nextTurn();
  f.control.close(); assert.equal(f.calls.at(-1)[1].enabled, false);
});
