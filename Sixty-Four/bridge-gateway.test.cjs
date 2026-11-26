'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { EventEmitter } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { createGateway } = require('./bridge-gateway.cjs');

const token = 'gateway-test-token-not-installed';
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
};
class ManualClock {
  value = 0;
  next = 1;
  timers = new Map();
  now = () => this.value;
  timestamp = () => 1700000000000 + this.value;
  setTimeout = (callback, ms) => {
    const id = this.next++;
    this.timers.set(id, { when: this.value + ms, callback });
    return id;
  };
  clearTimeout = id => { this.timers.delete(id); };
  async advance(ms) {
    const end = this.value + ms;
    for (;;) {
      const next = [...this.timers].filter(([, timer]) => timer.when <= end).sort((a, b) => a[1].when - b[1].when)[0];
      if (!next) break;
      this.value = next[1].when;
      this.timers.delete(next[0]);
      next[1].callback();
      for (let iteration = 0; iteration < 10; iteration++) await Promise.resolve();
    }
    this.value = end;
    for (let iteration = 0; iteration < 10; iteration++) await Promise.resolve();
  }
}
async function setup(t, invoke = async (action, args) => ({ ok: true, data: { action, args } }), options = {}) {
  const calls = [];
  const gateway = createGateway({ config: { token, url: 'http://127.0.0.1:0', port: 0 }, invoke: (action, args) => { calls.push({ action, args }); return invoke(action, args); }, ...options });
  const address = await gateway.listen();
  t.after(() => gateway.close());
  const url = `http://127.0.0.1:${address.port}`;
  const request = async (route, options = {}) => {
    const response = await fetch(url + route, { ...options, headers: { authorization: `Bearer ${token}`, ...options.headers } });
    return { status: response.status, body: await response.json(), headers: response.headers };
  };
  const action = (name, args = {}) => request('/actions', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ action: name, args }) });
  const pending = async count => {
    for (let attempt = 0; attempt < 100; attempt++) {
      if ((await request('/health')).body.pending === count) return;
      await delay(2);
    }
    assert.fail(`Gateway did not reach pending=${count}`);
  };
  return { gateway, url, request, action, calls, pending };
}

test('real HTTP authentication, origin protection, envelopes and external health', async t => {
  const b = await setup(t);
  const health = await b.request('/health', { headers: { authorization: '' } });
  assert.equal(health.status, 200);
  assert.equal(health.body.pid, process.pid);
  assert.equal(health.body.clock, 'wall');
  assert.equal(JSON.stringify(health.body).includes(token), false);
  for (const authorization of ['', 'Basic nope', `Bearer ${'x'.repeat(token.length)}`]) {
    assert.equal((await b.request('/state', { headers: { authorization } })).status, 401);
  }
  for (const origin of ['https://example.invalid', 'null']) {
    assert.equal((await b.request('/health', { headers: { origin } })).status, 403);
    assert.equal((await b.request('/state', { headers: { origin } })).status, 403);
  }
  assert.equal(b.calls.length, 0);
  const state = await b.request('/state');
  assert.equal(state.status, 200);
  assert.deepEqual(state.body.data, { action: 'state', args: {} });
  assert.equal(state.body.meta.clock, 'wall');
  assert.equal(typeof state.body.meta.wallTimestamp, 'number');
  assert.ok(state.body.meta.wallDurationMs >= 0);
  assert.equal(state.headers.get('cache-control'), 'no-store');
});

test('payload bounds, content type, action whitelist and private fields are enforced before IPC', async t => {
  const b = await setup(t);
  const post = (body, contentType = 'application/json') => b.request('/actions', { method: 'POST', headers: { 'content-type': contentType }, body });
  assert.equal((await post('{broken')).status, 400);
  assert.equal((await post('{"action":"save"}', 'text/plain')).status, 415);
  assert.equal((await post(JSON.stringify({ action: 'save', args: { text: 'x'.repeat(9000) } }))).status, 413);
  for (const action of ['eval', 'beginInteraction', 'endInteraction', 'releaseInteractions', '__proto__']) assert.equal((await b.action(action)).status, 400);
  for (const args of [null, [], { _id: 'private' }, { _holdActive: true }]) {
    assert.equal((await post(JSON.stringify({ action: 'save', args }))).status, 400);
  }
  for (const args of [{ holdMs: 5001 }, { count: 65 }, { holdMs: 5, count: 2 }]) assert.equal((await b.action('interact', args)).status, 400);
  assert.equal(b.calls.length, 0);
  await b.action('save', { export: true, id: 'untrusted', holdMs: 99999999, code: 'arbitrary' });
  assert.deepEqual(b.calls[0], { action: 'save', args: { export: true } });
});

