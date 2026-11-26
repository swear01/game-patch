'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const dispatchSource = require('./renderer-adapter.cjs').toString();

function fixture({ forbidRendererTime = false } = {}) {
  const machine = { name: 'pump', position: [0, 0], state: 2, active: false,
    onmousedown() { this.active = true; }, onmouseup() { this.active = false; }, canHit() { return true; } };
  const existingUI = { name: 'unrelated-selection' };
  const g = {
    codex: { entities: {
      pump: { class: function () {}, canPurchase: true, price: [25] },
      locked: { class: function () {}, canPurchase: true, price: [1] },
      eraser: { canPurchase: true, price: [1] },
    }, resources: ['Charonite', 'Elmerine', 'Qanetite', 'Beta-Pylene', 'Hell Gem', 'Chromalit', 'Celestialfoam', 'Hollowstone', 'Void', null].map((name) => name ? { name } : {}) },
    shop: {}, resources: Array(10).fill(100), stuff: [machine], entitiesInGame: { pump: 1 },
    unlockedEntities: { pump: true, eraser: true }, onlyones: {}, plane: 0, eraserType: 0,
    splash: { isShown: false, gameIsMute: false, close() { this.isShown = false; }, show() { this.isShown = true; } },
    toggleSplashCalls: 0, audioInitCalls: 0,
    initAudio() { this.audioInitCalls++; this.actx = { state: 'running' }; },
    toggleSplash() {
      this.toggleSplashCalls++;
      if (this.splash.isShown) {
        if (!this.actx && !this.splash.gameIsMute) this.initAudio();
        this.splash.close();
      } else this.splash.show();
    },
    version: '1.2.1', stats: { totalCubeClicks: 0 }, steamId: 'fixture',
    itemInHand: existingUI,
    pronounce(a, b) { return b; },
    getRealPrice(type) { return this.codex.entities[type].price; },
    canAfford(type) { return this.getRealPrice(type).every((amount, index) => !amount || this.resources[index] >= amount); },
    entityAtCoordinates(p) { return this.stuff.find((e) => e.position[0] === p[0] && e.position[1] === p[1]); },
    pickupItem(type) { this.itemInHand = { name: type, entitySpan: 0 }; },
    canEraseNow() { return this.hoveredEntity?.name !== 'cube' && this.stuff.length > 1 && this.resources[0] >= 1; },
    processClick() {
      const type = this.itemInHand.name;
      if (type === 'eraser') this.stuff.splice(this.stuff.indexOf(this.hoveredEntity), 1);
      else this.stuff.push({ name: type, position: [...this.hoveredCell], state: 0 });
      this.resources[0] -= this.getRealPrice(type)[0];
      this.hoveredCell = [99, 99]; // Simulate the game's cursor refresh.
    },
    saveGame() { this.saved = true; },
  };
  const forbidden = () => { throw new Error('Renderer clocks and timers must not pace interactions'); };
  const run = vm.runInNewContext(`(${dispatchSource})`, { game: g, localStorage: { getItem() { return 'encoded-fixture'; } },
    setTimeout: forbidRendererTime ? forbidden : setTimeout,
    setInterval: forbidden,
    performance: forbidRendererTime ? { now: forbidden } : performance,
    Date: forbidRendererTime ? { now: forbidden } : Date });
  return { g, run, existingUI, machine };
}

test('state returns optional audio diagnostics without changing the game or requiring an installed guard', async () => {
  const { g, run } = fixture();
  assert.equal((await run('state')).audio, null);
  const diagnostic = { mode: 'bounded', context: { currentTime: 12.5, state: 'running', sampleRate: 48000, baseLatency: 0.01 } };
  g.agentAudioStatus = () => diagnostic;
  assert.deepEqual(JSON.parse(JSON.stringify((await run('state')).audio)), diagnostic);
  assert.equal(g.itemInHand.name, 'unrelated-selection');
});

test('resume follows native menu closing/audio initialization once and never reopens a closed menu', async () => {
  const { g, run } = fixture();
  g.splash.isShown = true;
  assert.equal(g.actx, undefined);
  const first = await run('resume');
  assert.equal(first.menuShown, false);
  assert.equal(g.toggleSplashCalls, 1);
  assert.equal(g.audioInitCalls, 1);
  const context = g.actx;
  assert.ok(context);
  await run('resume');
  assert.equal(g.toggleSplashCalls, 1, 'repeated resume must not toggle the menu open');
  assert.equal(g.audioInitCalls, 1);
  g.toggleSplash(); // Open the menu using the game path, then resume again.
  assert.equal(g.splash.isShown, true);
  await run('resume');
  assert.equal(g.toggleSplashCalls, 3);
  assert.equal(g.splash.isShown, false);
  assert.equal(g.audioInitCalls, 1, 'an existing context must not be initialized again');
  assert.equal(g.actx, context);
  assert.equal(g.splash.gameIsMute, false);
});

