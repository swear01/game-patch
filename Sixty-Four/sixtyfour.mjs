#!/usr/bin/env node
import { write as writeFileDescriptor } from 'node:fs';
import { createClientFromConfig } from './client.mjs';

const help = `Sixty Four agent CLI (Node.js 24+)

Usage: node sixtyfour.mjs COMMAND
  health                        Check whether the local bridge is running
  state                         Read resources and placed machines
  catalog                       Read machine types, unlocks and costs
  place TYPE X Y                Place a machine at integer world coordinates
  interact X Y [--hold-ms N]     Click or hold a machine (0–5000 ms)
  remove X Y                    Remove a machine using normal recycling rules
  save                          Save current game progress
  resume                        Resume the game after the pause/start menu
  request ACTION JSON           Send one supported action with JSON arguments
  openapi                       Read the HTTP API schema
  session                       Keep one client open; read NDJSON commands on stdin

Examples:
  node sixtyfour.mjs state
  node sixtyfour.mjs catalog
  node sixtyfour.mjs place pump 3 -2
  node sixtyfour.mjs interact 3 -2 --hold-ms 1000
  node sixtyfour.mjs remove 3 -2

X and Y are world grid coordinates from state, not screen pixels.
Configuration: bridge-config.json beside this CLI, overridden by
SIXTYFOUR_API_URL and SIXTYFOUR_API_TOKEN environment variables.
Every successful command emits JSON. Errors emit JSON on stderr and exit 1.
Session input: {"id":1,"argv":["state"]}; one JSON response per line on stdout.
Use session as the persistent entry point for CLI agents.
EOF finishes queued commands. SIGINT/SIGTERM cancel work and abandon pending output.
Signal exit codes follow the platform; Windows forces termination after socket cleanup.
`;

function fail(message, code = 'CLI_ERROR') {
  throw Object.assign(new Error(message), { code });
}

function integer(value, label) {
  if (typeof value !== 'string' || !/^-?\d+$/.test(value) || !Number.isSafeInteger(Number(value))) {
    fail(`${label} must be a safe integer.`, 'INVALID_ARGUMENT');
  }
  return Number(value);
}

function parse(argv) {
  const [command, ...args] = argv;
  if (!command || command === 'help' || command === '--help' || command === '-h') return { help: true };
  if (command === 'session') {
    if (args.length) fail('session takes no arguments.', 'INVALID_ARGUMENT');
    return { session: true };
  }
  const endpoints = { health: '/health', state: '/state', catalog: '/catalog', openapi: '/openapi.json' };
  if (Object.hasOwn(endpoints, command)) {
    if (args.length) fail(`${command} takes no arguments.`, 'INVALID_ARGUMENT');
    return { path: endpoints[command], timeout: 10000, health: command === 'health' };
  }
  let action = command;
  let payload;
  if (command === 'place') {
    if (args.length !== 3) fail('Usage: place TYPE X Y', 'INVALID_ARGUMENT');
    payload = { type: args[0], x: integer(args[1], 'X'), y: integer(args[2], 'Y') };
  } else if (command === 'interact') {
    if (args.length !== 2 && !(args.length === 4 && args[2] === '--hold-ms')) {
      fail('Usage: interact X Y [--hold-ms N]', 'INVALID_ARGUMENT');
    }
    payload = { x: integer(args[0], 'X'), y: integer(args[1], 'Y') };
    if (args.length === 4) payload.holdMs = integer(args[3], 'hold-ms');
  } else if (command === 'remove') {
    if (args.length !== 2) fail('Usage: remove X Y', 'INVALID_ARGUMENT');
    payload = { x: integer(args[0], 'X'), y: integer(args[1], 'Y') };
  } else if (command === 'save' || command === 'resume') {
    if (args.length) fail(`${command} takes no arguments.`, 'INVALID_ARGUMENT');
    payload = {};
  } else if (command === 'request') {
    if (args.length !== 2) fail('Usage: request ACTION JSON', 'INVALID_ARGUMENT');
    action = args[0];
    try { payload = JSON.parse(args[1]); } catch { fail('JSON arguments could not be parsed.', 'INVALID_ARGUMENT'); }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      fail('JSON arguments must be an object.', 'INVALID_ARGUMENT');
    }
  } else {
    fail(`Unknown command: ${command}. Run with --help for usage.`, 'INVALID_ARGUMENT');
  }
  if (!['place', 'interact', 'remove', 'save', 'resume'].includes(action)) fail(`Unsupported action: ${action}`, 'INVALID_ARGUMENT');
  if (payload.holdMs !== undefined && (!Number.isInteger(payload.holdMs) || payload.holdMs < 0 || payload.holdMs > 5000)) {
    fail('hold-ms must be between 0 and 5000.', 'INVALID_ARGUMENT');
  }
  return { path: '/actions', body: { action, args: payload }, timeout: 10000 + (payload.holdMs || 0) };
}