test('hold duration stays exactly wall1000ms across game1000x acceleration and clock rollback', async t => {
  const clock = new ManualClock();
  let gameTime = 100;
  const events = [];
  const begin = deferred();
  const b = await setup(t, async (action, args) => {
    events.push({ action, wall: clock.now(), game: gameTime, args });
    if (action === 'beginInteraction') { begin.resolve(); return { ok: true, data: { before: { state: 'up' }, performed: 1 } }; }
    if (action === 'endInteraction') return { ok: true, data: { after: { state: 'up' } } };
    throw new Error(`Unexpected operation ${action}`);
  }, { clock });
  const result = b.action('interact', { x: 3, y: -2, holdMs: 1000 });
  await begin.promise;
  for (let i = 0; i < 10; i++) await Promise.resolve();
  gameTime += 999000; // Simulate 1000x game time; no gateway time changes.
  await clock.advance(999);
  assert.equal(events.length, 1);
  gameTime = -999999999; // A game-clock rollback cannot prolong this hold.
  await clock.advance(1);
  const response = await result;
  assert.equal(response.status, 200);
  assert.deepEqual(events.map(event => [event.action, event.wall]), [['beginInteraction', 0], ['endInteraction', 1000]]);
  assert.equal(events[0].args.id, events[1].args.id);
  assert.deepEqual(response.body.data, {
    before: { state: 'up' }, after: { state: 'up' }, performed: 1, holdMs: 1000,
    timing: { clock: 'wall', requestedHoldMs: 1000, holdWaitMs: 1000, beginRoundTripMs: 0, endRoundTripMs: 0 },
  });
  assert.equal(response.body.meta.wallDurationMs, 1000);
});

test('hold timing separates the wall1000ms wait from slow begin and end game IPC', async t => {
  const clock = new ManualClock();
  const beginCalled = deferred();
  const beginReply = deferred();
  const endCalled = deferred();
  const endReply = deferred();
  const b = await setup(t, async action => {
    if (action === 'beginInteraction') { beginCalled.resolve(); await beginReply.promise; return { ok: true, data: { before: { active: false }, performed: 1 } }; }
    if (action === 'endInteraction') { endCalled.resolve(); await endReply.promise; return { ok: true, data: { after: { active: false } } }; }
    throw new Error(`Unexpected operation ${action}`);
  }, { clock });
  const result = b.action('interact', { x: 1, y: 2, holdMs: 1000 });
  await beginCalled.promise;
  await clock.advance(250); // Delayed acknowledgement from the game.
  beginReply.resolve();
  for (let i = 0; i < 10; i++) await Promise.resolve();
  await clock.advance(999);
  assert.equal(b.calls.length, 1);
  await clock.advance(1);
  await endCalled.promise;
  await clock.advance(600); // Release RPC is also delayed by the busy game.
  endReply.resolve();
  const response = await result;
  assert.equal(response.status, 200);
  assert.equal(response.body.meta.wallDurationMs, 1850);
  assert.deepEqual(response.body.data.timing, {
    clock: 'wall', requestedHoldMs: 1000, holdWaitMs: 1000,
    beginRoundTripMs: 250, endRoundTripMs: 600,
  });
  assert.equal(response.body.data.after.active, false);
});

test('repeated clicks use external30ms pacing and never forward renderer timers', async t => {
  const clock = new ManualClock();
  const times = [];
  const first = deferred();
  const b = await setup(t, async (action, args) => {
    assert.equal(action, 'interact');
    assert.deepEqual(args, { x: 1, y: 2, count: 1, holdMs: 0, ...(times.length ? { targetId: 'bound-original-target' } : {}) });
    times.push(clock.now());
    first.resolve();
    return { ok: true, data: { before: { n: times.length - 1 }, after: { n: times.length }, performed: 1, targetId: 'bound-original-target' } };
  }, { clock });
  const result = b.action('interact', { x: 1, y: 2, count: 3 });
  await first.promise;
  for (let i = 0; i < 10; i++) await Promise.resolve();
  await clock.advance(29);
  assert.deepEqual(times, [0]);
  await clock.advance(1);
  assert.deepEqual(times, [0, 30]);
  await clock.advance(30);
  const response = await result;
  assert.deepEqual(times, [0, 30, 60]);
  assert.equal(response.body.data.performed, 3);
  assert.equal(Object.hasOwn(response.body.data, 'targetId'), false);
});

