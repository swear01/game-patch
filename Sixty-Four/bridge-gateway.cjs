'use strict';
// This module runs in standalone Node, outside every accelerated game process.
const http = require('node:http');
const crypto = require('node:crypto');

const actions = new Set(['place', 'interact', 'remove', 'save', 'resume']);
const wallClock = {
  now: () => Number(process.hrtime.bigint()) / 1e6,
  timestamp: () => Date.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: timer => clearTimeout(timer),
};
const errorResult = (code, message) => ({ ok: false, error: { code, message } });

function createGateway({ config, invoke, clock = wallClock, deadlineMs = 8000, speedStatus = () => null }) {
  if (typeof invoke !== 'function') throw new Error('A game IPC transport is required');
  if (typeof config?.token !== 'string' || !config.token) throw new Error('A bearer token is required');
  const queue = [];
  let active = null;
  let closed = false;
  let pending = 0;

  function send(res, status, body, started = clock.now()) {
    if (res.destroyed || res.writableEnded) return;
    const result = { ...body, meta: { clock: 'wall', wallTimestamp: clock.timestamp(), wallDurationMs: Math.max(0, clock.now() - started) } };
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    res.end(JSON.stringify(result));
  }
  function authorized(req) {
    const actual = Buffer.from(req.headers.authorization || '');
    const expected = Buffer.from(`Bearer ${config.token}`);
    return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
  }
  const alive = job => !closed && !job.expired && !job.cancelled;
  function wake(job) { for (const callback of [...job.waiters]) callback(); }
  function expire(job) {
    if (!alive(job)) return;
    job.expired = true;
    send(job.res, 504, errorResult('DEADLINE_EXCEEDED', 'Game operation exceeded its wall-clock deadline; an active operation may still be settling'), job.started);
    wake(job);
    if (active !== job) removeQueued(job);
  }
  function checkAlive(job) {
    if (alive(job) && clock.now() >= job.deadlineAt) expire(job);
    return alive(job);
  }
  function wait(job, ms) {
    if (!checkAlive(job)) return Promise.resolve();
    return new Promise(resolve => {
      let timer;
      const finish = () => { clock.clearTimeout(timer); job.waiters.delete(finish); resolve(); };
      timer = clock.setTimeout(finish, ms);
      job.waiters.add(finish);
    });
  }
  function cleanArgs(action, args) {
    if (action === 'place') return { type: args.type, x: args.x, y: args.y };
    if (action === 'remove') return { x: args.x, y: args.y };
    if (action === 'save') return args.export === true ? { export: true } : {};
    return {};
  }
  async function run(job) {
    if (!checkAlive(job)) return errorResult('CANCELLED', 'Request no longer active');
    if (job.action !== 'interact') return invoke(job.action, cleanArgs(job.action, job.args));
    const { x, y } = job.args;
    const duration = job.args.holdMs ?? 0;
    const count = job.args.count ?? 1;
    if (duration > 0) {
      const id = crypto.randomUUID();
      let begin;
      let end;
      const beginStarted = clock.now();
      let beginRoundTripMs = 0;
      let endRoundTripMs = 0;
      let holdWaitMs = 0;
      try {
        begin = await invoke('beginInteraction', { x, y, id, holdMs: duration });
        beginRoundTripMs = Math.max(0, clock.now() - beginStarted);
        if (begin?.ok && checkAlive(job)) {
          const waitStarted = clock.now();
          await wait(job, duration);
          holdWaitMs = Math.max(0, clock.now() - waitStarted);
        }
      } finally {
        // Even a late/failed begin must be paired with cleanup before the next action.
        const endStarted = clock.now();
        try { end = await invoke('endInteraction', { id }); }
        finally { endRoundTripMs = Math.max(0, clock.now() - endStarted); }
      }
      if (!begin?.ok) return begin;
      if (!end?.ok) return end;
      return { ok: true, data: {
        before: begin.data?.before, after: end.data?.after ?? null, performed: begin.data?.performed ?? 1, holdMs: duration,
        timing: { clock: 'wall', requestedHoldMs: duration, holdWaitMs, beginRoundTripMs, endRoundTripMs },
      } };
    }
    let first;
    let last;
    let performed = 0;
    let targetId;
    for (let index = 0; index < count && checkAlive(job); index++) {
      const nativeArgs = { x, y, count: 1, holdMs: 0 };
      if (targetId !== undefined) nativeArgs.targetId = targetId;
      const result = await invoke('interact', nativeArgs);
      if (!result?.ok) {
        if (performed > 0 && ['NOT_FOUND', 'CANNOT_INTERACT', 'TARGET_CHANGED'].includes(result?.error?.code)) {
          if (result.error.code === 'CANNOT_INTERACT' && last) last = { ...last, canInteract: false };
          else last = null;
          break;
        }
        return result;
      }
      first ??= result.data?.before;
      last = result.data?.after ?? null;
      performed += result.data?.performed ?? 1;
      if (targetId === undefined) targetId = result.data?.targetId;
      // Native repeated interaction stops successfully when its target is gone
      // or becomes unavailable, retaining every click already performed.
      if (last === null || last.canInteract === false) break;
      if (index + 1 < count && checkAlive(job)) {
        if (typeof targetId !== 'string' || !targetId) return errorResult('INVALID_RESPONSE', 'The game did not provide an identity for repeated interaction');
        await wait(job, 30);
      }
    }
    return { ok: true, data: { before: first, after: last, performed, holdMs: 0 } };
  }
  function removeQueued(job) {
    const index = queue.indexOf(job);
    if (index !== -1) { queue.splice(index, 1); pending--; clock.clearTimeout(job.timer); }
  }
  async function pump() {
    if (active || closed) return;
    const job = queue.shift();
    if (!job) return;
    active = job;
    try {
      const result = await run(job);
      if (checkAlive(job)) send(job.res, result?.ok === false ? 409 : 200, result, job.started);
    } catch (error) {
      if (checkAlive(job)) send(job.res, 503, errorResult(error.code || 'BRIDGE_ERROR', error.message), job.started);
    } finally {
      clock.clearTimeout(job.timer);
      pending--;
      active = null;
      // Expiration sends a response, but never releases this gate before the
      // original RPC and every hold cleanup have actually settled.
      void pump();
    }
  }
  function enqueue(res, action, args, started) {
    // The socket may close while readBody awaits its final chunk, before the
    // per-job close listener below exists. Such requests must never mutate play.
    if (res.destroyed || res.writableEnded) return;
    if (closed) return send(res, 503, errorResult('DISCONNECTED', 'Game gateway is closing'), started);
    if (pending >= 16) return send(res, 429, errorResult('BUSY', 'Action queue is full'), started);
    const deadlineAt = started + deadlineMs + (action === 'interact' ? (args.holdMs || 0) : 0);
    if (clock.now() >= deadlineAt) return send(res, 504, errorResult('DEADLINE_EXCEEDED', 'Request deadline elapsed before the operation could start'), started);
    const job = { res, action, args, started, deadlineAt, expired: false, cancelled: false, waiters: new Set() };
    pending++;
    queue.push(job);
    job.timer = clock.setTimeout(() => expire(job), Math.max(0, deadlineAt - clock.now()));
    res.once('close', () => {
      if (res.writableEnded) return;
      job.cancelled = true;
      wake(job);
      if (active !== job) removeQueued(job);
    });
    void pump();
  }
  function readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      let rejected = false;
      req.on('data', chunk => {
        if (rejected) return;
        size += chunk.length;
        if (size > 8192) {
          rejected = true;
          reject(Object.assign(new Error('Body exceeds 8192 bytes'), { code: 'TOO_LARGE' }));
          req.resume();
        } else chunks.push(chunk);
      });
      req.on('end', () => {
        if (rejected) return;
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch { reject(Object.assign(new Error('Expected a JSON body'), { code: 'BAD_REQUEST' })); }
      });
      req.on('error', reject);
    });
  }
  function openapi() {
    const responses = { '200': { description: 'JSON result with wall-clock metadata' }, '409': { description: 'Game rule rejected the action' }, '429': { description: 'Queue full' }, '504': { description: 'Wall-clock deadline exceeded (DEADLINE_EXCEEDED); the operation may still be settling' } };
    return { openapi: '3.1.0', info: { title: 'Sixty Four Agent API', version: '2.0.0' }, servers: [{ url: config.url }], security: [{ bearerAuth: [] }], components: { securitySchemes: { bearerAuth: { type: 'http', scheme: 'bearer' } } }, paths: {
      '/health': { get: { operationId: 'health', security: [], responses } },
      '/state': { get: { operationId: 'state', responses } },
      '/catalog': { get: { operationId: 'catalog', responses } },
      '/actions': { post: { operationId: 'act', requestBody: { required: true, content: { 'application/json': { schema: { type: 'object', required: ['action'], properties: { action: { enum: [...actions] }, args: { type: 'object', properties: { type: { type: 'string' }, x: { type: 'integer' }, y: { type: 'integer' }, holdMs: { type: 'integer', minimum: 0, maximum: 5000 }, count: { type: 'integer', minimum: 1, maximum: 64 }, export: { type: 'boolean' } } } } } } } }, responses } },
    } };
  }
  const server = http.createServer(async (req, res) => {
    const started = clock.now();
    try {
      if (req.headers.origin) return send(res, 403, errorResult('ORIGIN_DENIED', 'Browser origins are not supported'), started);
      if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true, service: 'sixtyfour-agent', version: '2.0.0', pid: process.pid, clock: 'wall', pending, active: Boolean(active), speedControl: speedStatus() }, started);
      if (!authorized(req)) return send(res, 401, errorResult('UNAUTHORIZED', 'Bearer authentication required'), started);
      if (req.method === 'GET' && req.url === '/openapi.json') {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
        return res.end(JSON.stringify(openapi()));
      }
      if (req.method === 'GET' && ['/state', '/catalog'].includes(req.url)) return enqueue(res, req.url.slice(1), {}, started);
      if (req.method !== 'POST' || req.url !== '/actions') return send(res, 404, errorResult('NOT_FOUND', 'Unknown endpoint'), started);
      if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] || '')) return send(res, 415, errorResult('CONTENT_TYPE', 'Use application/json'), started);
      const body = await readBody(req);
      if (!body || typeof body !== 'object' || !actions.has(body.action) || (body.args !== undefined && (!body.args || typeof body.args !== 'object' || Array.isArray(body.args)))) {
        return send(res, 400, errorResult('BAD_REQUEST', 'Unknown action or invalid args'), started);
      }
      const args = body.args || {};
      if (Object.keys(args).some(key => key.startsWith('_'))) return send(res, 400, errorResult('BAD_REQUEST', 'Private argument fields are not supported'), started);
      if (body.action === 'interact') {
        const duration = args.holdMs ?? 0;
        const count = args.count ?? 1;
        if (!Number.isInteger(duration) || duration < 0 || duration > 5000 || !Number.isInteger(count) || count < 1 || count > 64 || (duration && count !== 1)) {
          return send(res, 400, errorResult('BAD_ARGUMENT', 'holdMs must be 0–5000 and count 1–64; a hold must use count 1'), started);
        }
      }
      enqueue(res, body.action, args, started);
    } catch (error) {
      send(res, error.code === 'TOO_LARGE' ? 413 : error.code === 'BAD_REQUEST' ? 400 : 503, errorResult(error.code || 'BRIDGE_ERROR', error.message), started);
    }
  });
  server.requestTimeout = 10000;
  server.headersTimeout = 10000;
  return {
    server,
    listen: () => new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(config.port, '127.0.0.1', () => { server.removeListener('error', reject); resolve(server.address()); });
    }),
    close: () => {
      closed = true;
      for (const job of [...queue]) {
        job.cancelled = true;
        wake(job);
        send(job.res, 503, errorResult('DISCONNECTED', 'Game connection closed'), job.started);
        removeQueued(job);
      }
      if (active) { active.cancelled = true; wake(active); clock.clearTimeout(active.timer); }
      server.closeAllConnections();
      return new Promise(resolve => server.close(resolve));
    },
  };
}

