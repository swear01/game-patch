'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { install } = require('./simulation-clock.cjs');

function fixture(extraOptions = {}) {
  let real = 1000;
  let external = { enabled: false, factor: 100 };
  const spans = [];
  const acknowledgements = [];
  const native = function () { return 'original'; };
  const game = {
    time: { lt: 1000, dt: 0, realDt: 0 }, stats: { totalPlayTime: 0, totalPlayAndIdleTime: 0 },
    updateLoop: native,
    updateCycle(span) { spans.push(span); this.time.dt = span; this.time.realDt = span; this.stats.totalPlayAndIdleTime += span; return true; },
    clock: { postMessage(value) { acknowledgements.push(value); } },
  };
  const handle = install(game, { readRealNow: () => real, readSpeed: () => external, ...extraOptions });
  return { game, handle, spans, acknowledgements, native, real: value => { real = value; }, external: value => { external = value; }, tick: () => game.updateLoop() };
}

test('disabled speed is exactly1x despite stored100, enabled100 scales once and substeps at64ms', () => {
  const f = fixture();
  f.real(1010); f.tick();
  assert.equal(f.game.stats.totalPlayTime, 10);
  f.external({ enabled: true, factor: 100 });
  f.real(1020); f.tick();
  assert.equal(f.game.stats.totalPlayTime, 1010);
  assert.ok(f.spans.every(span => span <= 64 && span > 0));
  assert.equal(f.handle.state.virtualTime, 1010);
  assert.equal(f.game.time.lt, 1020, 'Real baseline must not become virtual time');
  assert.deepEqual(f.acknowledgements, [true, true]);
});

test('numeric speed also requires an explicit external enabled signal', () => {
  let enabled = false;
  const f = fixture({ readSpeed: () => 100, readEnabled: () => enabled });
  f.real(1005); f.tick();
  assert.equal(f.game.stats.totalPlayTime, 5);
  enabled = true; f.real(1010); f.tick();
  assert.equal(f.game.stats.totalPlayTime, 505);
  enabled = false; f.real(1015); f.tick();
  assert.equal(f.game.stats.totalPlayTime, 510);
});

test('controller defaults1x, accepts only enabled factors and fails closed after2000wall-ms', () => {
  let real = 1000;
  const game = { time:{lt:1000}, stats:{totalPlayTime:0}, updateLoop(){}, updateCycle(){return true;}, clock:{postMessage(){}} };
  const controller = install(game, {readRealNow:()=>real});
  real=1005;game.updateLoop();
  assert.equal(game.stats.totalPlayTime,5);
  controller.setState({enabled:false,factor:100});
  real=1010;game.updateLoop();
  assert.equal(game.stats.totalPlayTime,10);
  controller.setState({enabled:true,factor:100});
  real=1015;game.updateLoop();
  assert.equal(game.stats.totalPlayTime,510);
  assert.equal(game.agentSpeedStatus().factor,100);
  real=3011;game.updateLoop();
  assert.equal(controller.getStatus().expired,true);
  assert.equal(controller.getStatus().factor,1);
  assert.equal(controller.getStatus().scope,'dt-driven-simulation-only');
  const afterExpiry=game.stats.totalPlayTime;
  real=3016;game.updateLoop();
  assert.equal(game.stats.totalPlayTime-afterExpiry,5,'Helper expiry must immediately return future ticks to1x');
  controller.setState({enabled:true,factor:Infinity});
  real=3021;game.updateLoop();
  assert.equal(controller.getStatus().factor,1);
  assert.equal(controller.getStatus().enabled,false);
});

test('factory is self-contained when stringified and evaluated in the game realm', () => {
  let now=1000;
  const context=vm.createContext({performance:{now:()=>now}});
  const factory=vm.runInContext(`(${install.toString()})`,context);
  const g={time:{lt:1000},stats:{totalPlayTime:0},updateLoop(){},updateCycle(){return true;},clock:{postMessage(){}}};
  const controller=factory(g);
  controller.setState({enabled:true,factor:100});
  now=1005;g.updateLoop();
  assert.equal(g.stats.totalPlayTime,500);
  assert.equal(g.agentSpeedStatus().factor,100);
  now=3010;assert.equal(g.agentSpeedStatus().expired,true);
  controller.uninstall();
  assert.equal(g.agentSpeedStatus,undefined);
});

test('speed toggles keep virtual time continuous and discard stale accelerated backlog', () => {
  const f = fixture({ maxSteps: 1 });
  f.external({ enabled: true, factor: 100 });
  f.real(1010); f.tick();
  assert.equal(f.handle.state.virtualTime, 64);
  assert.equal(f.handle.state.backlogMs, 936);
  f.external({ enabled: false, factor: 100 });
  f.real(1015); f.tick();
  assert.equal(f.handle.state.virtualTime, 69);
  assert.equal(f.handle.state.backlogMs, 0);
  assert.equal(f.handle.state.droppedOnSpeedChangeMs, 936);
  f.external({ enabled: true, factor: 100 });
  f.real(1020); f.tick();
  assert.equal(f.handle.state.virtualTime, 133);
  assert.equal(f.game.time.lt, 1020);
});