test('target removal or loss of interactability between ticks retains successful clicks', async t => {
  for (const code of ['NOT_FOUND', 'CANNOT_INTERACT', 'TARGET_CHANGED']) {
    const clock = new ManualClock();
    const first = deferred();
    let number = 0;
    const b = await setup(t, async (action, args) => {
      number++;
      if (number === 1) {
        first.resolve();
        return { ok: true, data: { before: { canInteract: true, state: 0 }, after: { canInteract: true, state: 1 }, performed: 1, targetId: 'original-entity' } };
      }
      assert.equal(args.targetId, 'original-entity');
      return { ok: false, error: { code, message: 'Target changed between clicks' } };
    }, { clock });
    const result = b.action('interact', { x: 1, y: 2, count: 64 });
    await first.promise;
    for (let iteration = 0; iteration < 10; iteration++) await Promise.resolve();
    await clock.advance(30);
    const response = await result;
    assert.equal(response.status, 200);
    assert.equal(response.body.data.performed, 1);
    assert.deepEqual(response.body.data.before, { canInteract: true, state: 0 });
    assert.deepEqual(response.body.data.after, code === 'CANNOT_INTERACT' ? { canInteract: false, state: 1 } : null);
    assert.equal(Object.hasOwn(response.body.data, 'targetId'), false);
    assert.equal(number, 2, 'Stop after the expected target transition');
  }
});

test('repeat sequence binds its original entity and never clicks a replacement at the same cell', async t => {
  const clock = new ManualClock();
  const clicked = [];
  const first = deferred();
  let target = { id: 'original', hits: 0 };
  const b = await setup(t, async (action, args) => {
    if (args.targetId && args.targetId !== target.id) return { ok: false, error: { code: 'TARGET_CHANGED', message: 'A different entity occupies this cell' } };
    target.hits++;
    clicked.push(target.id);
    first.resolve();
    return { ok: true, data: { before: { type: 'cube', canInteract: true }, after: { type: 'cube', canInteract: true }, performed: 1, targetId: target.id } };
  }, { clock });
  const result = b.action('interact', { x: 1, y: 2, count: 64, targetId: 'untrusted-public-value' });
  await first.promise;
  for (let iteration = 0; iteration < 10; iteration++) await Promise.resolve();
  const original = target;
  target = { id: 'same-type-replacement', hits: 0 };
  await clock.advance(30);
  const response = await result;
  assert.equal(response.status, 200);
  assert.equal(response.body.data.performed, 1);
  assert.equal(original.hits, 1);
  assert.equal(target.hits, 0);
  assert.deepEqual(clicked, ['original']);
  assert.equal(b.calls[0].args.targetId, undefined, 'Public target tokens must not reach the renderer');
  assert.equal(b.calls[1].args.targetId, 'original');
  assert.equal(Object.hasOwn(response.body.data, 'targetId'), false);
});

test('unexpected repeat failure remains an error and missing identity never permits an unbound second click', async t => {
  const clock = new ManualClock();
  const first = deferred();
  let number = 0;
  const b = await setup(t, async () => {
    if (++number === 1) {
      first.resolve();
      return { ok: true, data: { before: {}, after: { canInteract: true }, performed: 1, targetId: 'original' } };
    }
    return { ok: false, error: { code: 'GAME_ERROR', message: 'Unexpected native failure' } };
  }, { clock });
  const result = b.action('interact', { x: 1, y: 2, count: 3 });
  await first.promise;
  for (let iteration = 0; iteration < 10; iteration++) await Promise.resolve();
  await clock.advance(30);
  const response = await result;
  assert.equal(response.status, 409);
  assert.equal(response.body.error.code, 'GAME_ERROR');
  const oldAdapter = await setup(t, async () => ({ ok: true, data: { before: {}, after: { canInteract: true }, performed: 1 } }));
  const unbound = await oldAdapter.action('interact', { x: 1, y: 2, count: 3 });
  assert.equal(unbound.status, 409);
  assert.equal(unbound.body.error.code, 'INVALID_RESPONSE');
  assert.equal(oldAdapter.calls.length, 1);
});