test('resume preserves the native mute decision and does not bypass native initialization failures', async () => {
  const muted = fixture();
  muted.g.splash.isShown = true;
  muted.g.splash.gameIsMute = true;
  await muted.run('resume');
  assert.equal(muted.g.toggleSplashCalls, 1);
  assert.equal(muted.g.audioInitCalls, 0);
  assert.equal(muted.g.actx, undefined);
  assert.equal(muted.g.splash.gameIsMute, true);
  assert.equal(muted.g.splash.isShown, false);
  const failed = fixture();
  const error = new Error('native audio initialization failed');
  failed.g.splash.isShown = true;
  failed.g.initAudio = () => { throw error; };
  await assert.rejects(failed.run('resume'), thrown => thrown === error);
  assert.equal(failed.g.splash.isShown, true, 'native failure must not be concealed by directly closing splash');
});

test('catalog preserves native text and indexed current price while naming nonzero materials like state', async () => {
  const { g, run, existingUI } = fixture();
  const price = [0, 12, 0, 0, 0, 0, 0, 0, 0, 1.5];
  g.codex.entities.pump.price = price;
  g.pronounce = (group, type, field) => field === 'description' ? '<b>Native description</b>' : 'Native name';
  const before = await run('state');
  const catalog = await run('catalog');
  assert.equal(Array.isArray(catalog), true);
  const pump = catalog.find((item) => item.type === 'pump');
  assert.equal(pump.name, 'Native name');
  assert.equal(pump.description, '<b>Native description</b>');
  assert.deepEqual(Array.from(pump.price), price);
  assert.notEqual(pump.price, price);
  assert.deepEqual(JSON.parse(JSON.stringify(pump.materials)), [
    { index: 1, name: before.resources[1].name, amount: 12 },
    { index: 9, name: 'resource-9', amount: 1.5 },
  ]);
  assert.equal(before.resources[9].name, 'resource-9');
  const after = await run('state');
  for (const field of ['resources', 'entities', 'counts', 'stats']) {
    assert.deepEqual(JSON.parse(JSON.stringify(after[field])), JSON.parse(JSON.stringify(before[field])));
  }
  assert.equal(g.itemInHand, existingUI);
  assert.equal(pump.placementSupported, true);
  assert.equal(pump.available, true);
});

test('catalog follows current native price inflation and affordability without using base cost', async () => {
  const { g, run } = fixture();
  g.codex.entities.pump.price = [10, 0, 5];
  g.codex.entities.pump.priceExponent = 2;
  g.getRealPrice = function (type) {
    const item = this.codex.entities[type];
    const multiplier = item.priceExponent ? item.priceExponent ** (this.entitiesInGame[type] || 0) : 1;
    return multiplier === 1 ? item.price : item.price.map((amount) => amount * multiplier);
  };
  const current = async () => (await run('catalog')).find((item) => item.type === 'pump');
  const first = await current();
  assert.deepEqual(Array.from(first.price), [20, 0, 10]);
  assert.deepEqual(JSON.parse(JSON.stringify(first.materials)), [
    { index: 0, name: 'Charonite', amount: 20 },
    { index: 2, name: 'Qanetite', amount: 10 },
  ]);
  g.entitiesInGame.pump = 3;
  const inflated = await current();
  assert.deepEqual(Array.from(inflated.price), [80, 0, 40]);
  assert.equal(inflated.materials[1].amount, 40);
  assert.equal(inflated.affordable, true);
  g.resources[2] = 39;
  const unaffordable = await current();
  assert.equal(unaffordable.affordable, false);
  assert.equal(unaffordable.available, false);
  assert.deepEqual(Array.from(unaffordable.price), [80, 0, 40]);
  assert.deepEqual(Array.from(g.codex.entities.pump.price), [10, 0, 5]);
});

