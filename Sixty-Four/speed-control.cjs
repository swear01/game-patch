'use strict';
// Runs only in the unaccelerated gateway. The native helper isolates game clocks;
// its authoritative OpenSpeedy flag/factor controls only game simulation dt.
const { spawn } = require('node:child_process');

function startSpeedControl({ config, invoke, parentPid = process.ppid, spawnProcess = spawn, report = () => {} }) {
  const settings = config.speedControl;
  if (!settings?.enabled) return { close() {} };
  let closed = false;
  let latest;
  let sending = false;
  let buffer = '';
  let status = { running: true, isolated: false, enabled: false, factor: 1 };
  const disabled = { enabled: false, factor: 1 };
  async function pump() {
    if (sending || !latest) return;
    sending = true;
    try {
      while (latest) {
        const value = latest;
        latest = undefined;
        try { await invoke('syncSpeed', value); }
        catch (error) { report(`Speed state delivery failed: ${error.message}`); }
      }
    } finally { sending = false; }
  }
  function update(value) { latest = value; void pump(); }
  const child = spawnProcess(settings.helperPath, [
    '--apply', '--watch', '--game', settings.gameExe, '--dll', settings.dllPath,
    '--parent', String(parentPid),
  ], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', chunk => {
    if (closed) return;
    buffer += chunk.toString('utf8');
    if (buffer.length > 1024 * 1024) { buffer = ''; update(disabled); report('Speed helper output exceeded limit'); return; }
    let split;
    while ((split = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, split).trim();
      buffer = buffer.slice(split + 1);
      if (!line) continue;
      try {
        const value = JSON.parse(line);
        const protectedProcesses = Array.isArray(value.processes) && value.processes.length > 0 && value.processes.every(p => p.isolated === true);
        if (value.ok !== true || !protectedProcesses || typeof value.enabled !== 'boolean' || !Number.isFinite(value.factor) || value.factor < 0.001 || value.factor > 1000) {
          status = { running: true, isolated: false, enabled: false, factor: 1, errors: value.errors || [] };
          update(disabled);
          report('Speed helper has not isolated every game process; simulation speed stays at 1');
          continue;
        }
        status = { running: true, isolated: true, enabled: value.enabled, factor: value.enabled ? value.factor : 1, configuredFactor: value.configuredFactor, processes: value.processes, wallTimestamp: Date.now() };
        update({ enabled: value.enabled, factor: value.enabled ? value.factor : 1 });
      } catch { status = { running: true, isolated: false, enabled: false, factor: 1 }; update(disabled); report('Invalid speed helper status'); }
    }
  });
  child.stderr.on('data', data => report(data.toString('utf8').trim().slice(0, 1000)));
  child.once('error', error => { status = { running: false, enabled: false, factor: 1, error: error.message }; report(`Speed helper could not start: ${error.message}`); update(disabled); });
  child.once('exit', () => { status = { running: false, enabled: false, factor: 1 }; report('Speed helper stopped; simulation speed returns to 1'); update(disabled); });
  return {
    getStatus: () => ({ ...status }),
    close() {
      if (closed) return;
      closed = true;
      update(disabled);
      child.kill();
    },
  };
}

module.exports = { startSpeedControl };