test('nonfinite or reversed clocks and invalid speed samples never produce negative/nonfinite steps', () => {
  const f = fixture();
  for (const [now, sample] of [[1010, {enabled:true,factor:NaN}], [NaN, {enabled:true,factor:100}], [900, {enabled:true,factor:Infinity}], [905, {enabled:true,factor:0}], [910, {enabled:true,factor:-10}]]) {
    f.real(now); f.external(sample); f.tick();
    assert.ok(Number.isFinite(f.game.stats.totalPlayTime));
    assert.ok(Number.isFinite(f.game.time.lt));
    assert.ok(Number.isFinite(f.handle.state.backlogMs));
  }
  assert.ok(f.spans.every(span => Number.isFinite(span) && span > 0 && span <= 64));
  assert.equal(f.handle.state.rollbackSamples, 1);
  assert.equal(f.handle.state.invalidClockSamples, 1);
  assert.equal(f.acknowledgements.length, 5);
});

test('one real second backlog cap and step cap bound catch-up after a long stall', () => {
  const f = fixture({ maxSteps: 2 });
  f.external({ enabled: true, factor: 1000 });
  f.real(11000); f.tick();
  assert.equal(f.spans.length, 2);
  assert.equal(f.handle.state.virtualTime, 128);
  assert.ok(f.handle.state.backlogRealMs <= 1000);
  assert.equal(f.handle.state.droppedSimulationMs, 9000000);
  assert.equal(f.acknowledgements.length, 1);
});

test('wall CPU budget stops catch-up without advancing real clocks or discarding its backlog silently', () => {
  let real = 1000;
  const f = fixture({ readRealNow: () => real, maxWorkMs: 2 });
  f.game.updateCycle = span => { f.spans.push(span); real += 1; return true; };
  f.external({ enabled: true, factor: 100 });
  real = 1010; f.tick();
  assert.equal(f.spans.length, 2);
  assert.equal(f.handle.state.workBudgetHits, 1);
  assert.equal(f.handle.state.backlogMs, 872);
  assert.equal(f.handle.state.droppedSimulationMs, 0);
  assert.equal(f.acknowledgements.length, 1);
});

test('native update failure remains visible and ACK occurs exactly once despite partial progress', () => {
  const f = fixture();
  const failure = new Error('native update failed');
  f.game.updateCycle = () => { throw failure; };
  f.external({ enabled: true, factor: 100 });
  f.real(1010);
  assert.throws(f.tick, error => error === failure);
  assert.deepEqual(f.acknowledgements, [false]);
  assert.equal(f.game.stats.totalPlayTime, 64);
  assert.equal(f.handle.state.backlogMs, 936);
});

test('install never wraps native time twice and restores the exact original method descriptor', () => {
  const f = fixture();
  assert.throws(() => install(f.game), /already installed/);
  f.handle.uninstall();
  assert.equal(f.game.updateLoop, f.native);
  assert.equal(f.game.updateLoop(), 'original');
  f.handle.uninstall();
});

const recordPath = path.resolve(__dirname, '../../outputs/sixtyfour-agent/installation.json');
const record = fs.existsSync(recordPath) ? JSON.parse(fs.readFileSync(recordPath, 'utf8')) : null;
const gameSourcePath = process.env.SIXTYFOUR_GAME_JS || (record && path.join(record.gameDir, 'resources/app/game/scripts/game.js'));
test('untouched native updateCycle retains halted services, menu behavior and VFX completion callbacks', { skip: !(gameSourcePath && fs.existsSync(gameSourcePath)) }, () => {
  const context = vm.createContext({ performance: { now: () => 1000 } });
  vm.runInContext(fs.readFileSync(gameSourcePath, 'utf8'), context);
  const Game = vm.runInContext('Game', context);
  let real = 1000;
  const service = [];
  const entitySteps = [];
  let vfxCompleted = 0;
  const g = Object.create(Game.prototype);
  Object.assign(g, {
    time: {lt:1000,dt:0,realDt:0}, stats: {totalPlayTime:0,totalPlayAndIdleTime:0,timeSinceLastDelete:0},
    clock:{postMessage(){}}, halt:true, splash:{isShown:true}, entitiesInGame:{},
    messenger:{update:span=>service.push(['messenger',span])}, achiever:{update:span=>service.push(['achiever',span])},
    updateGamepad(span){service.push(['gamepad',span]);}, updateSlowdownEvent(){}, updateUnfilled(){},
    updateEntities(span){entitySteps.push(span);}, updateResourceInteractions(){},
    updateVFX(span){ this.effectRemaining = (this.effectRemaining ?? 120)-span; if(this.effectRemaining<=0&&!this.effectDone){this.effectDone=true;vfxCompleted++;} },
    updateHollowEvents(){}, updateResourcePops(){}, updateSurge(){}, updateAnalytics(){}, updateTranslation(){}, updateAutoClicker(){}, updateMusic(){},
  });
  install(g, {readRealNow:()=>real,readSpeed:()=>({enabled:true,factor:100})});
  real=1002;g.updateLoop();
  assert.equal(g.stats.totalPlayTime,200);
  assert.equal(g.stats.totalPlayAndIdleTime,200);
  assert.equal(entitySteps.length,0,'halt must suppress native in-game updates');
  assert.ok(service.length>0,'native menu/dialogue/achievement services still run before halt');
  g.halt=false;real=1004;g.updateLoop();
  assert.ok(entitySteps.length>0,'menu visibility alone must not introduce a new halt condition');
  assert.equal(vfxCompleted,1,'VFX completion callback must not be skipped during catch-up');
  assert.equal(g.stats.totalPlayTime,400);
  assert.equal(g.stats.totalPlayAndIdleTime,400);
  assert.ok(entitySteps.every(span=>span<=64));
});
