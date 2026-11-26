'use strict';

// Stringified into the game renderer. Only SFX are bounded; simulation and music
// keep their native methods and clocks. No global timers or AudioContext hooks.
function install(game, options = {}) {
  const key = Symbol.for('sixtyfour.agent.audioGuard.v1');
  if (!game || ['playSound', 'startSound', 'stopSound'].some(name => typeof game[name] !== 'function')) throw new TypeError('Expected native game audio methods');
  if (game[key]) throw new Error('Audio guard is already installed');
  const now = options.now ?? (() => performance.now());
  if (typeof now !== 'function') throw new TypeError('now must be a function');
  const maxVoices = options.maxVoices ?? 24;
  const maxPerSecond = options.maxPerSecond ?? 120;
  const maxPerSoundPerSecond = options.maxPerSoundPerSecond ?? 12;
  const maxFadeSeconds = options.maxFadeSeconds ?? 0.05;
  for (const [name, value] of Object.entries({ maxVoices, maxPerSecond, maxPerSoundPerSecond })) {
    if (!Number.isSafeInteger(value) || value < 1 || value > 4096) throw new RangeError(`${name} must be an integer from 1 to 4096`);
  }
  if (!Number.isFinite(maxFadeSeconds) || maxFadeSeconds <= 0 || maxFadeSeconds > 1) throw new RangeError('Invalid maxFadeSeconds');
  const names = ['playSound', 'startSound', 'stopSound', 'agentAudioStatus'];
  const descriptors = new Map(names.map(name => [name, Object.getOwnPropertyDescriptor(game, name)]));
  if (names.some(name => descriptors.get(name)?.configurable === false)) throw new TypeError('Audio methods must be configurable');
  const originals = { playSound: game.playSound, startSound: game.startSound, stopSound: game.stopSound };
  const voices = new Set();
  const bundles = new WeakMap();
  const contexts = new Map();
  let mode = 'bounded', acceleration = 1, installed = true, lastNow = -Infinity;
  let recent = [];
  const counts = { started: 0, dropped: 0, cleaned: 0, errors: 0, peakVoices: 0 };

  function clean(voice) {
    if (voice.cleaned) return;
    voice.cleaned = true;
    voices.delete(voice);
    if (voice.counted) {
      counts.cleaned++;
      if (!voice.loop && game.sfx) game.sfx.stackSize = Math.max(0, (game.sfx.stackSize || 0) - 1);
    }
    if (voice.listener && voice.source?.removeEventListener) voice.source.removeEventListener('ended', voice.listener);
    else if (voice.endedWrapper && voice.source?.onended === voice.endedWrapper) voice.source.onended = voice.oldEnded;
    for (const node of voice.nodes) { try { node.disconnect(); } catch {} }
  }
  function halt(voice) {
    if (voice.cleaned) return;
    try { voice.source?.stop(voice.context.currentTime); } catch {}
    clean(voice);
  }
  function observe(context) {
    if (contexts.has(context)) return;
    const listener = () => {
      if (context.state === 'closed') for (const voice of [...voices]) if (voice.context === context) halt(voice);
    };
    // Native AudioContext implements EventTarget; fake/legacy contexts may not.
    context.addEventListener?.('statechange', listener);
    contexts.set(context, listener);
  }
  function admit(id) {
    let time;
    try { time = now(); } catch { counts.errors++; counts.dropped++; return false; }
    if (!Number.isFinite(time) || time < lastNow) { counts.dropped++; return false; }
    lastNow = time;
    recent = recent.filter(event => time - event.time < 1000);
    if (voices.size >= maxVoices || recent.length >= maxPerSecond || recent.filter(event => event.id === id).length >= maxPerSoundPerSecond) {
      counts.dropped++; return false;
    }
    recent.push({ time, id });
    return true;
  }
  function create(id, panning, loudness, dark, loop) {
    const context = game.actx, sample = game.sfx?.samples?.[id];
    if (game.preventNoise || !game.sfx?.ready || !context || context.state === 'closed' || !sample?.data) return false;
    if (!admit(id)) return false;
    const voice = { context, nodes: [], loop, cleaned: false, counted: false };
    try {
      observe(context);
      if (!loop && context.state !== 'running') {
        const resumed = context.resume();
        resumed?.catch?.(() => { counts.errors++; halt(voice); });
      }
      const source = context.createBufferSource(); voice.source = source; voice.nodes.push(source);
      const volume = context.createGain(); voice.nodes.push(volume);
      const pan = context.createStereoPanner(); voice.nodes.push(pan);
      loudness = loudness === undefined ? 1 : loudness;
      pan.pan.value = panning || 0;
      volume.gain.value = sample.volume * loudness || 0.5 * loudness;
      source.buffer = sample.data;
      source.loop = loop;
      let detune = sample.detune ? (Math.random() * 2 - 1) * sample.detune : 0;
      if (!loop && game.slowdown?.state) detune += (game.slowdown.multiplyer < 1 ? -100 / game.slowdown.multiplyer : game.slowdown.multiplyer * 200) * game.slowdown.f;
      source.detune.value = detune;
      source.connect(pan); pan.connect(volume);
      if (loop || !game.plane || dark) volume.connect(game.sfx.master);
      else {
        const filter = context.createBiquadFilter(); voice.nodes.push(filter);
        filter.type = 'lowpass'; volume.connect(filter).connect(game.sfx.master);
      }
      const listener = () => clean(voice);
      if (source.addEventListener) { voice.listener = listener; source.addEventListener('ended', listener); }
      else {
        voice.oldEnded = source.onended;
        voice.endedWrapper = function (...args) { try { voice.oldEnded?.apply(this, args); } finally { listener(); } };
        source.onended = voice.endedWrapper;
      }
      voices.add(voice); voice.counted = true;
      counts.started++; counts.peakVoices = Math.max(counts.peakVoices, voices.size);
      if (!loop) game.sfx.stackSize = (game.sfx.stackSize || 0) + 1;
      source.start(context.currentTime);
      if (!loop) source.stop(context.currentTime + (sample.duration || source.buffer.duration));
      const bundle = { source, volume, pan, baseVolume: sample.volume || 0.5 };
      bundles.set(bundle, voice);
      return bundle;
    } catch {
      counts.errors++;
      halt(voice);
      return false;
    }
  }
  function playSound(...args) {
    if (mode === 'native' || !installed) return Reflect.apply(originals.playSound, this, args);
    if (mode !== 'silent') create(args[0], args[1], args[2], args[3], false);
  }
  function startSound(...args) {
    if (mode === 'native' || !installed) return Reflect.apply(originals.startSound, this, args);
    return mode === 'silent' ? false : create(args[0], args[1], args[2], false, true);
  }
  function stopSound(bundle, seconds) {
    const voice = bundle && bundles.get(bundle);
    if (!voice) return Reflect.apply(originals.stopSound, this, arguments);
    if (voice.cleaned || voice.stopping) return;
    voice.stopping = true;
    const requested = Number.isFinite(seconds) && seconds > 0 ? seconds : 1;
    const duration = acceleration > 1 ? Math.min(requested, maxFadeSeconds) : requested;
    try {
      const end = voice.context.currentTime + duration;
      bundle.volume.gain.exponentialRampToValueAtTime(0.01, end);
      bundle.source.stop(end);
    } catch { counts.errors++; halt(voice); }
  }
  function getStatus() {
    const context = game.actx;
    return { mode, acceleration, activeVoices: voices.size, ...counts, maxVoices, maxPerSecond, maxPerSoundPerSecond, maxFadeSeconds,
      context: context ? { state: context.state, currentTime: context.currentTime, sampleRate: context.sampleRate, baseLatency: context.baseLatency } : null,
      tracking: mode === 'native' ? 'guard-owned-only; native voices are not counted' : 'guard-owned-sfx; music is native' };
  }
  function setMode(value) {
    if (!['native', 'bounded', 'silent'].includes(value)) throw new TypeError('Invalid audio mode');
    if (mode !== value) { for (const voice of [...voices]) halt(voice); recent = []; mode = value; }
    return getStatus();
  }
  function setAcceleration(value) {
    if (!Number.isFinite(value) || value <= 0 || value > 1000) throw new RangeError('Invalid acceleration');
    acceleration = value;
  }
  const wrappers = { playSound, startSound, stopSound, agentAudioStatus: getStatus };
  function uninstall() {
    if (!installed) return;
    installed = false;
    for (const voice of [...voices]) halt(voice);
    for (const [context, listener] of contexts) context.removeEventListener?.('statechange', listener);
    contexts.clear();
    for (const name of names) if (game[name] === wrappers[name]) {
      const descriptor = descriptors.get(name);
      if (descriptor) Object.defineProperty(game, name, descriptor); else delete game[name];
    }
    if (game[key] === controller) delete game[key];
  }
  const controller = { getStatus, setMode, setAcceleration, uninstall };
  for (const name of names) Object.defineProperty(game, name, { configurable: true, writable: true, value: wrappers[name] });
  Object.defineProperty(game, key, { configurable: true, value: controller });
  return controller;
}

module.exports = { install };
