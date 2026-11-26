import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { once } from 'node:events';

const cli = fileURLToPath(new URL('./sixtyfour.mjs', import.meta.url));

function run(args, url, token = 'test-local-token') {
  return runScript(cli, args, url, token);
}

function runScript(script, args, url, token = 'test-local-token') {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script, ...args], {
      env: { ...process.env, SIXTYFOUR_API_URL: url, SIXTYFOUR_API_TOKEN: token },
      windowsHide: true,
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, stdout, stderr }));
  });
}

test('CLI speaks the authenticated bridge protocol and preserves world coordinates', async t => {
  const seen = [];
  const server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    seen.push({ method: request.method, path: request.url, token: request.headers.authorization, body: body ? JSON.parse(body) : undefined });
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ ok: true, result: { received: seen.at(-1).body ?? request.url } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const url = `http://127.0.0.1:${server.address().port}`;
  for (const command of ['health', 'state', 'catalog', 'openapi']) {
    const result = await run([command], url);
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stderr, '');
    assert.equal(JSON.parse(result.stdout).ok, true);
  }
  assert.equal(seen[0].token, undefined, 'health must not send credentials');
  assert.equal(seen[1].token, 'Bearer test-local-token');
  assert.deepEqual(seen.slice(0, 4).map(item => item.path), ['/health', '/state', '/catalog', '/openapi.json']);
  for (const args of [
    ['place', 'pump', '-3', '7'], ['interact', '-3', '7', '--hold-ms', '1250'],
    ['remove', '-3', '7'], ['save'], ['request', 'interact', '{"x":2,"y":4}'], ['resume'],
  ]) {
    const result = await run(args, url);
    assert.equal(result.code, 0, result.stderr);
    assert.equal(seen.at(-1).method, 'POST');
    assert.equal(seen.at(-1).path, '/actions');
  }
  assert.deepEqual(seen[4].body, { action: 'place', args: { type: 'pump', x: -3, y: 7 } });
  assert.deepEqual(seen[5].body, { action: 'interact', args: { x: -3, y: 7, holdMs: 1250 } });
  assert.deepEqual(seen[6].body, { action: 'remove', args: { x: -3, y: 7 } });
  assert.deepEqual(seen[7].body, { action: 'save', args: {} });
  assert.deepEqual(seen[8].body, { action: 'interact', args: { x: 2, y: 4 } });
  assert.deepEqual(seen[9].body, { action: 'resume', args: {} });
});

test('example agent defaults to dry run and reuses its client for an explicitly enabled action', { timeout: 10000 }, async t => {
  const seen = [];
  const server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    seen.push({ path: request.url, socket: request.socket, body: body ? JSON.parse(body) : undefined });
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ ok: true, data: request.url === '/state' ? {
      menuShown: false, halted: false, resources: [{ amount: 2 }],
      entities: [{ type: 'destabilizer', canInteract: true, fuel: [1], x: 3, y: -2 }],
    } : { performed: 1 } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const example = fileURLToPath(new URL('./example-agent.mjs', import.meta.url));
  const url = `http://127.0.0.1:${server.address().port}`;
  const preview = await runScript(example, [], url);
  assert.equal(preview.code, 0, preview.stderr);
  assert.deepEqual(JSON.parse(preview.stdout), { action: 'interact', args: { x: 3, y: -2 }, machine: 'destabilizer', dryRun: true });
  assert.deepEqual(seen.map(value => value.path), ['/state']);
  const performed = await runScript(example, ['--act'], url);
  assert.equal(performed.code, 0, performed.stderr);
  assert.deepEqual(JSON.parse(performed.stdout), { performed: 1 });
  assert.deepEqual(seen.map(value => value.path), ['/state', '/state', '/actions']);
  assert.equal(seen[1].socket, seen[2].socket);
  assert.deepEqual(seen[2].body, { action: 'interact', args: { x: 3, y: -2 } });
});

