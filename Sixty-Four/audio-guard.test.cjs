'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { install } = require('./audio-guard.cjs');

class Events {
  constructor() { this.listeners = new Map(); }
  addEventListener(type, fn) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(fn);
  }
  removeEventListener(type, fn) { this.listeners.get(type)?.delete(fn); }
  emit(type) {
    const event = { type, target: this };
    for (const fn of [...(this.listeners.get(type) || [])]) fn.call(this, event);
    this[`on${type}`]?.call(this, event);
  }
}
class AudioNode extends Events {
  constructor(context, kind) {
    super(); this.context = context; this.kind = kind; this.disconnects = 0; this.connections = [];
    context.nodes.push(this);
  }
  connect(destination) { this.context.fail(`${this.kind}.connect`); this.connections.push(destination); return destination; }
  disconnect() { this.disconnects++; this.connections = []; }
}
class Source extends AudioNode {
  constructor(context) {
    super(context, 'source'); this.detune = { value: 0 }; this.loop = false; this.starts = []; this.stops = [];
    this.onended = function (event) { context.priorEnded.push({ receiver: this, event }); };
  }
  start(time) {
    this.context.fail('source.start'); this.starts.push(time); this.context.live.add(this);
    this.context.peak = Math.max(this.context.peak, this.context.live.size);
  }
  stop(time = this.context.currentTime) {
    this.context.fail('source.stop'); this.stops.push(time); this.stopAt = time;
    if (time <= this.context.currentTime) this.context.live.delete(this);
  }
  end() { this.context.live.delete(this); this.emit('ended'); }
}
class FakeAudioContext extends Events {
  constructor() {
    super(); this.state = 'running'; this.currentTime = 10; this.sampleRate = 48000; this.baseLatency = 0.01;
    this.nodes = []; this.sources = []; this.live = new Set(); this.peak = 0; this.priorEnded = []; this.fault = null;
  }
  fail(point) { if (this.fault === point) { this.fault = null; throw new Error(`audio fixture failure: ${point}`); } }
  createBufferSource() { this.fail('createBufferSource'); const node = new Source(this); this.sources.push(node); return node; }
  createGain() {
    this.fail('createGain'); const node = new AudioNode(this, 'gain');
    node.gain = { value: 1, ramps: [], exponentialRampToValueAtTime(value, time) { this.ramps.push({ value, time }); } };
    return node;
  }
  createStereoPanner() { this.fail('createStereoPanner'); const node = new AudioNode(this, 'pan'); node.pan = { value: 0 }; return node; }
  createBiquadFilter() { this.fail('createBiquadFilter'); return new AudioNode(this, 'filter'); }
  resume() { this.state = 'running'; return Promise.resolve(); }
  close() { this.state = 'closed'; this.emit('statechange'); return Promise.resolve(); }
  advanceAudio(seconds) {
    this.currentTime += seconds;
    for (const source of [...this.live]) if (source.stopAt <= this.currentTime) source.end();
  }
}

function fixture(options = {}, factory = install) {
  let time = 1000;
  const calls = [];
  const native = {};
  for (const method of ['playSound', 'startSound', 'stopSound']) native[method] = function (...args) {
    calls.push({ method, receiver: this, args });
    if (args[0] === 'native-throws') throw new Error('native failure');
    return native[method].result;
  };
  native.startSound.result = { native: true };
  native.playSound.result = Symbol('native result');
  native.stopSound.result = 'native stopped';
  const context = new FakeAudioContext();
  const game = Object.assign(Object.create(native), {
    actx: context, preventNoise: false, plane: false, slowdown: { state: false, multiplyer: 1, f: 0 },
    sfx: { ready: true, stackSize: 0, master: { master: true }, samples: {
      a: { data: { duration: 2 }, volume: 0.4, duration: 0.25, detune: 0 },
      b: { data: { duration: 1 }, volume: 0.6, detune: 0 },
    } },
    resources: [123, 456], stats: { totalPlayTime: 99, totalCubeClicks: 7 }, time: { lt: 12, dt: 5 },
  });
  const beforeSimulation = JSON.stringify({ resources: game.resources, stats: game.stats, time: game.time });
  const handle = factory(game, { now: () => time, ...options });
  return { game, context, handle, calls, native, time: value => { time = value; }, beforeSimulation,
    assertSimulationUnchanged() { assert.equal(JSON.stringify({ resources: game.resources, stats: game.stats, time: game.time }), beforeSimulation); } };
}
const statusFields = ['activeVoices', 'started', 'dropped', 'cleaned', 'errors', 'peakVoices'];
function assertCleanedNodes(context) {
  for (const node of context.nodes) assert.equal(node.disconnects, 1, `${node.kind} must be disconnected exactly once`);
}

