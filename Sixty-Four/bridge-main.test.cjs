'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const { setImmediate: nextTurn } = require('node:timers/promises');
const source = fs.readFileSync(path.join(__dirname, 'bridge-main.cjs'), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));

async function executor(options = {}) {
  const events = new EventEmitter();
  const child = new EventEmitter();
  const forks = [], replies = [], calls = [], logs = [];
  const dependencies = [];
  child.connected = true;
  child.send = (message, callback) => { replies.push(plain(message)); callback?.(null); };
  child.disconnect = () => { child.connected = false; child.emit('disconnect'); };
  const renderer = vm.createContext({ __invoke: options.behavior || ((action, args) => ({ action, args })), ...options.rendererGlobals });
  const contents = {
    getURL: () => 'file:///mock/resources/app/game/index.html',
    executeJavaScript: async expression => {
      calls.push(expression);
      return vm.runInContext(expression, renderer);
    },
  };
  function adapter(action, args) { return globalThis.__invoke(action, args); }
  function installAudio(game) {
    game.audioInstalls = (game.audioInstalls || 0) + 1;
    const controller = { setAcceleration(factor) { (game.audioFactors ||= []).push(factor); } };
    game[Symbol.for('sixtyfour.agent.audioGuard.v1')] = controller;
    return controller;
  }
  const config = { nodePath: process.execPath, token: 'test-only', port: 0, ...options.config };
  const modules = {
    'node:fs': { readFileSync: () => JSON.stringify(config), statSync: () => ({ isFile: () => true }), appendFileSync: (_, text) => logs.push(text) },
    'node:path': path,
    'node:child_process': { fork: (...args) => { forks.push(args); return child; } },
    electron: { app: { whenReady: () => Promise.resolve(), once: (...args) => events.once(...args) }, BrowserWindow: { getAllWindows: () => [{ isDestroyed: () => false, webContents: contents }] } },
    './renderer-adapter.cjs': adapter,
    './audio-guard.cjs': options.audioModule || { install: installAudio },
    './simulation-clock.cjs': require('./simulation-clock.cjs'),
  };
  const forbiddenTime = () => { throw new Error('Game-process clocks and timers must not control renderer RPC lifetime'); };
  const isolatedTime = options.forbidMainTime ? {
    setTimeout: forbiddenTime, clearTimeout: forbiddenTime, setInterval: forbiddenTime, clearInterval: forbiddenTime,
    performance: { now: forbiddenTime }, Date: class { constructor() { forbiddenTime(); } static now = forbiddenTime; },
  } : { setTimeout, clearTimeout };
  vm.runInNewContext(source, { require(name) { dependencies.push(name); assert.ok(Object.hasOwn(modules, name), `Unexpected dependency: ${name}`); return modules[name]; }, __dirname, ...isolatedTime }, { filename: 'bridge-main.cjs' });
  await nextTurn();
  return { events, child, forks, replies, calls, logs, contents, dependencies, renderer,
    async send(message) { child.emit('message', message); await nextTurn(); return replies.at(-1); } };
}

test('Steam-ready hook forks standalone Node with no inherited Electron exec arguments or visible console', async () => {
  const e = await executor();
  assert.equal(e.forks.length, 1);
  const [file, args, options] = e.forks[0];
  assert.equal(file, path.join(__dirname, 'bridge-gateway.cjs'));
  assert.deepEqual(plain(args), []);
  assert.equal(options.execPath, process.execPath);
  assert.deepEqual(plain(options.execArgv), []);
  assert.equal(options.windowsHide, true);
  assert.deepEqual(plain(options.stdio), ['ignore', 'ignore', 'ignore', 'ipc']);
  assert.equal(e.calls.length, 0);
});

test('private IPC operations and normal commands reach adapter with literal, non-executable arguments', async () => {
  const e = await executor();
  const literal = '\");throw new Error("injected");//\n${process.env}';
  for (const [index, action] of ['state', 'catalog', 'save', 'resume', 'place', 'remove', 'interact', 'beginInteraction', 'endInteraction', 'releaseInteractions'].entries()) {
    const result = await e.send({ id: index + 1, action, args: { text: literal } });
    assert.deepEqual(result, { id: index + 1, result: { ok: true, data: { action, args: { text: literal } } } });
  }
});

