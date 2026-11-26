'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

// Use the user's installed copy or a local original backup; do not distribute
// the game's proprietary source in this deliverable.
const configPath = path.join(__dirname, 'installation.json');
const installation = fs.existsSync(configPath) ? JSON.parse(fs.readFileSync(configPath, 'utf8')) : null;
const scripts = process.env.SIXTYFOUR_GAME_SCRIPTS || (installation && path.join(installation.gameDir, 'resources/app/game/scripts'));
const originalCandidates = [
  process.env.SIXTYFOUR_ORIGINAL_GAME_JS,
  installation?.freezeFix?.backupPath,
  path.join(__dirname, '../../work/freeze/game.js.original'),
  installation && installation.backupDir && path.join(installation.backupDir, 'game.js.original'),
].filter(Boolean);
const originalFile = originalCandidates.find(filename => fs.existsSync(filename));
const sourceFile = originalFile || (scripts && path.join(scripts, 'game.js'));
const canRun = Boolean(sourceFile && fs.existsSync(sourceFile));
const original = canRun ? fs.readFileSync(sourceFile, 'utf8') : '';
const sourceTest = (name, fn) => test(name, { skip: canRun ? false : 'Local Sixty Four source required; set SIXTYFOUR_ORIGINAL_GAME_JS and SIXTYFOUR_GAME_SCRIPTS.' }, fn);
function patch(source) {
  const result = require('./clock-fix.cjs').patchSource(source);
  return typeof result === 'string' ? result : result.source;
}
function engine(source) {
  const clocks = [];
  const frames = [];
  const time = { now: 466432.1 };
  class FakeWorker {
    constructor(url) { this.url = url; this.listeners = new Map(); this.messages = []; this.terminated = 0; clocks.push(this); }
    addEventListener(name, callback) { this.listeners.set(name, callback); }
    postMessage(value) { this.messages.push(value); }
    terminate() { this.terminated++; }
    emitMessage() { const callback = this.listeners.get('message'); assert.equal(typeof callback, 'function'); callback({data:true}); }
  }
  const context = vm.createContext({ performance:{now:()=>time.now}, Worker:FakeWorker, requestAnimationFrame:callback=>frames.push(callback), Number, Math, console });
  vm.runInContext(source, context, { filename: 'game.js' });
  const Game = vm.runInContext('Game', context);
  const oldWorker = new FakeWorker('scripts/clock.js');
  const stopRender = new Error('test render boundary');
  const game = Object.create(Game.prototype);
  Object.assign(game, {
    solidUnit:1,zoom:1,halt:false,plane:0,slowdown:{state:false},
    time:{lt:1420533.9,dt:5,realDt:5},renderTime:{lt:466384.1,dt:0},
    stats:{totalPlayTime:1000,totalPlayAndIdleTime:1000}, clock:oldWorker,
    ctx:{fillRect(){throw stopRender;}},
    updateCycle(span){this.time.dt=span;this.time.realDt=span;this.stats.totalPlayAndIdleTime+=span;return true;},
  });
  function frame() {
    try { game.renderloop(); }
    catch(error) { if(error !== stopRender) throw error; }
  }
  return {game,context,clocks,frames,time,oldWorker,frame};
}

sourceTest('unpatched source leaves the observed stalled worker unrecovered despite live render frames',()=>{
  const e=engine(original);
  e.frame();
  assert.equal(e.game.time.lt,1420533.9);
  assert.equal(e.game.stats.totalPlayTime,1000);
  assert.equal(e.oldWorker.terminated,0);
  assert.equal(e.clocks.length,1);
  assert(Math.abs(e.game.renderTime.dt-48)<0.001);
});

sourceTest('a live render frame detects simulation-clock rollback and restarts exactly one native worker',()=>{
  const e=engine(patch(original));
  e.frame();
  assert.equal(e.oldWorker.terminated,1);
  assert.equal(e.clocks.length,2);
  assert.equal(e.clocks[1].url,'scripts/clock.js');
  assert.equal(e.game.clock,e.clocks[1]);
  assert(Number.isFinite(e.game.time.lt));
  assert(e.game.time.lt<=e.time.now);
  const before=e.game.stats.totalPlayTime;
  e.time.now+=50;
  e.clocks[1].emitMessage();
  assert(e.game.stats.totalPlayTime>before);
  assert(e.game.time.dt>0 && e.game.time.dt<=1000);
  assert.equal(e.game.time.lt,e.time.now);
  assert(e.clocks[1].messages.length>0,'replacement worker must receive the tick acknowledgement');
  for(let i=0;i<4;i++){e.time.now+=16;e.frame();}
  assert.equal(e.clocks.length,2,'normal frames must not continually rebuild the worker');
  assert.equal(e.oldWorker.terminated,1);
});