test('catalog marks erasers and classless tools unsupported consistently with place rejection', async () => {
  const { g, run } = fixture();
  for (const type of ['eraser', 'eraser2', 'eraser3']) {
    g.codex.entities[type] = { canPurchase: true, class: function () {}, price: [1] };
    g.unlockedEntities[type] = true;
  }
  g.codex.entities.classless = { canPurchase: true, price: [1] };
  g.unlockedEntities.classless = true;
  g.codex.entities.hidden = { canPurchase: false, class: function () {}, price: [1] };
  const catalog = await run('catalog');
  assert.equal(catalog.some((item) => item.type === 'hidden'), false);
  for (const type of ['eraser', 'eraser2', 'eraser3', 'classless']) {
    const item = catalog.find((entry) => entry.type === type);
    assert.equal(item.unlocked, true);
    assert.equal(item.affordable, true);
    assert.equal(item.placementSupported, false);
    assert.equal(item.available, false);
    await assert.rejects(run('place', { type, x: 1, y: 1 }), (error) => error.code === 'NOT_BUILDABLE');
  }
  assert.equal(g.stuff.length, 1);
  assert.equal(g.resources[0], 100);
});

test('placement calls normal game flow, charges actual price and restores selection', async () => {
  const { g, run, existingUI } = fixture();
  const result = await run('place', { type: 'pump', x: 2, y: 3 });
  assert.equal(result.placed.type, 'pump');
  assert.equal(g.resources[0], 75);
  assert.equal(g.itemInHand, existingUI);
  assert.equal(g.hoveredCell, undefined);
});

test('locked, occupied, unaffordable and invalid coordinate commands do not mutate world', async () => {
  const { g, run, existingUI } = fixture();
  await assert.rejects(run('place', { type: 'locked', x: 1, y: 1 }), (e) => e.code === 'LOCKED');
  await assert.rejects(run('place', { type: 'pump', x: 0, y: 0 }), (e) => e.code === 'OCCUPIED');
  await assert.rejects(run('place', { type: 'pump', x: NaN, y: 0 }), (e) => e.code === 'BAD_ARGUMENT');
  g.resources[0] = 0;
  await assert.rejects(run('place', { type: 'pump', x: 1, y: 1 }), (e) => e.code === 'INSUFFICIENT_RESOURCES');
  assert.equal(g.stuff.length, 1);
  assert.equal(g.resources[0], 0);
  assert.equal(g.itemInHand, existingUI);
});

test('last excavator stays protected and recyclable target uses eraser flow', async () => {
  const { g, run, existingUI } = fixture();
  await assert.rejects(run('remove', { x: 0, y: 0 }), (e) => e.code === 'CANNOT_REMOVE');
  assert.equal(g.itemInHand, existingUI);
  await run('place', { type: 'pump', x: 1, y: 1 });
  const result = await run('remove', { x: 1, y: 1 });
  assert.equal(result.removed.x, 1);
  assert.equal(g.stuff.length, 1);
  assert.equal(g.resources[0], 74);
});

test('public interaction only taps once and rejects renderer-timed holds and repeated clicks', async () => {
  const { g, run, machine, existingUI } = fixture({ forbidRendererTime: true });
  await assert.rejects(run('interact', { x: 0, y: 0, holdMs: 5001 }), (e) => e.code === 'BAD_ARGUMENT');
  await assert.rejects(run('interact', { x: 0, y: 0, holdMs: 35 }), (e) => e.code === 'BAD_ARGUMENT');
  await assert.rejects(run('interact', { x: 0, y: 0, count: 2 }), (e) => e.code === 'BAD_ARGUMENT');
  const result = await run('interact', { x: 0, y: 0 });
  assert.equal(result.performed, 1);
  assert.equal(machine.active, false);
  assert.equal(g.itemInHand, existingUI);
  assert.equal(g.hoveredEntity, undefined);
});

test('save export is opt-in and disabled saving is reported truthfully', async () => {
  const { g, run } = fixture();
  assert.equal((await run('save')).encodedSave, undefined);
  assert.equal((await run('save', { export: true })).encodedSave, 'encoded-fixture');
  g.preventCloud = true;
  await assert.rejects(run('save'), (e) => e.code === 'SAVE_DISABLED');
});