module.exports = { createGateway };

if (require.main === module) {
  if (process.versions.electron || Number(process.versions.node.split('.')[0]) < 24 || typeof process.send !== 'function' || !process.connected) {
    console.error('The gateway requires standalone Node.js24+ and its game IPC parent.');
    process.exit(1);
  }
  const fs = require('node:fs');
  const path = require('node:path');
  const config = JSON.parse(fs.readFileSync(path.join(__dirname, 'bridge-config.json'), 'utf8'));
  let nextId = 1;
  const calls = new Map();
  const invoke = (action, args) => new Promise((resolve, reject) => {
    if (!process.connected) return reject(Object.assign(new Error('Game IPC disconnected'), { code: 'DISCONNECTED' }));
    const id = nextId++;
    calls.set(id, { resolve, reject });
    process.send({ id, action, args }, error => {
      if (error && calls.has(id)) { calls.delete(id); reject(error); }
    });
  });
  let speedControl;
  const gateway = createGateway({ config, invoke, speedStatus: () => speedControl?.getStatus?.() ?? null });
  speedControl = config.speedControl?.enabled
    ? require('./speed-control.cjs').startSpeedControl({ config, invoke, report: message => console.error(message) }) : null;
  process.on('message', message => {
    if (!message || !Number.isSafeInteger(message.id) || !calls.has(message.id)) return;
    const call = calls.get(message.id);
    calls.delete(message.id);
    call.resolve(message.result);
  });
  process.once('disconnect', () => {
    speedControl?.close();
    for (const call of calls.values()) call.reject(Object.assign(new Error('Game IPC disconnected'), { code: 'DISCONNECTED' }));
    calls.clear();
    void gateway.close().finally(() => process.exit(0));
  });
  gateway.listen().catch(error => { console.error(error.message); process.exit(1); });
}