test('default bounded mode preserves native audio parameters and leaves simulation untouched', () => {
  const f = fixture();
  assert.equal(f.handle.getStatus().mode, 'bounded');
  for (const key of statusFields) assert.ok(Number.isFinite(f.handle.getStatus()[key]), key);
  f.game.plane = true;
  f.game.slowdown = { state: true, multiplyer: 2, f: 0.25 };
  f.game.playSound('a', -0.25, 0.5, false, true);
  const source = f.context.sources[0];
  assert.equal(source.buffer, f.game.sfx.samples.a.data);
  assert.equal(source.detune.value, 100);
  assert.deepEqual(source.starts, [10]);
  assert.deepEqual(source.stops, [10.25]);
  assert.equal(f.context.nodes.find(n => n.kind === 'pan').pan.value, -0.25);
  assert.equal(f.context.nodes.find(n => n.kind === 'gain').gain.value, 0.2);
  assert.equal(f.context.nodes.find(n => n.kind === 'filter').type, 'lowpass');
  assert.equal(f.calls.length, 0, 'bounded mode must not call the old timer-based implementation');
  f.assertSimulationUnchanged();
  source.end(); assertCleanedNodes(f.context);
});

test('native mode purely delegates all methods, receiver, return and thrown error', () => {
  const f = fixture(); f.handle.setMode('native');
  const receiver = {};
  assert.equal(f.game.playSound.call(receiver, 'a', 0.2, 0.5, true, true), f.native.playSound.result);
  assert.equal(f.game.startSound.call(receiver, 'a', 0.2, 0.5), f.native.startSound.result);
  assert.equal(f.game.stopSound.call(receiver, f.native.startSound.result, 3), f.native.stopSound.result);
  assert.ok(f.calls.every(call => call.receiver === receiver));
  assert.deepEqual(f.calls[0].args, ['a', 0.2, 0.5, true, true]);
  assert.throws(() => f.game.playSound('native-throws'), /native failure/);
  assert.equal(f.context.nodes.length, 0);
});

test('one-shot, loop and forced audio share the hard active-voice ceiling', () => {
  const f = fixture({ maxVoices: 3, maxPerSecond: 100, maxPerSoundPerSecond: 100 });
  f.game.startSound('a'); f.game.playSound('b'); f.game.playSound('a', 0, 1, false, true);
  assert.equal(f.context.sources.length, 3);
  for (let i = 0; i < 100; i++) { f.game.playSound('a', 0, 1, false, true); f.game.startSound('b'); }
  assert.equal(f.context.sources.length, 3);
  assert.equal(f.handle.getStatus().activeVoices, 3);
  assert.equal(f.handle.getStatus().peakVoices, 3);
  assert.ok(f.handle.getStatus().dropped >= 200);
  f.context.sources[0].end();
  assert.ok(f.game.startSound('b'));
  assert.equal(f.handle.getStatus().activeVoices, 3);
  f.assertSimulationUnchanged();
  f.handle.uninstall();
});

test('global admission rate is a rolling real-second limit, including forced and loop sounds', () => {
  const f = fixture({ maxVoices: 20, maxPerSecond: 2, maxPerSoundPerSecond: 20 });
  f.time(1900); f.game.playSound('a', 0, 1, false, true); f.context.sources.at(-1).end();
  f.time(1999); f.game.startSound('b'); f.context.sources.at(-1).end();
  f.time(2001); f.game.playSound('b', 0, 1, false, true); f.game.startSound('a');
  assert.equal(f.context.sources.length, 2, 'crossing a bucket boundary must not reset the rate early');
  f.time(2901); f.game.playSound('a', 0, 1, false, true);
  assert.equal(f.context.sources.length, 3);
  f.handle.uninstall();
});