test('begin/end hold use no renderer time and pin native update despite cursor refreshes', async () => {
  const { g, run, machine, existingUI } = fixture({ forbidRendererTime: true });
  machine.spoolup = 0;
  const nativeUpdate = function () {
    if (g.hoveredEntity !== this) this.onmouseup();
    if (this.active) this.spoolup++;
  };
  const prototype = { update: nativeUpdate };
  Object.setPrototypeOf(machine, prototype);
  const begin = await run('beginInteraction', { x: 0, y: 0, id: 'hold-1', holdMs: 5000 });
  assert.equal(begin.before.active, false);
  assert.equal(begin.performed, 1);
  assert.equal(machine.active, true);
  assert.notEqual(machine.update, nativeUpdate);
  for (let i = 0; i < 4; i++) {
    g.hoveredEntity = undefined;
    machine.update();
  }
  const end = await run('endInteraction', { id: 'hold-1' });
  assert.equal(machine.spoolup, 4, 'each native pump tick must advance during the hold');
  assert.equal(end.after.spoolup, 4);
  assert.equal(end.holdMs, 5000);
  assert.equal(machine.active, false);
  assert.equal(machine.update, nativeUpdate);
  assert.equal(Object.hasOwn(machine, 'update'), false);
  assert.equal(g.itemInHand, existingUI);
  assert.equal(g.hoveredEntity, undefined);
});

test('tap honors canHit so an externally paced sequence stops once a cube breaks', async () => {
  const { g, run, machine } = fixture({ forbidRendererTime: true });
  machine.canHit = () => false;
  await assert.rejects(run('interact', { x: 0, y: 0 }), (e) => e.code === 'CANNOT_INTERACT');
  assert.equal(machine.active, false);
  machine.name = 'cube';
  machine.canHit = () => machine.state === 2;
  machine.onmousedown = () => { machine.state = 3; };
  const result = await run('interact', { x: 0, y: 0 });
  assert.equal(result.performed, 1);
  await assert.rejects(run('interact', { x: 0, y: 0 }), (e) => e.code === 'CANNOT_INTERACT');
  assert.equal(g.stats.totalCubeClicks, 1);
});

test('active hold is exclusive and cannot be ended by a different id', async () => {
  const { g, run, machine } = fixture({ forbidRendererTime: true });
  await run('beginInteraction', { x: 0, y: 0, id: 'owned', holdMs: 100 });
  for (const action of ['beginInteraction', 'interact', 'place', 'remove', 'resume']) {
    await assert.rejects(run(action, { x: 0, y: 0, id: 'other' }), (e) => e.code === 'INTERACTION_ACTIVE');
  }
  await assert.rejects(run('endInteraction', { id: 'other' }), (e) => e.code === 'INTERACTION_ID');
  assert.equal(machine.active, true);
  const ended = await run('endInteraction', { id: 'owned' });
  assert.equal(ended.released, true);
  assert.equal((await run('endInteraction', { id: 'owned' })).released, false);
  assert.equal(machine.active, false);
});

test('disconnect release restores an own update descriptor even after target removal or pause', async () => {
  const { g, run, machine, existingUI } = fixture({ forbidRendererTime: true });
  const nativeUpdate = function () {};
  Object.defineProperty(machine, 'update', { value: nativeUpdate, writable: false, configurable: true, enumerable: false });
  const descriptor = Object.getOwnPropertyDescriptor(machine, 'update');
  await run('beginInteraction', { x: 0, y: 0, id: 'disconnect', holdMs: 100 });
  g.stuff.splice(0, 1);
  g.halt = true;
  g.splash.isShown = true;
  const result = await run('releaseInteractions');
  assert.equal(result.after, null);
  assert.equal(machine.active, false);
  assert.deepEqual(Object.getOwnPropertyDescriptor(machine, 'update'), descriptor);
  assert.equal(g.itemInHand, existingUI);
  assert.equal((await run('releaseInteractions')).released, false);
});

test('press failure releases partially initialized hold, restores UI and preserves game error', async () => {
  const { g, run, machine, existingUI } = fixture({ forbidRendererTime: true });
  const originalUpdate = function () {};
  machine.update = originalUpdate;
  const gameError = new Error('native press failure');
  machine.onmousedown = () => { machine.active = true; throw gameError; };
  await assert.rejects(run('beginInteraction', { x: 0, y: 0, id: 'failed', holdMs: 100 }), (e) => e === gameError);
  assert.equal(machine.active, false);
  assert.equal(machine.update, originalUpdate);
  assert.equal(g.itemInHand, existingUI);
  assert.equal((await run('endInteraction', { id: 'failed' })).released, false);
});