test('invalid IPC identifiers are ignored; unknown commands and invalid args never reach renderer', async () => {
  const e = await executor();
  for (const id of [undefined, '1', 0, -1, Infinity, 1.5, Number.MAX_SAFE_INTEGER + 1]) await e.send({ id, action: 'state', args: {} });
  assert.equal(e.replies.length, 0);
  for (const [index, action] of ['eval', 'executeJavaScript', '__proto__', 'constructor'].entries()) {
    const reply = await e.send({ id: index + 1, action, args: {} });
    assert.equal(reply.result.error.code, 'BAD_REQUEST');
  }
  for (const args of [null, undefined, [], 'bad']) {
    assert.equal((await e.send({ id: 20, action: 'save', args })).result.error.code, 'BAD_REQUEST');
  }
  assert.equal(e.calls.length, 0);
});

test('native game errors, renderer failures, and absent game windows return result envelopes', async () => {
  const e = await executor({ behavior: () => { throw Object.assign(new Error('Cannot afford'), { code: 'INSUFFICIENT_RESOURCES' }); } });
  assert.deepEqual((await e.send({ id: 1, action: 'place', args: {} })).result, { ok: false, error: { code: 'INSUFFICIENT_RESOURCES', message: 'Cannot afford' } });
  e.contents.executeJavaScript = async () => { throw new Error('Renderer disconnected'); };
  assert.equal((await e.send({ id: 2, action: 'state', args: {} })).result.error.code, 'BRIDGE_ERROR');
  e.contents.getURL = () => 'file:///other/index.html';
  assert.equal((await e.send({ id: 3, action: 'state', args: {} })).result.error.code, 'NOT_READY');
});

test('duplicate outstanding request ids cannot execute a mutation twice', async () => {
  let release;
  const wait = new Promise(resolve => { release = resolve; });
  const e = await executor({ behavior: async () => { await wait; return 'done'; } });
  e.child.emit('message', { id: 1, action: 'place', args: {} });
  e.child.emit('message', { id: 1, action: 'place', args: {} });
  assert.equal(e.calls.length, 1);
  release();
  await nextTurn();
  assert.equal(e.replies.length, 1);
});

test('normal quit releases holds and disconnects child; later disconnect/exit never restart it', async () => {
  const e = await executor();
  e.events.emit('before-quit');
  assert.equal(e.child.connected, false);
  await nextTurn();
  assert.equal(e.calls.length, 1);
  assert.match(e.calls[0], /releaseInteractions/);
  e.child.emit('exit', 0);
  await e.send({ id: 1, action: 'state', args: {} });
  assert.equal(e.calls.length, 1);
  assert.equal(e.forks.length, 1);
  assert.equal(e.replies.length, 0);
});

test('unexpected child exit releases holds once, logs failure, and has no restart loop', async () => {
  const e = await executor();
  e.child.connected = false;
  e.child.emit('disconnect');
  e.child.emit('exit', 1);
  await nextTurn();
  assert.equal(e.calls.length, 1);
  assert.match(e.logs.join(''), /Gateway exited/);
  assert.equal(e.forks.length, 1);
});

test('missing standalone Node configuration cannot accidentally fork the Electron binary', async () => {
  const e = await executor({ config: { nodePath: undefined } });
  assert.equal(e.forks.length, 0);
  assert.match(e.logs.join(''), /standalone Node.js 24/);
});


test('renderer RPC remains outstanding until native completion without any game-process clock or timer', async () => {
  let complete;
  const native = new Promise(resolve => { complete = resolve; });
  const e = await executor({ behavior: () => native, forbidMainTime: true, config: { rendererTimeoutMs: 100 } });
  e.child.emit('message', { id: 1, action: 'interact', args: {} });
  for (let turn = 0; turn < 4; turn++) await nextTurn();
  assert.equal(e.calls.length, 1);
  assert.equal(e.replies.length, 0, 'A stalled native mutation must not produce an early completion envelope');
  e.child.emit('message', { id: 1, action: 'interact', args: {} });
  assert.equal(e.calls.length, 1, 'The outstanding native request must retain its duplicate-execution guard');
  complete('native mutation settled');
  await nextTurn();
  assert.deepEqual(e.replies, [{ id: 1, result: { ok: true, data: 'native mutation settled' } }]);
  assert.equal(e.logs.length, 0);
});

