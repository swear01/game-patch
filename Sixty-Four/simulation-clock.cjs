'use strict';

// EXPERIMENT ONLY: this is not an OpenSpeedy hook or a native-clock bypass.
// Install only when readRealNow really is unmodified monotonic wall time and
// native scheduling is confirmed1x. No global clocks, timers or render methods
// are changed. Existing performance.now-based game behavior is not virtualized.
function install(game, options = {}) {
  if (!game?.time || !game?.stats || typeof game.updateLoop !== 'function' || typeof game.updateCycle !== 'function') {
    throw new TypeError('Expected a Sixty Four Game instance with its native update methods');
  }
  const key = Symbol.for('sixtyfour.experimental.simulationClock.v1');
  if (game[key]) throw new Error('The experimental simulation clock is already installed');
  const readRealNow = options.readRealNow || performance.now.bind(performance);
  const readSpeed = options.readSpeed;
  const readEnabled = options.readEnabled || (() => false);
  let useController = typeof readSpeed !== 'function';
  let requested = { enabled: false, factor: 1 };
  const stateTtlMs = 2000;
  const maxStepMs = options.maxStepMs ?? 64;
  const maxSteps = options.maxSteps ?? 64;
  const maxWorkMs = options.maxWorkMs ?? 4;
  const maxBacklogRealMs = options.maxBacklogRealMs ?? 1000;
  for (const [name, value, maximum] of [
    ['maxStepMs', maxStepMs, 64], ['maxSteps', maxSteps, 4096],
    ['maxWorkMs', maxWorkMs, 1000], ['maxBacklogRealMs', maxBacklogRealMs, 1000],
  ]) {
    if (!Number.isFinite(value) || value <= 0 || value > maximum || (name === 'maxSteps' && !Number.isInteger(value))) {
      throw new RangeError(`${name} must be positive and at most${maximum}`);
    }
  }
  const descriptor = Object.getOwnPropertyDescriptor(game, 'updateLoop');
  const statusDescriptor = Object.getOwnPropertyDescriptor(game, 'agentSpeedStatus');
  if (descriptor?.configurable === false || statusDescriptor?.configurable === false) throw new Error('The experimental methods must be configurable');
  const originalUpdateLoop = game.updateLoop;
  let lastReal = readRealNow();
  if (!Number.isFinite(lastReal)) lastReal = null;
  let lastStateAt = lastReal;
  let lastFactor = 1;
  let backlog = 0;
  let installed = true;
  const state = {
    experimental: true, clock: 'wall', source: 'external-speed-sample', scope: 'dt-driven-simulation-only', enabled: false, factor: 1,
    virtualTime: 0, simulatedMs: 0, backlogMs: 0, backlogRealMs: 0,
    droppedSimulationMs: 0, droppedRealMs: 0, droppedOnSpeedChangeMs: 0,
    rollbackSamples: 0, invalidClockSamples: 0, invalidSpeedSamples: 0,
    ticks: 0, cycles: 0, lastSteps: 0, workBudgetHits: 0,
  };
  const safeAdd = (before, value) => Math.min(Number.MAX_SAFE_INTEGER, before + Math.max(0, value));
  function controllerSample(now) {
    const age = Number.isFinite(now) && Number.isFinite(lastStateAt) && now >= lastStateAt ? now - lastStateAt : null;
    const expired = age === null || age > stateTtlMs;
    return { enabled: !expired && requested.enabled, factor: !expired && requested.enabled ? requested.factor : 1, expired, stateAgeMs: age };
  }
  function getStatus() {
    const current = useController ? controllerSample(readRealNow()) : { enabled: state.enabled, factor: state.factor, expired: false, stateAgeMs: null };
    return { ...state, ...current, authority: useController ? 'controller' : 'reader', stateTtlMs, lastStateAt, requestedEnabled: requested.enabled, requestedFactor: requested.factor, installed };
  }
  function speed(now) {
    const sample = useController ? controllerSample(now) : readSpeed();
    const object = sample && typeof sample === 'object';
    const enabled = object ? sample.enabled === true : readEnabled() === true;
    const requested = object ? sample.factor : sample;
    // A stored factor is never itself evidence that acceleration is enabled.
    if (!enabled) return { enabled: false, factor: 1 };
    if (!Number.isFinite(requested) || requested < 0.001 || requested > 1000) {
      state.invalidSpeedSamples++;
      return { enabled: true, factor: 1 };
    }
    return { enabled: true, factor: requested };
  }
  function discard(amount, factor, speedChange = false) {
    state.droppedSimulationMs = safeAdd(state.droppedSimulationMs, amount);
    state.droppedRealMs = safeAdd(state.droppedRealMs, amount / factor);
    if (speedChange) state.droppedOnSpeedChangeMs = safeAdd(state.droppedOnSpeedChangeMs, amount);
  }
  function experimentalUpdateLoop() {
    if (!installed) return originalUpdateLoop.call(this);
    let done = true;
    let failure;
    state.ticks++;
    state.lastSteps = 0;
    try {
      const now = readRealNow();
      const sampled = speed(now);
      state.enabled = sampled.enabled;
      state.factor = sampled.factor;
      // Pending accelerated work must not continue after disabling/changing
      // speed. Discard it explicitly, without jumping the virtual clock.
      if (sampled.factor !== lastFactor) { discard(backlog, lastFactor, true); backlog = 0; }
      lastFactor = sampled.factor;
      let elapsed = 0;
      if (!Number.isFinite(now)) state.invalidClockSamples++;
      else {
        if (lastReal !== null) {
          if (now < lastReal) state.rollbackSamples++;
          else elapsed = now - lastReal;
        }
        lastReal = now;
        game.time.lt = now; // Real baseline: compatible with native render checks.
      }
      // Bound unprocessed credit to one real second even after a long stall.
      const admittedReal = Math.min(elapsed, maxBacklogRealMs);
      if (elapsed > admittedReal) discard((elapsed - admittedReal) * sampled.factor, sampled.factor);
      backlog += admittedReal * sampled.factor;
      const limit = maxBacklogRealMs * sampled.factor;
      if (backlog > limit) { discard(backlog - limit, sampled.factor); backlog = limit; }
      const started = now;
      while (backlog > 1e-9 && state.lastSteps < maxSteps) {
        if (state.lastSteps) {
          const current = readRealNow();
          if (Number.isFinite(current) && Number.isFinite(started) && current - started >= maxWorkMs) {
            state.workBudgetHits++;
            break;
          }
        }
        const span = Math.min(maxStepMs, backlog);
        backlog = Math.max(0, backlog - span);
        // Native updateLoop increments playtime before updateCycle, including
        // halted/menu/service ticks. Keep the untouched native updateCycle so
        // its services, slowdown logic and VFX completion callbacks still run.
        game.stats.totalPlayTime += span;
        state.virtualTime = safeAdd(state.virtualTime, span);
        state.simulatedMs = state.virtualTime;
        state.cycles++;
        state.lastSteps++;
        done = game.updateCycle(span);
      }
      return done;
    } catch (error) {
      done = false;
      failure = error;
      throw error;
    } finally {
      state.backlogMs = backlog;
      state.backlogRealMs = backlog / lastFactor;
      // The Worker posts once then waits for an acknowledgement. Repeated
      // substeps never generate extra ACKs, and native exceptions stay visible.
      try { game.clock?.postMessage(done); }
      catch (ackError) {
        if (failure) throw new AggregateError([failure, ackError], 'Native simulation and Worker acknowledgement both failed');
        throw ackError;
      }
    }
  }
  Object.defineProperty(game, 'updateLoop', { configurable: true, writable: true, value: experimentalUpdateLoop });
  const handle = {
    state,
    getStatus,
    setState(sample) {
      useController = true;
      const enabled = sample?.enabled === true;
      const factor = sample?.factor;
      if (enabled && (!Number.isFinite(factor) || factor < 0.001 || factor > 1000)) {
        state.invalidSpeedSamples++;
        requested = { enabled: false, factor: 1 };
      } else requested = { enabled, factor: enabled ? factor : 1 };
      const now = readRealNow();
      lastStateAt = Number.isFinite(now) ? now : null;
      return getStatus();
    },
    uninstall() {
      if (!installed) return;
      if (game.updateLoop !== experimentalUpdateLoop) throw new Error('Another component replaced updateLoop; preserve and inspect before restoring');
      installed = false;
      if (descriptor) Object.defineProperty(game, 'updateLoop', descriptor);
      else delete game.updateLoop;
      if (game.agentSpeedStatus === getStatus) {
        if (statusDescriptor) Object.defineProperty(game, 'agentSpeedStatus', statusDescriptor);
        else delete game.agentSpeedStatus;
      }
      delete game[key];
    },
  };
  Object.defineProperty(game, 'agentSpeedStatus', { configurable: true, writable: true, value: getStatus });
  Object.defineProperty(game, key, { configurable: true, value: handle });
  return handle;
}

module.exports = { install };