test('mouseup failure still restores update/UI and clears active record', async () => {
  const { g, run, machine, existingUI } = fixture({ forbidRendererTime: true });
  const originalUpdate = function () {};
  machine.update = originalUpdate;
  await run('beginInteraction', { x: 0, y: 0, id: 'release-error', holdMs: 100 });
  const gameError = new Error('native release failure');
  machine.onmouseup = () => { throw gameError; };
  await assert.rejects(run('endInteraction', { id: 'release-error' }), (e) => e === gameError);
  assert.equal(machine.update, originalUpdate);
  assert.equal(g.itemInHand, existingUI);
  assert.equal((await run('releaseInteractions')).released, false);
});

test('native update failure cleans up hold and propagates instead of swallowing game errors', async () => {
  const { g, run, machine, existingUI } = fixture({ forbidRendererTime: true });
  const gameError = new Error('native update failure');
  const nativeUpdate = () => { throw gameError; };
  machine.update = nativeUpdate;
  await run('beginInteraction', { x: 0, y: 0, id: 'tick-error', holdMs: 100 });
  assert.throws(() => machine.update(), (e) => e === gameError);
  assert.equal(machine.active, false);
  assert.equal(machine.update, nativeUpdate);
  assert.equal(g.itemInHand, existingUI);
  assert.equal((await run('endInteraction', { id: 'tick-error' })).released, true);
});

test('opening menu during a native tick releases hold before executing normal update', async () => {
  const { g, run, machine, existingUI } = fixture({ forbidRendererTime: true });
  const observed = [];
  machine.update = function () { observed.push(this.active); };
  const original = machine.update;
  await run('beginInteraction', { x: 0, y: 0, id: 'menu', holdMs: 100 });
  g.splash.isShown = true;
  machine.update();
  assert.deepEqual(observed, [false]);
  assert.equal(machine.update, original);
  assert.equal(g.itemInHand, existingUI);
  await run('endInteraction', { id: 'menu' });
});

test('private repeat target id stays stable for one entity across separate dispatch calls', async () => {
  const { run, machine } = fixture({ forbidRendererTime: true });
  let presses = 0;
  machine.onmousedown = () => { presses++; };
  const first = await run('interact', { x: 0, y: 0 });
  assert.equal(typeof first.targetId, 'string');
  assert(first.targetId.length > 0);
  const second = await run('interact', { x: 0, y: 0, targetId: first.targetId });
  assert.equal(second.targetId, first.targetId);
  assert.equal(presses, 2);
});

test('same-type replacement at identical coordinates cannot inherit a repeat target token', async () => {
  const { g, run, machine, existingUI } = fixture({ forbidRendererTime: true });
  const first = await run('interact', { x: 0, y: 0 });
  let replacementPresses = 0;
  const replacement = { ...machine, onmousedown() { replacementPresses++; } };
  g.stuff[0] = replacement;
  await assert.rejects(run('interact', { x: 0, y: 0, targetId: first.targetId }), (e) => e.code === 'TARGET_CHANGED');
  assert.equal(replacementPresses, 0);
  assert.equal(g.itemInHand, existingUI);
  const fresh = await run('interact', { x: 0, y: 0 });
  assert.notEqual(fresh.targetId, first.targetId);
  assert.equal(replacementPresses, 1);
});

test('removed target returns TARGET_CHANGED for a continuation and NOT_FOUND for a new click', async () => {
  const { g, run } = fixture({ forbidRendererTime: true });
  const first = await run('interact', { x: 0, y: 0 });
  g.stuff.length = 0;
  await assert.rejects(run('interact', { x: 0, y: 0, targetId: first.targetId }), (e) => e.code === 'TARGET_CHANGED');
  await assert.rejects(run('interact', { x: 0, y: 0 }), (e) => e.code === 'NOT_FOUND');
});

test('invalid repeat tokens and tokens belonging to other cells never press a target', async () => {
  const { g, run, machine } = fixture({ forbidRendererTime: true });
  const first = await run('interact', { x: 0, y: 0 });
  let presses = 0;
  const other = { ...machine, position: [1, 0], onmousedown() { presses++; } };
  g.stuff.push(other);
  for (const targetId of [null, 4, {}, '', 'x'.repeat(129)]) {
    await assert.rejects(run('interact', { x: 1, y: 0, targetId }), (e) => e.code === 'BAD_ARGUMENT');
  }
  await assert.rejects(run('interact', { x: 1, y: 0, targetId: first.targetId }), (e) => e.code === 'TARGET_CHANGED');
  assert.equal(presses, 0);
});
