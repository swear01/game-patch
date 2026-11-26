'use strict';

// This function is stringified and evaluated in the game's renderer. Keep it self-contained.
module.exports = async function dispatch(command, args = {}) {
  const fail = (code, message) => {
    const error = new Error(message);
    error.code = code;
    throw error;
  };
  if (typeof game === 'undefined' || !game?.codex?.entities || !game.shop || !game.resources) {
    fail('NOT_READY', 'The game is still loading.');
  }
  const g = game;
  if (!args || typeof args !== 'object' || Array.isArray(args)) fail('BAD_ARGUMENT', 'Arguments must be an object.');
  const integer = (value, label, min, max) => {
    if (!Number.isSafeInteger(value) || value < min || value > max) {
      fail('BAD_ARGUMENT', `${label} must be an integer from ${min} to ${max}.`);
    }
    return value;
  };
  const position = () => [integer(args.x, 'x', -10000, 10000), integer(args.y, 'y', -10000, 10000)];
  const unlocked = (type) => Boolean(g.unlockedEntities[type] || g.codex.entities[type]?.shouldUnlock?.(g));
  const describe = (entity) => {
    if (!entity) return null;
    const result = { type: entity.name, x: entity.position[0], y: entity.position[1] };
    for (const key of ['state', 'fill', 'maxFill', 'conversion', 'depth', 'broken', 'breakPower', 'active', 'spoolup', 'pumpSpeed', 'online', 'soul', 'soulPower', 'entitySpan', 'indestructible', 'resourceCount', 'penalty']) {
      if (typeof entity[key] === 'number' || typeof entity[key] === 'boolean') result[key] = entity[key];
    }
    if (Array.isArray(entity.fuel)) result.fuel = [...entity.fuel];
    if (Array.isArray(entity.resources)) result.resources = [...entity.resources];
    if (Array.isArray(entity.composition)) result.composition = [...entity.composition];
    result.canInteract = Boolean((g.plane ? entity.canDarkHit?.() : entity.canHit?.()));
    return result;
  };
  const catalog = () => Object.entries(g.codex.entities).filter(([, item]) => item.canPurchase).map(([type, item]) => {
    const price = [...g.getRealPrice(type)];
    const placementSupported = Boolean(item.class) && !type.startsWith('eraser');
    return {
      type,
      name: g.pronounce('entities', type, 'name'),
      description: g.pronounce('entities', type, 'description'),
      price,
      materials: price.flatMap((amount, index) => amount === 0 ? [] : [{ index, name: g.codex.resources[index]?.name || `resource-${index}`, amount }]),
      placementSupported,
      unlocked: unlocked(type),
      affordable: g.canAfford(type),
      alreadyBuiltUnique: Boolean(g.onlyones[type]),
      dark: Boolean(item.isDark),
      upgradeFrom: item.isUpgradeTo || null,
      count: g.entitiesInGame[type] || 0,
      available: placementSupported && unlocked(type) && g.canAfford(type) && !g.onlyones[type] && Boolean(item.isDark) === Boolean(g.plane)
    };
  });
  const state = () => ({
    version: g.version,
    plane: g.plane,
    menuShown: Boolean(g.splash?.isShown),
    halted: Boolean(g.halt),
    savingDisabled: Boolean(g.preventSaving || g.preventCloud),
    resources: g.resources.map((amount, index) => ({ index, name: g.codex.resources[index]?.name || `resource-${index}`, amount })),
    entities: g.stuff.map(describe),
    counts: { ...g.entitiesInGame },
    eraserType: g.eraserType,
    stats: { ...g.stats },
    speed: typeof g.agentSpeedStatus === 'function' ? g.agentSpeedStatus() : null,
    audio: typeof g.agentAudioStatus === 'function' ? g.agentAudioStatus() : null,
    timing: { now: performance.now(), simulationLast: g.time?.lt, simulationDelta: g.time?.dt, renderLast: g.renderTime?.lt, renderDelta: g.renderTime?.dt, rollbackRecoveries: g.clockRollbackRecoveries || 0,
      clockFixActive: typeof g.renderloop === 'function' && Function.prototype.toString.call(g.renderloop).includes('// SIXTYFOUR_CLOCK_ROLLBACK_FIX_V1') },
    timestamp: Date.now()
  });
  const mutableKeys = ['itemInHand', 'itemInHandPriceTag', 'itemInHandPriceAndRefundTag', 'transportedEntity', 'hoveredCell', 'hoveredEntity', 'selectedEntity', 'canPlace'];
  const interactionKey = Symbol.for('sixtyfour.agent.activeInteraction.v1');
  const captureUI = () => mutableKeys.map((key) => [key, Object.hasOwn(g, key), g[key]]);
  const restoreUI = (saved) => {
    for (const [key, had, value] of saved) {
      const deadEntity = ['hoveredEntity', 'selectedEntity', 'transportedEntity'].includes(key) && value && !g.stuff.includes(value);
      if (had && !deadEntity) g[key] = value;
      else delete g[key];
    }
  };
  const release = (record) => {
    if (record.cleaned) return;
    record.cleaned = true;
    try {
      record.entity.onmouseup?.();
    } finally {
      try {
        if (record.updateDescriptor) Object.defineProperty(record.entity, 'update', record.updateDescriptor);
        else delete record.entity.update;
      } finally {
        restoreUI(record.savedUI);
      }
    }
  };
  const preserveUI = async (action) => {
    const saved = captureUI();
    try {
      delete g.transportedEntity;
      delete g.itemInHand;
      return await action();
    } finally {
      restoreUI(saved);
    }
  };
  const ensureWorld = () => {
    if (g.halt) fail('HALTED', 'The game is halted.');
    if (g.splash?.isShown) fail('MENU_OPEN', 'Close the menu with resume before performing actions.');
  };
  if (command === 'state') return state();
  if (command === 'catalog') return catalog();
  if (command === 'endInteraction' || command === 'releaseInteractions') {
    const record = g[interactionKey];
    if (!record) return { released: false, before: null, after: null, performed: 0, holdMs: 0 };
    if (command === 'endInteraction' && args.id !== record.id) fail('INTERACTION_ID', 'The active interaction belongs to another request.');
    try {
      release(record);
      return { released: true, before: record.before, after: g.stuff.includes(record.entity) ? describe(record.entity) : null, performed: record.performed, holdMs: record.holdMs };
    } finally {
      delete g[interactionKey];
    }
  }
  if (g[interactionKey]) fail('INTERACTION_ACTIVE', 'Finish the active interaction before another game command.');
  if (command === 'resume') {
    if (g.splash?.isShown) g.toggleSplash();
    return { menuShown: Boolean(g.splash?.isShown), halted: Boolean(g.halt) };
  }
  if (command === 'save') {
    if (g.preventSaving || g.preventCloud) fail('SAVE_DISABLED', 'The game has disabled saving at the current stage.');
    g.saveGame();
    const key = `abstractv03${g.steamId}`;
    const encodedSave = localStorage.getItem(key);
    if (!encodedSave) fail('SAVE_FAILED', 'The local save was not written.');
    return { saved: true, persisted: true, version: g.version, cloudWrite: 'requested', timestamp: Date.now(), ...(args.export === true ? { encodedSave, key } : {}) };
  }
  if (command === 'place') {
    ensureWorld();
    const p = position();
    const type = args.type;
    if (typeof type !== 'string' || !Object.hasOwn(g.codex.entities, type)) fail('BAD_ARGUMENT', 'Unknown machine type.');
    const item = g.codex.entities[type];
    if (!item.canPurchase || !item.class || type.startsWith('eraser')) fail('NOT_BUILDABLE', 'This type cannot be placed.');
    if (!unlocked(type)) fail('LOCKED', 'This machine has not been unlocked.');
    if (Boolean(item.isDark) !== Boolean(g.plane)) fail('WRONG_PLANE', 'This machine belongs to another plane.');
    if (g.onlyones[type]) fail('UNIQUE_EXISTS', 'This unique machine already exists.');
    if (!g.canAfford(type)) fail('INSUFFICIENT_RESOURCES', 'There are not enough resources for this machine.');
    const existing = g.entityAtCoordinates(p);
    if (existing && item.isUpgradeTo !== existing.name) fail('OCCUPIED', 'The target cell is occupied by an incompatible entity.');
    if (!existing && item.isUpgradeTo && (g.codex.entities[item.isUpgradeTo]?.onlyone || ['flower', 'fruit', 'gradient_rem'].includes(type))) {
      fail('UPGRADE_TARGET_REQUIRED', 'This upgrade requires its existing base machine.');
    }
    return preserveUI(async () => {
      g.pickupItem(type);
      const span = g.itemInHand.entitySpan || 0;
      for (let dy = -span; dy <= span; dy++) {
        for (let dx = -span; dx <= span; dx++) {
          const occupant = g.entityAtCoordinates([p[0] + dx, p[1] + dy]);
          if (occupant && occupant !== existing) fail('OCCUPIED', 'The machine footprint overlaps another entity.');
        }
      }
      const price = [...g.getRealPrice(type)];
      g.hoveredCell = p;
      g.hoveredEntity = existing;
      g.processClick();
      const placed = g.entityAtCoordinates(p);
      if (!placed || placed === existing || placed.name !== type) fail('PLACE_FAILED', 'The game rejected placement.');
      return { placed: describe(placed), upgradedFrom: existing?.name || null, price };
    });
  }
  if (command === 'remove') {
    ensureWorld();
    if (g.plane) fail('WRONG_PLANE', 'Recycling is available on the normal plane.');
    const p = position();
    const existing = g.entityAtCoordinates(p);
    if (!existing) fail('NOT_FOUND', 'There is no entity at that cell.');
    const eraser = g.eraserType === 1 ? 'eraser2' : g.eraserType === 2 ? 'eraser3' : 'eraser';
    if (!unlocked(eraser)) fail('LOCKED', 'Recycling has not been unlocked.');
    return preserveUI(async () => {
      g.hoveredCell = [...existing.position];
      g.hoveredEntity = existing;
      if (!g.canEraseNow()) fail('CANNOT_REMOVE', 'The target is protected, is a cube, is the last excavator, or recycling cannot be afforded.');
      const removed = describe(existing);
      const refund = [...g.getRealPrice(existing.name, true)];
      const price = [...g.getRealPrice(eraser)];
      g.pickupItem(eraser);
      g.processClick();
      if (g.stuff.includes(existing)) fail('REMOVE_FAILED', 'The game rejected recycling.');
      return { removed, price, refund, refundPendingAnimation: true };
    });
  }
  if (command === 'interact' || command === 'beginInteraction') {
    ensureWorld();
    const p = position();
    const count = integer(args.count ?? 1, 'count', 1, 1);
    const duration = integer(args.holdMs ?? 0, 'holdMs', 0, 5000);
    if (command === 'interact' && duration) fail('BAD_ARGUMENT', 'Hold and repeated-click timing must be managed by the external gateway.');
    if (command === 'beginInteraction' && (typeof args.id !== 'string' || !args.id || args.id.length > 128)) fail('BAD_ARGUMENT', 'An internal interaction id is required.');
    const entity = g.entityAtCoordinates(p);
    let targetId;
    if (command === 'interact') {
      // The external gateway carries this private token between paced clicks.
      // A WeakMap binds an object, so a new cube at the same coordinates cannot inherit it.
      const targetsKey = Symbol.for('sixtyfour.agent.targetIds.v1');
      const targets = g[targetsKey] ||= { ids: new WeakMap(), next: 1 };
      if (args.targetId !== undefined) {
        if (typeof args.targetId !== 'string' || !args.targetId || args.targetId.length > 128) fail('BAD_ARGUMENT', 'Invalid internal target id.');
        if (!entity || targets.ids.get(entity) !== args.targetId) fail('TARGET_CHANGED', 'The original interaction target is no longer at that cell.');
      }
      if (entity) {
        targetId = targets.ids.get(entity);
        if (!targetId) {
          targetId = `target-${targets.next++}`;
          targets.ids.set(entity, targetId);
        }
      }
    }
    if (!entity) fail('NOT_FOUND', 'There is no entity at that cell.');
    const callback = g.plane ? 'ondarkmousedown' : 'onmousedown';
    if (typeof entity[callback] !== 'function') fail('CANNOT_INTERACT', 'This entity has no interaction on the current plane.');
    if (!(g.plane ? entity.canDarkHit?.() : entity.canHit?.())) fail('CANNOT_INTERACT', 'This entity cannot currently be interacted with.');
    if (g.plane && command === 'beginInteraction') fail('BAD_ARGUMENT', 'Hold interactions are supported on the normal plane.');
    if (command === 'beginInteraction') {
      const record = {
        id: args.id, entity, before: describe(entity), performed: 0, holdMs: duration,
        savedUI: captureUI(), updateDescriptor: Object.getOwnPropertyDescriptor(entity, 'update'), cleaned: false
      };
      const nativeUpdate = entity.update;
      g[interactionKey] = record;
      try {
        delete g.transportedEntity;
        delete g.itemInHand;
        g.hoveredCell = [...entity.position];
        g.hoveredEntity = entity;
        g.selectedEntity = entity;
        if (typeof nativeUpdate === 'function') {
          Object.defineProperty(entity, 'update', { configurable: true, writable: true, value: function (...updateArgs) {
            if (g.halt || g.splash?.isShown || !g.stuff.includes(entity)) {
              release(record);
              return nativeUpdate.apply(this, updateArgs);
            }
            g.hoveredEntity = entity;
            try {
              return nativeUpdate.apply(this, updateArgs);
            } catch (error) {
              try { release(record); } catch (cleanupError) {
                throw new AggregateError([error, cleanupError], `${error.message}; release failed: ${cleanupError.message}`);
              }
              throw error;
            }
          } });
        }
        if (entity.name === 'cube') g.stats.totalCubeClicks++;
        entity.onmousedown();
        record.performed = 1;
        return { before: record.before, performed: 1, holdMs: duration };
      } catch (error) {
        try { release(record); } catch (cleanupError) {
          throw new AggregateError([error, cleanupError], `${error.message}; release failed: ${cleanupError.message}`);
        } finally {
          delete g[interactionKey];
        }
        throw error;
      }
    }
    return preserveUI(async () => {
      const before = describe(entity);
      g.hoveredCell = [...entity.position];
      g.hoveredEntity = entity;
      g.selectedEntity = entity;
      try {
        if (entity.name === 'cube' && !g.plane) g.stats.totalCubeClicks++;
        entity[callback]();
      } finally {
        if (!g.plane) entity.onmouseup?.();
      }
      return { before, after: g.stuff.includes(entity) ? describe(entity) : null, performed: count, holdMs: 0, targetId };
    });
  }
  fail('UNKNOWN_COMMAND', 'Unknown game command.');
};