test('late native rejection is returned only when actual RPC settles and is never replaced by a timeout', async () => {
  const e = await executor({ forbidMainTime: true });
  let rejectNative;
  e.contents.executeJavaScript = () => new Promise((_, reject) => { rejectNative = reject; });
  e.child.emit('message', { id: 1, action: 'place', args: {} });
  await nextTurn();
  assert.equal(e.replies.length, 0);
  rejectNative(Object.assign(new Error('late native failure'), { code: 'NATIVE_FAILURE' }));
  await nextTurn();
  assert.deepEqual(e.replies, [{ id: 1, result: { ok: false, error: { code: 'NATIVE_FAILURE', message: 'late native failure' } } }]);
});

test('speed synchronization is unavailable without explicit configuration and never loads its game clock', async () => {
  for (const speedControl of [undefined, { enabled: false }]) {
    const e = await executor({ config: { speedControl }, forbidMainTime: true });
    assert.equal(e.dependencies.includes('./simulation-clock.cjs'), false);
    const result = await e.send({ id: 1, action: 'syncSpeed', args: { enabled: true, factor: 100 } });
    assert.equal(result.result.error.code, 'NOT_CONFIGURED');
    assert.equal(e.calls.length, 0);
    const normal = await e.send({ id: 2, action: 'state', args: {} });
    assert.equal(normal.result.ok, true);
  }
});

test('ordinary requests install audio once without speed-control configuration and preserve its acceleration', async () => {
  const game = {};
  const e = await executor({ rendererGlobals: { game }, forbidMainTime: true });
  assert.equal((await e.send({ id: 1, action: 'state', args: {} })).result.ok, true);
  const controller = game[Symbol.for('sixtyfour.agent.audioGuard.v1')];
  assert.ok(controller);
  controller.setAcceleration(100);
  assert.equal((await e.send({ id: 2, action: 'catalog', args: {} })).result.ok, true);
  assert.equal(game.audioInstalls, 1);
  assert.deepEqual(Array.from(game.audioFactors), [100], 'A normal request must not reset an established acceleration');
  assert.equal(e.dependencies.filter(name => name === './audio-guard.cjs').length, 1);
});

test('the actual audio module stringifies into an early renderer without AudioContext and synchronizes its existing controller', async () => {
  const game = {
    playSound() {}, startSound() {}, stopSound() {},
    time: { lt: 1000 }, stats: { totalPlayTime: 0 }, updateLoop() {}, updateCycle() { return true; },
  };
  const original = game.playSound;
  const e = await executor({
    config: { speedControl: { enabled: true } }, forbidMainTime: true,
    audioModule: require('./audio-guard.cjs'), rendererGlobals: { game, performance: { now: () => 1000 } },
    behavior: () => game.agentAudioStatus(),
  });
  const early = await e.send({ id: 1, action: 'state', args: {} });
  assert.equal(early.result.ok, true);
  assert.equal(early.result.data.context, null);
  assert.equal(early.result.data.acceleration, 1);
  assert.notEqual(game.playSound, original);
  const controller = game[Symbol.for('sixtyfour.agent.audioGuard.v1')];
  assert.equal((await e.send({ id: 2, action: 'syncSpeed', args: { enabled: true, factor: 100 } })).result.ok, true);
  assert.equal((await e.send({ id: 3, action: 'state', args: {} })).result.data.acceleration, 100);
  assert.equal((await e.send({ id: 4, action: 'syncSpeed', args: { enabled: false, factor: 100 } })).result.ok, true);
  assert.equal(game.agentAudioStatus().acceleration, 1);
  assert.equal(game[Symbol.for('sixtyfour.agent.audioGuard.v1')], controller);
});