test('per-sound rate limits survive ended cleanup while other sound IDs remain usable', () => {
  const f = fixture({ maxVoices: 20, maxPerSecond: 10, maxPerSoundPerSecond: 2 });
  for (let i = 0; i < 2; i++) { f.game.playSound('a', 0, 1, false, true); f.context.sources.at(-1).end(); }
  f.game.startSound('a');
  assert.equal(f.context.sources.length, 2);
  assert.ok(f.game.startSound('b'));
  assert.equal(f.context.sources.length, 3);
  f.time(2001); assert.ok(f.game.startSound('a'));
  f.handle.uninstall();
});

test('100x loop churn retains capacity until actual ended and caps accelerated stop tails', () => {
  const f = fixture({ maxVoices: 4, maxPerSecond: 100, maxPerSoundPerSecond: 100, maxFadeSeconds: 0.05 });
  f.handle.setAcceleration(100);
  for (let simulatedCycle = 0; simulatedCycle < 1000; simulatedCycle++) {
    const bundle = f.game.startSound('a', 0.3, 0.5);
    if (bundle) {
      assert.equal(bundle.source.loop, true); assert.equal(bundle.baseVolume, 0.4);
      assert.equal(bundle.pan.pan.value, 0.3); assert.equal(bundle.volume.gain.value, 0.2);
      f.game.stopSound(bundle, 3);
      assert.ok(bundle.source.stops.at(-1) <= f.context.currentTime + 0.05 + 1e-9);
      assert.ok(bundle.volume.gain.ramps.at(-1).time <= f.context.currentTime + 0.05 + 1e-9);
    }
  }
  assert.equal(f.context.sources.length, 4, 'stop scheduling is not equivalent to releasing a live voice');
  assert.equal(f.handle.getStatus().activeVoices, 4);
  f.time(100000); f.game.startSound('b');
  assert.equal(f.context.sources.length, 4, 'advancing JS time alone must not free Web Audio voices');
  f.context.advanceAudio(0.051);
  assert.equal(f.handle.getStatus().activeVoices, 0);
  assertCleanedNodes(f.context);
  assert.ok(f.game.startSound('b'));
  assert.ok(f.context.peak <= 4);
  f.assertSimulationUnchanged();
  f.handle.uninstall();
});

test('1x preserves requested fade and foreign bundles always delegate native stopSound', () => {
  const f = fixture();
  const own = f.game.startSound('a');
  f.game.stopSound(own, 3);
  assert.equal(own.source.stops.at(-1), f.context.currentTime + 3);
  f.handle.setAcceleration(100);
  const foreign = { source: {}, volume: {} };
  assert.equal(f.game.stopSound(foreign, 3), f.native.stopSound.result);
  assert.deepEqual(f.calls.at(-1).args, [foreign, 3]);
  f.handle.uninstall();
});

test('ended cleanup preserves a previous handler and is idempotent across duplicate events and close', async () => {
  const f = fixture(); f.game.playSound('a');
  const source = f.context.sources[0];
  source.end();
  assert.equal(f.context.priorEnded.length, 1);
  assert.equal(f.context.priorEnded[0].receiver, source);
  assert.equal(f.context.priorEnded[0].event.type, 'ended');
  assert.equal(f.handle.getStatus().activeVoices, 0);
  assert.equal(f.handle.getStatus().cleaned, 1);
  source.end(); await f.context.close(); f.handle.uninstall();
  assert.equal(f.handle.getStatus().cleaned, 1);
  assertCleanedNodes(f.context);
});

test('context close releases loop/one-shot nodes once and preserves existing statechange handler', async () => {
  const f = fixture(); let nativeEvents = 0;
  f.context.onstatechange = () => nativeEvents++;
  f.game.startSound('a'); f.game.playSound('b');
  await f.context.close();
  assert.equal(nativeEvents, 1);
  assert.equal(f.handle.getStatus().activeVoices, 0);
  assert.equal(f.handle.getStatus().cleaned, 2);
  for (const source of f.context.sources) source.end();
  f.handle.uninstall();
  assert.equal(f.handle.getStatus().cleaned, 2);
  assertCleanedNodes(f.context);
});

