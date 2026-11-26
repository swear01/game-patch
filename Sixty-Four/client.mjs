import http from 'node:http';
import https from 'node:https';
import { readFile } from 'node:fs/promises';

const routes = new Map([
  ['/health', 'GET'], ['/state', 'GET'], ['/catalog', 'GET'],
  ['/openapi.json', 'GET'], ['/actions', 'POST'],
]);
const actions = new Set(['place', 'interact', 'remove', 'save', 'resume', 'debugEval']);
const responseLimit = 8 * 1024 * 1024;
const now = () => Number(process.hrtime.bigint()) / 1e6;
const failure = (code, message, details = {}) => Object.assign(new Error(message), { code, ...details });
const positiveTimeout = value => Number.isInteger(value) && value > 0 && value <= 2147483647;

// A client owns its keep-alive pool. Reuse it for a whole agent run, then close it.
// Requests are sent exactly once; callers must decide how to recover after errors.
export function createClient({ url = 'http://127.0.0.1:6464', token, timeoutMs = 10000, maxSockets = 4 } = {}) {
  let base;
  try { base = new URL(url); }
  catch { throw failure('CONFIG_ERROR', 'The API URL is invalid.'); }
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password) {
    throw failure('CONFIG_ERROR', 'The API URL must use HTTP or HTTPS without embedded credentials.');
  }
  if (!positiveTimeout(timeoutMs) || !Number.isInteger(maxSockets) || maxSockets < 1 || maxSockets > 1024) {
    throw failure('CONFIG_ERROR', 'timeoutMs must be a positive timer interval and maxSockets must be 1–1024.');
  }
  if (token !== undefined && (typeof token !== 'string' || /[\r\n]/.test(token))) {
    throw failure('CONFIG_ERROR', 'The API token must be a single-line string.');
  }
  const transport = base.protocol === 'https:' ? https : http;
  const agent = new transport.Agent({ keepAlive: true, maxSockets, maxFreeSockets: maxSockets });
  const inflight = new Set();
  let closed = false;

  async function request(path, { method = 'GET', body, timeoutMs: requestTimeout = timeoutMs } = {}) {
    const started = now();
    if (closed) throw failure('CLIENT_CLOSED', 'The API client is closed.');
    if (typeof path !== 'string' || !routes.has(path) || method !== routes.get(path)) {
      throw failure('INVALID_ARGUMENT', 'Use a supported API path and its exact HTTP method.');
    }
    if (!positiveTimeout(requestTimeout)) throw failure('INVALID_ARGUMENT', 'timeoutMs must be a positive timer interval.');
    if (path !== '/health' && !token) throw failure('CONFIG_ERROR', 'Missing API token. Set SIXTYFOUR_API_TOKEN or bridge-config.json.');
    let payload;
    if (method === 'POST') {
      if (!body || typeof body !== 'object' || Array.isArray(body) || !actions.has(body.action)
        || (body.args !== undefined && (!body.args || typeof body.args !== 'object' || Array.isArray(body.args)))) {
        throw failure('INVALID_ARGUMENT', 'Actions require a supported action and an argument object.');
      }
      try { payload = JSON.stringify(body); }
      catch { throw failure('INVALID_ARGUMENT', 'The request body must be JSON serializable.'); }
    } else if (body !== undefined) {
      throw failure('INVALID_ARGUMENT', 'GET requests cannot include a body.');
    }
    const headers = { accept: 'application/json' };
    if (path !== '/health') headers.authorization = `Bearer ${token}`;
    if (payload !== undefined) {
      headers['content-type'] = 'application/json';
      headers['content-length'] = Buffer.byteLength(payload);
    }
    const deadline = started + requestTimeout;
    return new Promise((resolve, reject) => {
      let req;
      let response;
      let timer;
      let settled = false;
      const finish = (error, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        inflight.delete(operation);
        if (error) {
          reject(error);
          response?.destroy();
          req?.destroy();
        } else resolve(value);
      };
      const expired = () => {
        if (now() < deadline) return false;
        finish(failure('TIMEOUT', 'The API request exceeded its wall-clock deadline.'));
        return true;
      };
      const operation = { cancel: () => finish(failure('CLIENT_CLOSED', 'The API client was closed.')) };
      inflight.add(operation);
      const armDeadline = () => {
        timer = setTimeout(() => { if (!settled && !expired()) armDeadline(); }, Math.max(1, Math.ceil(deadline - now())));
      };
      armDeadline();
      if (expired()) return;
      try {
        req = transport.request(new URL(path, base), { method, headers, agent }, res => {
          response = res;
          if (settled || expired()) { res.destroy(); return; }
          const status = res.statusCode;
          const chunks = [];
          let size = 0;
          const tooLarge = () => finish(failure('RESPONSE_TOO_LARGE', 'The API response exceeds 8 MiB.', { status }));
          if (Number(res.headers['content-length']) > responseLimit) { tooLarge(); return; }
          res.on('data', chunk => {
            if (settled || expired()) return;
            size += chunk.length;
            if (size > responseLimit) { tooLarge(); return; }
            chunks.push(chunk);
          });
          res.on('aborted', () => finish(failure('CONNECTION_ERROR', 'The API response ended before its body was complete.')));
          res.on('error', () => finish(failure('CONNECTION_ERROR', 'The API response could not be read.')));
          res.on('end', () => {
            if (settled || expired()) return;
            let data;
            let valid = true;
            try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
            catch { valid = false; }
            if (expired()) return;
            if (status < 200 || status >= 300) {
              finish(failure('HTTP_ERROR', `API request failed (HTTP ${status}).`, { status, ...(valid ? { apiResponse: data } : {}) }));
              return;
            }
            if (!valid || !/^application\/(?:[\w.-]+\+)?json(?:\s*;|$)/i.test(res.headers['content-type'] || '')) {
              finish(failure('INVALID_RESPONSE', 'The API returned an invalid JSON response.', { status }));
              return;
            }
            finish(null, data);
          });
        });
        // Explicit on every assignment, including reused sockets. end(payload)
        // writes headers and body together rather than flushing separate packets.
        req.on('socket', socket => socket.setNoDelay(true));
        req.on('error', () => finish(failure('CONNECTION_ERROR', 'Cannot reach the Sixty Four API.')));
        req.end(payload);
      } catch {
        finish(failure('CONNECTION_ERROR', 'Cannot start the Sixty Four API request.'));
      }
    });
  }
  return {
    request,
    health: () => request('/health'),
    state: () => request('/state'),
    catalog: () => request('/catalog'),
    openapi: () => request('/openapi.json'),
    act(action, args = {}) {
      const holdMs = action === 'interact' ? (args?.holdMs ?? 0) : 0;
      if (!Number.isInteger(holdMs) || holdMs < 0 || holdMs > 5000) {
        return Promise.reject(failure('INVALID_ARGUMENT', 'holdMs must be an integer from 0 to 5000.'));
      }
      return request('/actions', { method: 'POST', body: { action, args }, timeoutMs: Math.min(2147483647, timeoutMs + holdMs) });
    },
    close() {
      if (closed) return;
      closed = true;
      for (const operation of [...inflight]) operation.cancel();
      agent.destroy();
    },
  };
}

export async function createClientFromConfig({ env = process.env, configPath = new URL('./bridge-config.json', import.meta.url) } = {}) {
  let config = {};
  try { config = JSON.parse((await readFile(configPath, 'utf8')).replace(/^\uFEFF/, '')); }
  catch (error) {
    if (error.code !== 'ENOENT') throw failure('CONFIG_ERROR', 'Cannot read a valid bridge-config.json.');
  }
  if (!config || typeof config !== 'object' || Array.isArray(config)) throw failure('CONFIG_ERROR', 'bridge-config.json must contain an object.');
  return createClient({ url: env.SIXTYFOUR_API_URL ?? config.url, token: env.SIXTYFOUR_API_TOKEN ?? config.token });
}
