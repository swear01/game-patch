'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const originalHash = 'c03bbf7f2f2a2ca963b924f1539db50583dc37e6577aef0092c6c81f0ce39944';
const marker = '// SIXTYFOUR_CLOCK_ROLLBACK_FIX_V1';
const hash = data => crypto.createHash('sha256').update(data).digest('hex');

function patchSource(source) {
  if (source.includes(marker)) throw new Error('The clock fix is already installed.');
  if (hash(source) !== originalHash) throw new Error('Unsupported game.js version/hash; refusing to change the game.');
  const eol = source.includes('\r\n') ? '\r\n' : '\n';
  function replaceOnce(before, after) {
    if (source.split(before).length !== 2) throw new Error('The expected native clock expression is not unique.');
    source = source.replace(before, after.split('\n').join(eol));
  }
  replaceOnce('const span = Math.min(now - this.time.lt, 1000)',
    'const elapsed = now - this.time.lt\n\t\tconst span = Number.isFinite(elapsed) ? Math.max(0, Math.min(elapsed, 1000)) : 0');
  replaceOnce('this.renderTime.dt = now - this.renderTime.lt',
    `${marker}\n\t\t\t// An external speed decrease can move the clock behind a worker timer's deadline.\n\t\t\tif (Number.isFinite(now) && (now < this.time.lt || now < this.renderTime.lt)) {\n\t\t\t\tthis.time.lt = now\n\t\t\t\tthis.renderTime.lt = now\n\t\t\t\tthis.clock?.terminate()\n\t\t\t\tthis.clock = new Worker(\`scripts/clock.js\`)\n\t\t\t\tthis.clock.addEventListener(\`message\`, () => this.updateLoop())\n\t\t\t\tthis.clockRollbackRecoveries = (this.clockRollbackRecoveries || 0) + 1\n\t\t\t}\n\t\t\tconst renderElapsed = now - this.renderTime.lt\n\t\t\tthis.renderTime.dt = Number.isFinite(renderElapsed) ? Math.max(0, renderElapsed) : 0`);
  return source;
}

function install(gamePath, backupDir) {
  const original = fs.readFileSync(gamePath);
  const patched = patchSource(original.toString('utf8'));
  fs.mkdirSync(backupDir, { recursive: true });
  const backupPath = path.join(backupDir, 'game.js.original');
  if (fs.existsSync(backupPath)) throw new Error('A game.js backup already exists; refusing to overwrite it.');
  fs.writeFileSync(backupPath, original, { flag: 'wx' });
  fs.writeFileSync(gamePath, patched, 'utf8');
  return { version: 1, path: path.resolve(gamePath), backupPath: path.resolve(backupPath), originalHash: hash(original), installedHash: hash(patched) };
}
module.exports = { patchSource, install, originalHash, marker };

if (require.main === module) {
  try {
    const [command, gamePath, backupDir] = process.argv.slice(2);
    if (command === 'check' && gamePath) { patchSource(fs.readFileSync(gamePath, 'utf8')); console.log(JSON.stringify({supported:true})); }
    else if (command === 'install' && gamePath && backupDir) console.log(JSON.stringify(install(gamePath, backupDir)));
    else throw new Error('Usage: node clock-fix.cjs check GAME_JS | install GAME_JS BACKUP_DIR');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