test('partial creation/connect/start/stop failures clean owned nodes and do not throw into simulation', () => {
  for (const fault of ['createGain', 'createStereoPanner', 'createBiquadFilter', 'source.connect', 'source.start', 'source.stop']) {
    const f = fixture(); f.game.plane = true; f.context.fault = fault;
    assert.doesNotThrow(() => f.game.playSound('a'), fault);
    assert.equal(f.handle.getStatus().activeVoices, 0, fault);
    assert.ok(f.handle.getStatus().errors >= 1, fault);
    for (const source of f.context.sources) source.end();
    f.handle.uninstall();
    assertCleanedNodes(f.context);
    f.assertSimulationUnchanged();
  }
});

test('loop creation and owned stop ramp/stop errors also release every node exactly once', () => {
  for (const fault of ['createGain', 'source.connect', 'source.start']) {
    const f = fixture(); f.context.fault = fault;
    assert.doesNotThrow(() => f.game.startSound('a'), fault);
    assert.equal(f.handle.getStatus().activeVoices, 0);
    assert.ok(f.handle.getStatus().errors >= 1);
    f.handle.uninstall(); assertCleanedNodes(f.context); f.assertSimulationUnchanged();
  }
  for (const fault of ['ramp', 'source.stop']) {
    const f = fixture(); const bundle = f.game.startSound('a');
    if (fault === 'ramp') bundle.volume.gain.exponentialRampToValueAtTime = () => { throw new Error('ramp failed'); };
    else f.context.fault = fault;
    assert.doesNotThrow(() => f.game.stopSound(bundle, 3));
    assert.equal(f.handle.getStatus().activeVoices, 0);
    assert.equal(f.handle.getStatus().cleaned, 1);
    bundle.source.end(); f.game.stopSound(bundle, 3); f.handle.uninstall();
    assert.equal(f.handle.getStatus().cleaned, 1);
    assertCleanedNodes(f.context); f.assertSimulationUnchanged();
  }
});