test('invalid CLI inputs never reach the bridge', async t => {
  let count = 0;
  const server = createServer((request, response) => { count++; response.end('{}'); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const url = `http://127.0.0.1:${server.address().port}`;
  for (const args of [
    ['place', 'pump', '1.5', '2'], ['place', 'pump', '1', '9007199254740993'],
    ['interact', '0', '0', '--hold-ms', '5001'], ['interact', '0', '0', '--hold-ms', '-1'],
    ['interact', '0', '0', '--unknown', '10'], ['save', 'unexpected'],
    ['request', 'eval', '{}'], ['request', 'place', '[]'], ['request', 'place', '{broken'],
    ['state', 'extra'], ['unknown'],
  ]) {
    const result = await run(args, url);
    assert.equal(result.code, 1, args.join(' '));
    assert.equal(result.stdout, '');
    assert.equal(JSON.parse(result.stderr).error.code, 'INVALID_ARGUMENT');
  }
  assert.equal(count, 0);
});

test('API rejection is machine-readable and preserves its error detail', async t => {
  const server = createServer((request, response) => {
    response.writeHead(409, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ ok: false, error: { code: 'INSUFFICIENT_RESOURCES', message: 'Need more coal', cost: 64 } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const result = await run(['place', 'pump', '0', '0'], `http://127.0.0.1:${server.address().port}`);
  assert.equal(result.code, 1);
  assert.equal(result.stdout, '');
  assert.deepEqual(JSON.parse(result.stderr), {
    ok: false, httpStatus: 409,
    error: { code: 'INSUFFICIENT_RESOURCES', message: 'Need more coal', cost: 64 },
  });
});

test('missing credentials fail locally and help is available offline', async () => {
  const result = await run(['state'], 'http://127.0.0.1:1', '');
  assert.equal(result.code, 1);
  assert.equal(JSON.parse(result.stderr).error.code, 'CONFIG_ERROR');
  const help = await run(['--help'], 'http://127.0.0.1:1', '');
  assert.equal(help.code, 0);
  assert.match(help.stdout, /world grid coordinates/);
});

function startSession(url, token = 'session-token') {
  const child = spawn(process.execPath, [cli, 'session'], {
    env: { ...process.env, SIXTYFOUR_API_URL: url, SIXTYFOUR_API_TOKEN: token }, windowsHide: true,
  });
  const responses = [], waiting = [];
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  createInterface({ input: child.stdout }).on('line', line => {
    const response = JSON.parse(line);
    if (waiting.length) waiting.shift()(response); else responses.push(response);
  });
  const closed = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', code => resolve({ code, stderr }));
  });
  return {
    child, closed,
    send(value) { child.stdin.write(`${typeof value === 'string' ? value : JSON.stringify(value)}\n`); },
    next() { return responses.length ? Promise.resolve(responses.shift()) : new Promise(resolve => waiting.push(resolve)); },
  };
}

test('persistent CLI session preserves IDs, validation and API errors over one TCP connection', { timeout: 10000 }, async t => {
  const seen = [], sockets = new Set();
  let active = 0, maxActive = 0;
  const server = createServer(async (request, response) => {
    active++; maxActive = Math.max(maxActive, active);
    let body = '';
    for await (const chunk of request) body += chunk;
    seen.push({ path: request.url, token: request.headers.authorization, body: body ? JSON.parse(body) : undefined });
    if (request.url === '/state') await new Promise(resolve => setTimeout(resolve, 30));
    const failure = request.url === '/actions';
    response.writeHead(failure ? 409 : 200, { 'content-type': 'application/json' });
    response.end(JSON.stringify(failure
      ? { ok: false, error: { code: 'CANNOT_REMOVE', message: 'Machine is busy', refund: [64] } }
      : { ok: true, data: { path: request.url } }));
    active--;
  });
  server.on('connection', socket => sockets.add(socket));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const running = startSession(`http://127.0.0.1:${server.address().port}`);
  t.after(() => running.child.kill());
  running.send({ id: 0, argv: ['state'] });
  running.send('{bad-json');
  running.send({ id: 'invalid', argv: ['place', 'pump', 'x', '2'] });
  running.send({ id: 'nested', argv: ['session'] });
  running.send({ id: 'unknown', argv: ['request', 'eval', '{}'] });
  running.send({ id: 'catalog', argv: ['catalog'] });
  running.send({ id: 'remove', argv: ['remove', '-1', '2'] });
  running.send({ id: 'health', argv: ['health'] });
  running.child.stdin.end();
  const actual = [];
  for (let i = 0; i < 8; i++) actual.push(await running.next());
  assert.deepEqual(actual.map(value => value.id), [0, null, 'invalid', 'nested', 'unknown', 'catalog', 'remove', 'health']);
  assert.deepEqual(actual[0], { id: 0, ok: true, data: { path: '/state' } });
  assert.equal(actual[1].error.code, 'INVALID_JSON');
  for (const value of actual.slice(2, 5)) assert.equal(value.error.code, 'INVALID_ARGUMENT');
  assert.deepEqual(actual[6], {
    id: 'remove', ok: false, httpStatus: 409,
    error: { code: 'CANNOT_REMOVE', message: 'Machine is busy', refund: [64] },
  });
  assert.deepEqual(seen.map(value => value.path), ['/state', '/catalog', '/actions', '/health']);
  assert.deepEqual(seen[2].body, { action: 'remove', args: { x: -1, y: 2 } });
  assert.deepEqual(seen.map(value => value.token), ['Bearer session-token', 'Bearer session-token', 'Bearer session-token', undefined]);
  assert.equal(maxActive, 1, 'commands must execute in input order');
  assert.equal(sockets.size, 1, 'one session must reuse one TCP connection');
  const completion = await running.closed;
  assert.deepEqual(completion, { code: 0, stderr: '' });
  assert.equal([...sockets][0].destroyed, true, 'EOF must close the pooled socket');
});

test('session rejects invalid IDs and oversized UTF-8 lines, then accepts a final unterminated line', { timeout: 10000 }, async t => {
  let requests = 0;
  const server = createServer((request, response) => { requests++; response.setHeader('content-type', 'application/json'); response.end('{"ok":true,"data":{}}'); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const running = startSession(`http://127.0.0.1:${server.address().port}`);
  t.after(() => running.child.kill());
  running.send({ id: false, argv: ['save'] });
  running.send({ id: 'bad-argv', argv: ['state', 1] });
  running.send('é'.repeat(8193));
  running.child.stdin.end(JSON.stringify({ id: 'last', argv: ['state'] }));
  const actual = [];
  for (let i = 0; i < 4; i++) actual.push(await running.next());
  assert.deepEqual(actual.map(value => value.id), [null, 'bad-argv', null, 'last']);
  assert.deepEqual(actual.slice(0, 3).map(value => value.error.code), ['INVALID_ARGUMENT', 'INVALID_ARGUMENT', 'LINE_TOO_LONG']);
  assert.equal(actual[3].ok, true);
  assert.equal(requests, 1);
  assert.deepEqual(await running.closed, { code: 0, stderr: '' });
});

test('session does not retry a disconnected mutation and continues with later commands', { timeout: 10000 }, async t => {
  let mutations = 0;
  const server = createServer((request, response) => {
    if (request.url === '/actions') { mutations++; request.socket.destroy(); }
    else { response.setHeader('content-type', 'application/json'); response.end('{"ok":true,"data":{}}'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const running = startSession(`http://127.0.0.1:${server.address().port}`);
  t.after(() => running.child.kill());
  running.send({ id: 1, argv: ['save'] }); running.send({ id: 2, argv: ['state'] }); running.child.stdin.end();
  const failure = await running.next(), success = await running.next();
  assert.equal(failure.id, 1); assert.equal(failure.ok, false);
  assert.equal(success.id, 2); assert.equal(success.ok, true);
  assert.equal(mutations, 1);
  assert.deepEqual(await running.closed, { code: 0, stderr: '' });
});

test('SIGINT and SIGTERM exit a session even when a large response blocks stdout', { timeout: 10000 }, async t => {
  const server = createServer((_request, response) => {
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ ok: true, data: { payload: 'x'.repeat(2 * 1024 * 1024) } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
    // process.emit invokes the actual registered handler on Windows as well as
    // Unix; child.kill(SIGTERM) forcibly terminates Windows processes instead.
    const wrapper = `
      import { pathToFileURL } from 'node:url';
      process.on('message', signal => { process.stderr.write('signal:' + signal); process.emit(signal); });
      process.argv = [process.execPath, ${JSON.stringify(cli)}, 'session'];
      await import(pathToFileURL(${JSON.stringify(cli)}));
    `;
    const child = spawn(process.execPath, ['--input-type=module', '-e', wrapper], {
      env: { ...process.env, SIXTYFOUR_API_URL: `http://127.0.0.1:${server.address().port}`, SIXTYFOUR_API_TOKEN: 'signal-token' },
      windowsHide: true, stdio: ['pipe', 'pipe', 'pipe', 'ipc'],
    });
    t.after(() => child.kill());
    let stderr = '';
    child.stderr.on('data', chunk => { stderr += chunk; });
    const exited = once(child, 'exit');
    const closed = once(child, 'close');
    child.stdin.write('{"id":0,"argv":["state"]}\n');
    const deadline = Date.now() + 3000;
    while (child.stdout.readableLength < 65536 && child.exitCode === null && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert.ok(child.stdout.readableLength >= 65536, 'stdout must be backpressured before sending the signal');
    assert.equal(child.exitCode, null);
    const signaledAt = performance.now();
    child.send(signal);
    assert.deepEqual(await exited, [process.platform === 'win32' ? 1 : code, null]);
    assert.ok(performance.now() - signaledAt < 1500, 'intentional signal must terminate without waiting for stdout to drain');
    child.stdout.resume();
    await closed;
    assert.equal(stderr, `signal:${signal}`, 'blocked output must not prevent the JS signal handler from running');
  }
});