test('repeated clicks retain partial success when the target disappears or becomes unavailable', async t => {
  for (const after of [null, { type: 'pump', x: 1, y: 2, canInteract: false }]) {
    const b = await setup(t, async () => ({ ok: true, data: {
      before: { type: 'pump', x: 1, y: 2, canInteract: true }, after, performed: 1,
    } }));
    const result = await b.action('interact', { x: 1, y: 2, count: 64 });
    assert.equal(result.status, 200);
    assert.equal(result.body.data.performed, 1);
    assert.deepEqual(result.body.data.after, after);
    assert.equal(b.calls.length, 1, 'Do not send a second click to a removed or unavailable target');
  }
});

test('a response closed during body reading cannot enqueue a mutation', async t => {
  const b = await setup(t);
  for (const closedProperty of ['destroyed', 'writableEnded']) {
    const request = new EventEmitter();
    Object.assign(request, {
      method: 'POST', url: '/actions',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      resume() {},
    });
    const response = new EventEmitter();
    Object.assign(response, {
      destroyed: false, writableEnded: false,
      writeHead() { assert.fail('A closed response must not receive headers'); },
      end() { assert.fail('A closed response must not be written'); },
    });
    // Deliver through the actual HTTP request handler, forcing the socket-close
    // event before readBody resolves and before enqueue can attach its listener.
    b.gateway.server.emit('request', request, response);
    request.emit('data', Buffer.from(JSON.stringify({ action: 'place', args: { type: 'pump', x: 0, y: 0 } })));
    response[closedProperty] = true;
    response.emit('close');
    request.emit('end');
    for (let iteration = 0; iteration < 10; iteration++) await Promise.resolve();
    assert.equal(b.calls.length, 0);
    assert.equal((await b.request('/health')).body.pending, 0);
  }
});

test('active timeout responds504 but blocks the queue; expired queued actions never execute', async t => {
  const clock = new ManualClock();
  const gate = deferred();
  const began = deferred();
  const b = await setup(t, async action => {
    if (action === 'save') { began.resolve(); await gate.promise; }
    return { ok: true, data: { action } };
  }, { clock, deadlineMs: 100 });
  const first = b.action('save');
  await began.promise;
  await clock.advance(10);
  const queued = b.action('place', { type: 'pump', x: 0, y: 0 });
  await b.pending(2);
  await clock.advance(90);
  assert.equal((await first).status, 504);
  assert.deepEqual(b.calls.map(call => call.action), ['save']);
  const health = await b.request('/health');
  assert.equal(health.status, 200);
  assert.equal(health.body.active, true);
  await clock.advance(10);
  assert.equal((await queued).status, 504);
  await b.pending(1);
  gate.resolve();
  await b.pending(0);
  assert.deepEqual(b.calls.map(call => call.action), ['save']);
  assert.equal((await b.action('resume')).status, 200);
});

test('late hold begin is released immediately and next action waits for release acknowledgement', async t => {
  const clock = new ManualClock();
  const beginGate = deferred();
  const endGate = deferred();
  const began = deferred();
  const ended = deferred();
  const b = await setup(t, async action => {
    if (action === 'beginInteraction') { began.resolve(); await beginGate.promise; return { ok: true, data: { performed: 1 } }; }
    if (action === 'endInteraction') { ended.resolve(); await endGate.promise; }
    return { ok: true, data: {} };
  }, { clock, deadlineMs: 100 });
  const hold = b.action('interact', { x: 0, y: 0, holdMs: 1000 });
  await began.promise;
  await clock.advance(1100);
  assert.equal((await hold).status, 504);
  const queued = b.action('save');
  await b.pending(2);
  beginGate.resolve();
  await ended.promise;
  assert.deepEqual(b.calls.map(call => call.action), ['beginInteraction', 'endInteraction']);
  // No extra1000ms sleep after the delayed begin, and release is still exclusive.
  assert.equal(clock.now(), 1100);
  endGate.resolve();
  assert.equal((await queued).status, 200);
  assert.deepEqual(b.calls.map(call => call.action), ['beginInteraction', 'endInteraction', 'save']);
});