test('a rejected resume promise cleans the admitted voice without unhandled rejection', async () => {
  const f = fixture(); f.context.state = 'suspended';
  f.context.resume = () => Promise.reject(new Error('fixture resume failed'));
  assert.doesNotThrow(() => f.game.playSound('a'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.handle.getStatus().activeVoices, 0);
  assert.ok(f.handle.getStatus().errors >= 1);
  for (const source of f.context.sources) source.end();
  f.handle.uninstall(); assertCleanedNodes(f.context); f.assertSimulationUnchanged();
});

test('legacy onended fallback preserves the old callback and cleans even when it throws', () => {
  const f = fixture();
  const originalCreate = f.context.createBufferSource.bind(f.context);
  let oldEnded;
  f.context.createBufferSource = () => {
    const source = originalCreate();
    source.addEventListener = undefined;
    oldEnded = function () { throw new Error('original ended callback'); };
    source.onended = oldEnded;
    return source;
  };
  const bundle = f.game.startSound('a');
  assert.throws(() => bundle.source.end(), /original ended callback/);
  assert.equal(bundle.source.onended, oldEnded);
  assert.equal(f.handle.getStatus().activeVoices, 0);
  assert.equal(f.handle.getStatus().cleaned, 1);
  f.handle.uninstall(); assertCleanedNodes(f.context);
});

test('missing context/sample, not-ready and preventNoise safely skip then recover when available', () => {
  const f = fixture();
  delete f.game.actx;
  assert.doesNotThrow(() => { f.game.playSound('a'); f.game.startSound('a'); });
  f.game.actx = f.context;
  assert.doesNotThrow(() => { f.game.playSound('missing'); f.game.startSound('missing'); });
  f.game.sfx.samples.invalid = { data: null, volume: 0.5 };
  assert.doesNotThrow(() => f.game.playSound('invalid'));
  f.game.preventNoise = true; f.game.playSound('a'); f.game.startSound('a');
  f.game.preventNoise = false; f.game.sfx.ready = false; f.game.playSound('a');
  assert.equal(f.context.nodes.length, 0);
  f.game.sfx.ready = true;
  assert.ok(f.game.startSound('a'));
  f.handle.uninstall(); f.assertSimulationUnchanged();
});

test('non-finite and rolled-back wall samples fail closed until last valid time is reached', () => {
  const f = fixture({ maxPerSecond: 20, maxPerSoundPerSecond: 20 });
  f.game.playSound('a'); f.context.sources[0].end();
  for (const bad of [NaN, Infinity, 900, 999]) { f.time(bad); f.game.playSound('a', 0, 1, false, true); f.game.startSound('b'); }
  assert.equal(f.context.sources.length, 1);
  f.time(1001); assert.ok(f.game.startSound('b'));
  f.handle.uninstall();
});

test('a throwing wall-clock provider cannot turn an audio call into a simulation exception', () => {
  const f = fixture({ now() { throw new Error('clock provider failed'); } });
  assert.doesNotThrow(() => { f.game.playSound('a'); f.game.startSound('b'); });
  assert.equal(f.context.nodes.length, 0);
  assert.ok(f.handle.getStatus().errors >= 2);
  f.assertSimulationUnchanged(); f.handle.uninstall();
});

test('invalid options reject before changing game methods', () => {
  for (const options of [{ maxVoices: 0 }, { maxVoices: 1.5 }, { maxPerSecond: -1 }, { maxPerSoundPerSecond: Infinity }, { maxFadeSeconds: -1 }, { maxFadeSeconds: NaN }, { now: 'not a function' }]) {
    const game = { playSound() {}, startSound() {}, stopSound() {} };
    const before = Object.getOwnPropertyDescriptors(game);
    assert.throws(() => install(game, options));
    assert.deepEqual(Object.getOwnPropertyDescriptors(game), before);
  }
});

test('silent and native transitions clean only owned voices; silent does not create nodes', () => {
  const f = fixture(); f.game.startSound('a');
  f.handle.setMode('silent');
  assert.equal(f.handle.getStatus().activeVoices, 0);
  assertCleanedNodes(f.context);
  const count = f.context.nodes.length;
  f.game.playSound('a', 0, 1, false, true); f.game.startSound('b');
  assert.equal(f.context.nodes.length, count);
  f.handle.setMode('native'); assert.equal(f.game.startSound('a'), f.native.startSound.result);
  assert.equal(f.handle.getStatus().activeVoices, 0, 'this counts only guard-owned voices, not untracked native audio');
  f.handle.setMode('bounded'); assert.ok(f.game.startSound('b'));
  f.handle.uninstall();
});

test('uninstall restores inherited methods without overwriting later third-party wrappers', () => {
  const f = fixture(); f.game.startSound('a');
  const guardedPlay = f.game.playSound;
  const outer = function (...args) { return guardedPlay.apply(this, args); };
  f.game.playSound = outer;
  f.handle.uninstall(); f.handle.uninstall();
  assert.equal(f.game.playSound, outer);
  assert.equal(Object.hasOwn(f.game, 'startSound'), false);
  assert.equal(Object.hasOwn(f.game, 'stopSound'), false);
  assert.equal(f.game.startSound, f.native.startSound);
  assertCleanedNodes(f.context);
});

test('factory runs stringified in an isolated renderer without JavaScript cleanup timers', () => {
  const realm = vm.createContext({ performance: { now: () => 1000 },
    setTimeout() { throw new Error('cleanup must follow AudioNode lifecycle, not a JS timer'); },
    setInterval() { throw new Error('no cleanup poller'); } });
  const factory = vm.runInContext(`(${install.toString()})`, realm);
  const f = fixture({ maxVoices: 1 }, factory);
  f.game.playSound('a');
  assert.equal(f.context.sources.length, 1);
  f.time(100000); f.game.playSound('b');
  assert.equal(f.context.sources.length, 1);
  f.context.sources[0].end();
  assert.equal(f.handle.getStatus().activeVoices, 0);
  assertCleanedNodes(f.context);
  f.handle.uninstall();
});
