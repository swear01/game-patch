'use strict';
// The game process only executes whitelisted renderer operations.
// HTTP, action deadlines, click cadence and hold duration live in standalone Node.
const fs = require('node:fs');
const path = require('node:path');
const { fork } = require('node:child_process');
const { app, BrowserWindow } = require('electron');
const dispatch = require('./renderer-adapter.cjs');
const audioGuard = require('./audio-guard.cjs');
const config = JSON.parse(fs.readFileSync(path.join(__dirname, 'bridge-config.json'), 'utf8'));
const simulationClock = config.speedControl?.enabled ? require('./simulation-clock.cjs') : null;
const logPath = path.join(__dirname, 'bridge.log');
const actions = new Set(['state', 'catalog', 'save', 'resume', 'place', 'remove', 'interact', 'beginInteraction', 'endInteraction', 'releaseInteractions', 'syncSpeed']);
const log = message => fs.appendFileSync(logPath, `${new Date().toISOString()} ${message}\n`);
let child;
let stopping = false;
let released = false;

async function execute(action, args) {
  const win = BrowserWindow.getAllWindows().find(w => !w.isDestroyed() && /[\\/]game[\\/]index\.html/.test(decodeURI(w.webContents.getURL())));
  if (!win) throw Object.assign(new Error('Game window is not ready'), { code: 'NOT_READY' });
  if (action === 'syncSpeed') {
    if (!simulationClock) throw Object.assign(new Error('Native clock isolation is not configured'), { code: 'NOT_CONFIGURED' });
    if (typeof args.enabled !== 'boolean' || !Number.isFinite(args.factor) || args.factor < 0.001 || args.factor > 1000) {
      throw Object.assign(new Error('Invalid internal speed sample'), { code: 'BAD_ARGUMENT' });
    }
    return win.webContents.executeJavaScript(`(()=>{try{if(typeof game==='undefined')return {ok:false,error:{code:'NOT_READY'}};const audioKey=Symbol.for('sixtyfour.agent.audioGuard.v1');const audio=game[audioKey]||(${audioGuard.install.toString()})(game);audio.setAcceleration(${JSON.stringify(args.enabled ? args.factor : 1)});const key=Symbol.for('sixtyfour.experimental.simulationClock.v1');const clock=game[key]||(${simulationClock.install.toString()})(game);return {ok:true,data:clock.setState(${JSON.stringify({ enabled: args.enabled, factor: args.factor })})}}catch(e){return {ok:false,error:{code:e.code||'GAME_ERROR',message:e.message}}}})()`);
  }
  const expression = `(async()=>{try{if(typeof game!=='undefined'){const audioKey=Symbol.for('sixtyfour.agent.audioGuard.v1');game[audioKey]||(${audioGuard.install.toString()})(game)}return {ok:true,data:await (${dispatch.toString()})(${JSON.stringify(action)},${JSON.stringify(args)})}}catch(e){return {ok:false,error:{code:e.code||'GAME_ERROR',message:e.message}}}})()`;
  // Only the external gateway owns deadlines. Keep this RPC outstanding until
  // native execution settles so a timed-out mutation cannot overlap its successor.
  return win.webContents.executeJavaScript(expression);
}

function release() {
  if (released) return;
  released = true;
  // Do not wait on a renderer that might be closing or stalled.
  execute('releaseInteractions', {}).catch(() => {});
}

function stop() {
  if (stopping) return;
  stopping = true;
  release();
  // The child owns closing its server and exiting on IPC disconnection.
  if (child?.connected) {
    try { child.disconnect(); } catch { /* The child may already have exited. */ }
  }
}

app.once('before-quit', stop);
app.whenReady().then(() => {
  if (stopping) return;
  if (typeof config.nodePath !== 'string' || !path.isAbsolute(config.nodePath) || !fs.statSync(config.nodePath).isFile()) {
    throw new Error('A standalone Node.js 24+ executable is required; run install-api-isolation.ps1.');
  }
  child = fork(path.join(__dirname, 'bridge-gateway.cjs'), [], {
    execPath: config.nodePath, execArgv: [], windowsHide: true,
    stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
  });
  const active = new Set();
  child.on('message', async message => {
    if (stopping || !message || !Number.isSafeInteger(message.id) || message.id < 1) return;
    const { id, action, args } = message;
    if (active.has(id)) return;
    const reply = result => {
      if (!child.connected) return;
      try { child.send({ id, result }, error => { if (error && !stopping) log('Gateway reply failed.'); }); }
      catch { if (!stopping) log('Gateway reply failed.'); }
    };
    if (!actions.has(action) || !args || typeof args !== 'object' || Array.isArray(args)) {
      reply({ ok: false, error: { code: 'BAD_REQUEST', message: 'Unknown action or invalid arguments.' } });
      return;
    }
    active.add(id);
    try { reply(await execute(action, args)); }
    catch (error) { reply({ ok: false, error: { code: error.code || 'BRIDGE_ERROR', message: error.message } }); }
    finally { active.delete(id); }
  });
  child.once('disconnect', release);
  child.once('exit', (code, signal) => {
    release();
    if (!stopping) log(`Gateway exited (${code ?? signal ?? 'unknown'}); restart the game to start it again.`);
  });
  child.once('error', () => { release(); log('Gateway failed to start; check the configured standalone Node executable.'); });
}).catch(error => log(error.message));