test('disconnected queued client never executes its mutation', async t => {
  const gate = deferred();
  const began = deferred();
  const b = await setup(t, async action => {
    if (action === 'save') { began.resolve(); await gate.promise; }
    return { ok: true, data: {} };
  });
  const first = b.action('save');
  await began.promise;
  const disconnected = http.request(b.url + '/actions', { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' } });
  disconnected.on('error', () => {});
  disconnected.end(JSON.stringify({ action: 'place', args: { type: 'pump', x: 0, y: 0 } }));
  await b.pending(2);
  disconnected.destroy();
  await b.pending(1);
  gate.resolve();
  assert.equal((await first).status, 200);
  await b.pending(0);
  assert.deepEqual(b.calls.map(call => call.action), ['save']);
});

test('failed begin still triggers end cleanup and game errors retain their code', async t => {
  const b = await setup(t, async action => action === 'beginInteraction'
    ? { ok: false, error: { code: 'CANNOT_INTERACT', message: 'Protected target' } }
    : { ok: true, data: {} });
  const result = await b.action('interact', { x: 0, y: 0, holdMs: 1000 });
  assert.equal(result.status, 409);
  assert.equal(result.body.error.code, 'CANNOT_INTERACT');
  assert.deepEqual(b.calls.map(call => call.action), ['beginInteraction', 'endInteraction']);
});

test('disconnected active hold releases a late begin before the queue advances', { timeout: 5000 }, async t => {
  const beginGate = deferred();
  const endGate = deferred();
  const began = deferred();
  const ending = deferred();
  const b = await setup(t, async action => {
    if (action === 'beginInteraction') { began.resolve(); await beginGate.promise; }
    if (action === 'endInteraction') { ending.resolve(); await endGate.promise; }
    return { ok: true, data: {} };
  });
  const request = http.request(b.url + '/actions', { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' } });
  request.on('error', () => {});
  request.end(JSON.stringify({ action: 'interact', args: { x: 0, y: 0, holdMs: 5000 } }));
  await began.promise;
  request.destroy();
  await delay(10); // Let the OS report the closed client socket to the server.
  const queued = b.action('save');
  await b.pending(2);
  beginGate.resolve();
  await ending.promise;
  assert.deepEqual(b.calls.map(call => call.action), ['beginInteraction', 'endInteraction']);
  assert.equal((await b.request('/health')).body.pending, 2);
  endGate.resolve();
  assert.equal((await queued).status, 200);
  assert.deepEqual(b.calls.map(call => call.action), ['beginInteraction', 'endInteraction', 'save']);
});

test('queue cap16 and recovery do not dispatch excess requests', async t => {
  const gate = deferred();
  const b = await setup(t, async () => { await gate.promise; return { ok: true, data: {} }; });
  const requests = [];
  try {
    for (let count = 1; count <= 16; count++) { requests.push(b.action('save')); await b.pending(count); }
    const rejected = await b.action('save');
    assert.equal(rejected.status, 429);
    assert.equal(rejected.body.error.code, 'BUSY');
    assert.equal(b.calls.length, 1);
  } finally { gate.resolve(); }
  assert.ok((await Promise.all(requests)).every(result => result.status === 200));
  assert.equal((await b.action('save')).status, 200);
});

test('OpenAPI exposes only public actions and wall-clock bounded parameters', async t => {
  const b = await setup(t);
  const schema = (await b.request('/openapi.json')).body;
  assert.equal(schema.openapi, '3.1.0');
  assert.equal(schema.components.securitySchemes.bearerAuth.scheme, 'bearer');
  assert.deepEqual(schema.paths['/health'].get.security, []);
  const properties = schema.paths['/actions'].post.requestBody.content['application/json'].schema.properties;
  assert.deepEqual(properties.action.enum, ['place', 'interact', 'remove', 'save', 'resume']);
  assert.equal(properties.args.properties.holdMs.maximum, 5000);
  assert.equal(properties.args.properties.count.maximum, 64);
  assert.equal(b.calls.length, 0);
});