sourceTest('simulation delta is nonnegative and finite after rollback and invalid clock samples',()=>{
  for(const [previous,now] of [[1000,100],[NaN,100],[100,NaN],[Infinity,100],[100,Infinity]]) {
    const e=engine(patch(original));
    e.game.time.lt=previous;e.time.now=now;
    e.game.updateLoop();
    assert(Number.isFinite(e.game.time.dt),`${previous} -> ${now} produced a non-finite simulation delta`);
    assert(e.game.time.dt>=0 && e.game.time.dt<=1000);
    assert(Number.isFinite(e.game.stats.totalPlayTime));
  }
});

sourceTest('normal and accelerated positive simulation/render deltas retain native timing behavior',()=>{
  for(const delta of [5,50,500,2500]) {
    const e=engine(patch(original));
    e.time.now=10000+delta;e.game.time.lt=10000;e.game.renderTime.lt=10000;
    e.game.updateLoop();e.frame();
    assert.equal(e.game.time.dt,Math.min(delta,1000));
    assert.equal(e.game.renderTime.dt,delta,'render delta must not be capped during ordinary acceleration');
    assert.equal(e.clocks.length,1);
  }
});

sourceTest('rendering does not propagate negative or non-finite clock deltas',()=>{
  for(const [previous,now] of [[1000,100],[NaN,100],[100,NaN],[Infinity,100],[100,Infinity]]) {
    const e=engine(patch(original));
    e.game.time.lt=100;e.game.renderTime.lt=previous;e.time.now=now;
    e.frame();
    assert(Number.isFinite(e.game.renderTime.dt),`${previous} -> ${now} produced a non-finite render delta`);
    assert(e.game.renderTime.dt>=0);
  }
});

sourceTest('native update errors remain visible instead of being swallowed by clock recovery',()=>{
  const e=engine(patch(original));
  e.game.time.lt=e.time.now-16;
  const failure=new Error('native simulation failure');
  e.game.updateCycle=()=>{throw failure;};
  assert.throws(()=>e.game.updateLoop(),error=>error===failure);
});

sourceTest('installation preserves the exact original, records hashes, and refuses duplicate or unsupported installs',t=>{
  const {install,originalHash}=require('./clock-fix.cjs');
  const workRoot=path.resolve(__dirname,'../../work');
  fs.mkdirSync(workRoot,{recursive:true});
  const fixtureRoot=fs.mkdtempSync(path.join(workRoot,'clock-install-test-'));
  t.after(()=>{
    const safe=path.resolve(fixtureRoot);
    assert(safe.startsWith(workRoot+path.sep) && path.basename(safe).startsWith('clock-install-test-'));
    fs.rmSync(safe,{recursive:true,force:true});
  });
  const digest=value=>crypto.createHash('sha256').update(value).digest('hex');
  const target=path.join(fixtureRoot,'game.js');
  const backups=path.join(fixtureRoot,'backups');
  fs.writeFileSync(target,original,'utf8');
  const record=install(target,backups);
  assert.equal(record.version,1);
  assert.equal(record.path,path.resolve(target));
  assert.equal(record.backupPath,path.resolve(backups,'game.js.original'));
  assert.equal(record.originalHash,originalHash);
  assert.equal(digest(fs.readFileSync(record.backupPath)),originalHash);
  assert.equal(fs.readFileSync(record.backupPath,'utf8'),original);
  const installed=fs.readFileSync(target);
  assert.equal(record.installedHash,digest(installed));
  assert.notEqual(record.installedHash,record.originalHash);
  assert.equal(installed.toString('utf8'),patch(original));
  assert.throws(()=>install(target,backups),/already installed/);
  assert.equal(digest(fs.readFileSync(record.backupPath)),originalHash,'duplicate install must preserve backup');
  assert.equal(digest(fs.readFileSync(target)),record.installedHash,'duplicate install must preserve installed source');
  const unknown=path.join(fixtureRoot,'unsupported-game.js');
  const unknownBackup=path.join(fixtureRoot,'unsupported-backup');
  fs.writeFileSync(unknown,original+'\n// Simulated different game version\n','utf8');
  const unknownBefore=fs.readFileSync(unknown);
  assert.throws(()=>install(unknown,unknownBackup),/Unsupported game.js version\/hash/);
  assert.deepEqual(fs.readFileSync(unknown),unknownBefore);
  assert.equal(fs.existsSync(unknownBackup),false,'unsupported versions must not create a misleading backup');
});