function errorResult(error) {
  return error.apiResponse && typeof error.apiResponse === 'object' && !Array.isArray(error.apiResponse)
    ? { ...error.apiResponse, httpStatus: error.status }
    : { ok: false, error: { code: error.code ?? 'CLI_ERROR', message: error.message } };
}

function execute(client, request) {
  return client.request(request.path, {
    method: request.body ? 'POST' : 'GET', body: request.body, timeoutMs: request.timeout,
  });
}

async function writeOutput(text) {
  // Windows stdout pipe writes can block the JS thread. Async filesystem writes
  // keep signal handling responsive while an agent pauses its output reader.
  const buffer = Buffer.from(text);
  let offset = 0;
  while (offset < buffer.length) {
    const written = await new Promise((resolve, reject) => {
      writeFileDescriptor(1, buffer, offset, buffer.length - offset, null, (error, count) => error ? reject(error) : resolve(count));
    });
    if (!written) fail('Cannot write CLI output.', 'OUTPUT_ERROR');
    offset += written;
  }
}

function writeLine(value) {
  return writeOutput(`${JSON.stringify(value)}\n`);
}

async function session(client, stopped) {
  const limit = 16 * 1024;
  let buffered = Buffer.alloc(0), dropping = false;
  async function line(bytes) {
    let id = null;
    try {
      let input;
      try { input = JSON.parse(bytes.toString('utf8')); }
      catch { fail('Session line must contain valid JSON.', 'INVALID_JSON'); }
      if (!input || typeof input !== 'object' || Array.isArray(input)) fail('Session input must be an object.', 'INVALID_ARGUMENT');
      if (!(typeof input.id === 'string' || Number.isSafeInteger(input.id))) fail('id must be a string or safe integer.', 'INVALID_ARGUMENT');
      id = input.id;
      if (Object.keys(input).some(key => !['id', 'argv'].includes(key))) fail('Session input accepts only id and argv.', 'INVALID_ARGUMENT');
      if (!Array.isArray(input.argv) || !input.argv.every(arg => typeof arg === 'string')) fail('argv must be an array of strings.', 'INVALID_ARGUMENT');
      const request = parse(input.argv);
      if (request.session) fail('Nested sessions are not supported.', 'INVALID_ARGUMENT');
      const data = request.help ? { ok: true, data: { help } } : await execute(client, request);
      await writeLine({ ...data, id });
    } catch (error) { await writeLine({ ...errorResult(error), id }); }
  }
  try {
    for await (const chunk of process.stdin) {
      if (stopped()) break;
      let offset = 0;
      while (offset < chunk.length && !stopped()) {
        const newline = chunk.indexOf(10, offset);
        const end = newline < 0 ? chunk.length : newline;
        const part = chunk.subarray(offset, end);
        if (!dropping && buffered.length + part.length > limit) {
          buffered = Buffer.alloc(0); dropping = true;
          await writeLine({ id: null, ok: false, error: { code: 'LINE_TOO_LONG', message: 'Session lines must not exceed 16 KiB.' } });
        }
        if (!dropping) buffered = Buffer.concat([buffered, part]);
        if (newline < 0) break;
        if (!dropping) await line(buffered);
        buffered = Buffer.alloc(0); dropping = false; offset = newline + 1;
      }
    }
    if (!stopped() && !dropping && buffered.length) await line(buffered);
  } catch (error) { if (!stopped()) throw error; }
}

async function main() {
  const request = parse(process.argv.slice(2));
  if (request.help) { process.stdout.write(help); return; }
  const client = await createClientFromConfig();
  let stopping = false;
  const stop = signal => {
    stopping = true;
    process.stdin.destroy();
    // Intentional termination must also work when the parent stops reading stdout.
    // EOF drains normally; signals abandon pending results after closing sockets.
    try { client.close(); }
    finally {
      // Windows process.exit waits for a blocked async pipe write's worker.
      // Terminate only this CLI after synchronous socket cleanup on user signals.
      if (process.platform === 'win32') process.kill(process.pid, 'SIGKILL');
      else process.exit(signal === 'SIGINT' ? 130 : 143);
    }
  };
  const interrupt = () => stop('SIGINT'), terminate = () => stop('SIGTERM');
  process.once('SIGINT', interrupt); process.once('SIGTERM', terminate);
  try {
    if (request.session) await session(client, () => stopping);
    else await writeOutput(`${JSON.stringify(await execute(client, request), null, 2)}\n`);
  } finally {
    await client.close();
    process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', terminate);
  }
}

main().catch(error => {
  process.stderr.write(`${JSON.stringify(errorResult(error), null, 2)}\n`);
  process.exitCode = 1;
});
