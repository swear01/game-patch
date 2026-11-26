import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createClient, createClientFromConfig } from './client.mjs';

const json = (res, data = { ok: true }, status = 200) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(data));
};
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function fixture(t, handler, options = {}) {
  const requests = [];
  const sockets = new Set();
  const server = http.createServer((req, res) => {
    requests.push({ path: req.url, method: req.method, auth: req.headers.authorization, socket: req.socket });
    handler(req, res, requests);
  });
  server.on('connection', socket => sockets.add(socket));
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const url = `http://127.0.0.1:${server.address().port}`;
  const client = createClient({ url, token: 'fixture-secret', ...options });
  t.after(async () => { client.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  return { client, server, requests, sockets, url };
}

test('persistent client reuses a real TCP connection and maps all methods/auth/JSON', async t => {
  const bodies = [];
  const f = await fixture(t, (req, res) => {
    if (req.method !== 'POST') return json(res, { ok: true, data: req.url });
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => { bodies.push(JSON.parse(body)); json(res, { ok: true, data: bodies.at(-1) }); });
  });
  assert.deepEqual(await f.client.health(), { ok: true, data: '/health' });
  await f.client.state(); await f.client.catalog(); await f.client.openapi();
  for (const action of ['place', 'interact', 'remove', 'save', 'resume']) {
    assert.deepEqual(await f.client.act(action, { x: 1, y: -2 }), { ok: true, data: { action, args: { x: 1, y: -2 } } });
  }
  assert.equal(f.requests.length, 9);
  assert.equal(f.sockets.size, 1, 'sequential requests must reuse the same TCP connection');
  assert.equal(f.requests[0].auth, undefined);
  assert.ok(f.requests.slice(1).every(r => r.auth === 'Bearer fixture-secret'));
  assert.deepEqual(f.requests.map(r => [r.path, r.method]), [['/health', 'GET'], ['/state', 'GET'], ['/catalog', 'GET'], ['/openapi.json', 'GET'], ...Array.from({ length: 5 }, () => ['/actions', 'POST'])]);
});

test('route/method/action validation rejects locally without sending any request', async t => {
  const f = await fixture(t, (_req, res) => json(res));
  for (const [path, options] of [
    ['http://elsewhere.invalid/state', {}], ['//elsewhere.invalid/state', {}], ['/unknown', {}],
    ['/state?x=1', {}], ['/state', { method: 'POST' }], ['/actions', {}],
    ['/state', { body: {} }], ['/actions', { method: 'POST', body: { action: 'eval', args: {} } }],
    ['/actions', { method: 'POST', body: { action: 'save', args: [] } }], ['/health', { timeoutMs: 0 }],
  ]) await assert.rejects(f.client.request(path, options), { code: 'INVALID_ARGUMENT' });
  await assert.rejects(f.client.act('eval'), { code: 'INVALID_ARGUMENT' });
  assert.equal(f.requests.length, 0);
});

test('config/env precedence, absent config and per-request token checks do not expose secrets', async t => {
  const f = await fixture(t, (_req, res) => json(res));
  const dir = await mkdtemp(join(tmpdir(), 'sixtyfour-client-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const configPath = join(dir, 'bridge-config.json');
  await writeFile(configPath, JSON.stringify({ url: 'http://wrong.invalid', token: 'wrong-token' }));
  const client = await createClientFromConfig({ configPath, env: { SIXTYFOUR_API_URL: f.url, SIXTYFOUR_API_TOKEN: 'env-secret' } });
  t.after(() => client.close());
  await client.state();
  assert.equal(f.requests[0].auth, 'Bearer env-secret');
  const noToken = await createClientFromConfig({ configPath: join(dir, 'absent.json'), env: { SIXTYFOUR_API_URL: f.url } });
  t.after(() => noToken.close());
  await noToken.health();
  await assert.rejects(noToken.state(), { code: 'CONFIG_ERROR' });
  await writeFile(configPath, '{"token":"secret-in-broken-json"');
  await assert.rejects(createClientFromConfig({ configPath, env: {} }), e => e.code === 'CONFIG_ERROR' && !e.message.includes('secret-in-broken-json'));
  assert.throws(() => createClient({ url: 'http://user:secret-password@localhost' }), e => e.code === 'CONFIG_ERROR' && !e.message.includes('secret-password'));
  assert.throws(() => createClient({ token: 'secret-token\r\n' }), e => e.code === 'CONFIG_ERROR' && !e.message.includes('secret-token'));
});

test('HTTP errors retain the API envelope and status', async t => {
  const envelope = { ok: false, error: { code: 'BUSY', message: 'Queue full' }, meta: { clock: 'wall' } };
  const f = await fixture(t, (_req, res) => json(res, envelope, 429));
  await assert.rejects(f.client.state(), e => e.code === 'HTTP_ERROR' && e.status === 429 && assert.deepEqual(e.apiResponse, envelope) === undefined);
});

test('successful malformed JSON and non-JSON content are INVALID_RESPONSE', async t => {
  let index = 0;
  const f = await fixture(t, (_req, res) => {
    res.writeHead(200, { 'content-type': index++ === 0 ? 'application/json' : 'text/plain' });
    res.end(index === 1 ? '{broken' : '{"ok":true}');
  });
  await assert.rejects(f.client.state(), { code: 'INVALID_RESPONSE', status: 200 });
  await assert.rejects(f.client.state(), { code: 'INVALID_RESPONSE', status: 200 });
});

test('redirects are returned as errors and never forward bearer tokens', async t => {
  let destinationHits = 0;
  const destination = await fixture(t, (_req, res) => { destinationHits++; json(res); });
  const source = await fixture(t, (_req, res) => {
    res.writeHead(302, { location: `${destination.url}/state`, 'content-type': 'application/json' });
    res.end('{"redirected":true}');
  });
  await assert.rejects(source.client.state(), e => e.status === 302 && e.apiResponse.redirected === true);
  assert.equal(destinationHits, 0);
});

test('responses over 8 MiB are rejected with or without Content-Length', async t => {
  let index = 0;
  const f = await fixture(t, (_req, res) => {
    res.on('error', () => {});
    if (index++ === 0) {
      res.writeHead(200, { 'content-type': 'application/json', 'content-length': 8 * 1024 * 1024 + 1 });
      res.flushHeaders();
    } else {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(' '.repeat(8 * 1024 * 1024 + 1));
    }
  });
  await assert.rejects(f.client.state(), { code: 'RESPONSE_TOO_LARGE' });
  await assert.rejects(f.client.state(), { code: 'RESPONSE_TOO_LARGE' });
});

test('JSON save exports above 1 MiB are accepted and interrupted bodies reject', async t => {
  const exported = 'x'.repeat(1024 * 1024 + 256);
  let index = 0;
  const f = await fixture(t, (_req, res) => {
    if (index++ === 0) return json(res, { ok: true, data: { save: exported } });
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': 100 });
    res.write('{"ok":');
    setTimeout(() => res.destroy(), 10);
  });
  assert.equal((await f.client.act('save', { export: true })).data.save, exported);
  await assert.rejects(f.client.state(), { code: 'CONNECTION_ERROR' });
});

test('one wall-clock deadline covers slow headers and a trickling response body', async t => {
  let index = 0;
  const f = await fixture(t, (_req, res) => {
    if (index++ === 0) return;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.write('{"ok":');
    const timer = setInterval(() => res.write(' '), 10);
    res.on('close', () => clearInterval(timer));
  });
  const started = performance.now();
  await assert.rejects(f.client.request('/state', { timeoutMs: 70 }), { code: 'TIMEOUT' });
  await assert.rejects(f.client.request('/state', { timeoutMs: 70 }), { code: 'TIMEOUT' });
  assert.ok(performance.now() - started < 1000, 'body traffic must not reset the deadline');
});

test('act adds a validated hold duration to its base deadline', async t => {
  const f = await fixture(t, (_req, res) => {
    const timer = setTimeout(() => json(res, { ok: true, data: { performed: 1 } }), 160);
    res.on('close', () => clearTimeout(timer));
  }, { timeoutMs: 80 });
  assert.deepEqual(await f.client.act('interact', { x: 1, y: 2, holdMs: 160 }), { ok: true, data: { performed: 1 } });
  for (const holdMs of [-1, 5001, 1.5, '5000', Infinity]) {
    await assert.rejects(f.client.act('interact', { x: 1, y: 2, holdMs }), { code: 'INVALID_ARGUMENT' });
  }
  assert.equal(f.requests.length, 1, 'invalid holds must not be sent or create unbounded deadlines');
  await assert.rejects(f.client.act('save'), { code: 'TIMEOUT' });
});

test('a request that expires in the Agent socket queue never reaches the server later', async t => {
  let release;
  let started;
  const firstSeen = new Promise(resolve => { started = resolve; });
  const f = await fixture(t, (_req, res) => { release = () => json(res); started(); }, { maxSockets: 1 });
  const first = f.client.request('/state', { timeoutMs: 1000 });
  await firstSeen;
  await assert.rejects(f.client.request('/actions', { method: 'POST', body: { action: 'remove', args: { x: 1, y: 2 } }, timeoutMs: 50 }), { code: 'TIMEOUT' });
  release();
  await first;
  await delay(60);
  assert.equal(f.requests.length, 1, 'expired queued mutation must not be sent after a socket is free');
});

test('a mutation with a dropped response is sent once and is never retried', async t => {
  let mutations = 0;
  const f = await fixture(t, (req, _res) => {
    req.resume();
    req.on('end', () => { mutations++; req.socket.destroy(); });
  });
  await assert.rejects(f.client.act('place', { type: 'machine', x: 1, y: 2 }), { code: 'CONNECTION_ERROR' });
  await delay(30);
  assert.equal(mutations, 1);
});

test('close rejects active and socket-queued work, is idempotent, and prevents future requests', async t => {
  let notify;
  const seen = new Promise(resolve => { notify = resolve; });
  const f = await fixture(t, () => notify(), { maxSockets: 1 });
  const active = f.client.state();
  await seen;
  const queued = f.client.catalog();
  const checks = [assert.rejects(active, { code: 'CLIENT_CLOSED' }), assert.rejects(queued, { code: 'CLIENT_CLOSED' })];
  f.client.close(); f.client.close();
  await Promise.all(checks);
  await assert.rejects(f.client.health(), { code: 'CLIENT_CLOSED' });
  assert.equal(f.requests.length, 1);
});