test('configured internal speed samples install once, toggle100x to1x and bypass the interaction dispatcher', async () => {
  let now = 1000;
  let ordinaryCalls = 0;
  const acknowledgements = [];
  const nativeUpdateLoop = function () {};
  const game = {
    time: { lt: now }, stats: { totalPlayTime: 0 }, updateLoop: nativeUpdateLoop,
    updateCycle(span) { this.time.dt = span; return true; },
    clock: { postMessage(done) { acknowledgements.push(done); } },
  };
  const e = await executor({
    config: { speedControl: { enabled: true } }, forbidMainTime: true,
    rendererGlobals: { game, performance: { now: () => now } },
    behavior: () => { ordinaryCalls++; throw Object.assign(new Error('Finish active interaction'), { code: 'INTERACTION_ACTIVE' }); },
  });
  assert.equal(e.dependencies.filter(name => name === './simulation-clock.cjs').length, 1);
  const enabled = await e.send({ id: 1, action: 'syncSpeed', args: { enabled: true, factor: 100, _untrusted: 'discarded' } });
  assert.equal(enabled.result.ok, true);
  assert.equal(enabled.result.data.factor, 100);
  assert.equal(game.audioInstalls, 1);
  assert.deepEqual(Array.from(game.audioFactors), [100]);
  const installedMethod = game.updateLoop;
  const controller = game[Symbol.for('sixtyfour.experimental.simulationClock.v1')];
  assert.notEqual(installedMethod, nativeUpdateLoop);
  now = 1005; game.updateLoop();
  assert.equal(game.stats.totalPlayTime, 500);
  const ordinary = await e.send({ id: 2, action: 'place', args: {} });
  assert.equal(ordinary.result.error.code, 'INTERACTION_ACTIVE');
  const disabled = await e.send({ id: 3, action: 'syncSpeed', args: { enabled: false, factor: 100 } });
  assert.equal(disabled.result.ok, true);
  assert.equal(disabled.result.data.factor, 1);
  assert.equal(game.audioInstalls, 1, 'Do not install another audio wrapper');
  assert.deepEqual(Array.from(game.audioFactors), [100, 1], 'Every speed sample must refresh even an existing audio controller');
  assert.equal(game.updateLoop, installedMethod, 'Do not stack a second simulation wrapper');
  assert.equal(game[Symbol.for('sixtyfour.experimental.simulationClock.v1')], controller);
  now = 1010; game.updateLoop();
  assert.equal(game.stats.totalPlayTime, 505);
  assert.equal(game.time.lt, 1010, 'Native real-clock baseline must remain unscaled');
  assert.equal(ordinaryCalls, 1, 'syncSpeed must bypass adapter hold exclusivity without touching hold state');
  assert.deepEqual(acknowledgements, [true, true]);
  now = 3011;
  assert.equal(game.agentSpeedStatus().expired, true);
  assert.equal(game.agentSpeedStatus().factor, 1, 'Loss of authoritative speed samples fails closed');
  assert.equal(e.logs.length, 0);
});

test('invalid internal speed samples never execute renderer code or install a controller', async () => {
  const e = await executor({ config: { speedControl: { enabled: true } }, forbidMainTime: true });
  const invalid = [
    {}, { enabled: 'true', factor: 100 }, { enabled: 1, factor: 100 },
    { enabled: true }, { enabled: true, factor: '100' }, { enabled: true, factor: NaN },
    { enabled: true, factor: Infinity }, { enabled: true, factor: 0 },
    { enabled: true, factor: -1 }, { enabled: true, factor: 1000.001 },
    { enabled: false, factor: NaN },
  ];
  for (const [index, args] of invalid.entries()) {
    const reply = await e.send({ id: index + 1, action: 'syncSpeed', args });
    assert.equal(reply.result.error.code, 'BAD_ARGUMENT');
  }
  assert.equal(e.calls.length, 0);
});

test('a configured speed sample before the game exists reports NOT_READY without altering unrelated commands', async () => {
  const e = await executor({ config: { speedControl: { enabled: true } }, forbidMainTime: true });
  const reply = await e.send({ id: 1, action: 'syncSpeed', args: { enabled: false, factor: 1 } });
  assert.equal(reply.result.ok, false);
  assert.equal(reply.result.error.code, 'NOT_READY');
  const normal = await e.send({ id: 2, action: 'state', args: {} });
  assert.equal(normal.result.ok, true);
});