sourceTest('PowerShell clock installation leaves original files intact on readonly-record and late record-write failures',t=>{
  if(process.platform!=='win32') {t.skip('Windows file attributes and PowerShell 7 required.');return;}
  const pwsh=process.env.SIXTYFOUR_PWSH || 'pwsh';
  const probe=spawnSync(pwsh,['-NoLogo','-NoProfile','-NonInteractive','-Command','$PSVersionTable.PSVersion.Major'],{encoding:'utf8',windowsHide:true});
  if(probe.error || probe.status!==0 || Number(probe.stdout.trim())<7){t.skip('PowerShell 7 not available.');return;}
  const workRoot=path.resolve(__dirname,'../../work');
  fs.mkdirSync(workRoot,{recursive:true});
  const fixtureRoot=fs.mkdtempSync(path.join(workRoot,'clock-install-test-'));
  const readonlyScript=path.join(fixtureRoot,'readonly.ps1');
  fs.writeFileSync(readonlyScript,'param([string]$Target,[string]$Mode)\n(Get-Item -LiteralPath $Target).IsReadOnly=($Mode -eq "on")\n');
  const run=(script,args=[])=>spawnSync(pwsh,['-NoLogo','-NoProfile','-NonInteractive','-File',script,...args],{encoding:'utf8',timeout:30000,windowsHide:true});
  const gameDir=path.join(fixtureRoot,'fake-game');
  const target=path.join(gameDir,'resources/app/game/scripts/game.js');
  fs.mkdirSync(path.dirname(target),{recursive:true});
  fs.writeFileSync(target,original,'utf8');
  for(const file of ['install-clock-fix.ps1','clock-fix.cjs'])fs.copyFileSync(path.join(__dirname,file),path.join(fixtureRoot,file));
  const recordPath=path.join(fixtureRoot,'installation.json');
  const recordBefore=JSON.stringify({gameDir},null,2);
  fs.writeFileSync(recordPath,recordBefore,'utf8');
  t.after(()=>{
    run(readonlyScript,[recordPath,'off']);
    const safe=path.resolve(fixtureRoot);
    assert(safe.startsWith(workRoot+path.sep) && path.basename(safe).startsWith('clock-install-test-'));
    fs.rmSync(safe,{recursive:true,force:true});
  });
  const installScript=path.join(fixtureRoot,'install-clock-fix.ps1');
  assert.equal(run(readonlyScript,[recordPath,'on']).status,0);
  const readonly=run(installScript);
  assert.notEqual(readonly.status,0,'readonly state must not be reported as a successful installation');
  assert.equal(fs.readFileSync(target,'utf8'),original);
  assert.equal(fs.readFileSync(recordPath,'utf8'),recordBefore);
  assert.equal(run(readonlyScript,[recordPath,'off']).status,0);

  // Lock the record after the native source write, reproducing a late failure
  // without racing the filesystem or altering the production installer.
  const lateFailure=path.join(fixtureRoot,'late-failure.ps1');
  fs.writeFileSync(lateFailure,`param([string]$Installer,[string]$Record,[string]$NodeExe)
$global:sfFailureRecord=$Record
$global:sfNativeNode=$NodeExe
function global:node {
    param([Parameter(ValueFromRemainingArguments=$true)][object[]]$NodeArgs)
    & $global:sfNativeNode @NodeArgs
    $sfNativeExit=$LASTEXITCODE
    if ($sfNativeExit -eq 0 -and $NodeArgs[1] -eq 'install') { (Get-Item -LiteralPath $global:sfFailureRecord).IsReadOnly=$true }
    $global:LASTEXITCODE=$sfNativeExit
}
& $Installer
`);
  const failed=run(lateFailure,[installScript,recordPath,process.execPath]);
  assert.notEqual(failed.status,0,'late persistence failure must propagate');
  assert.equal(fs.readFileSync(target,'utf8'),original,'late persistence failure must restore the exact game source');
  assert.equal(fs.readFileSync(recordPath,'utf8'),recordBefore,'failed atomic record replacement must preserve prior state');
  const backupRoot=path.join(fixtureRoot,'backups');
  assert(fs.existsSync(backupRoot),'late failure must preserve its recovery backup');
  const backupDirectories=fs.readdirSync(backupRoot);
  assert.equal(backupDirectories.length,1);
  assert.equal(fs.readFileSync(path.join(backupRoot,backupDirectories[0],'game.js.original'),'utf8'),original);
});
