// The stock Dodge movement event calls this before resolving manual controls.
_MinutescapePatrolInput() {
    if (this._minutescapePatrol) return;
    const state = this._minutescapePatrol = { enabled: true, route: null };
    globalThis.addEventListener("keydown", event => {
        if (event.code !== "F8" || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
        event.preventDefault();
        if (event.repeat) return;
        state.enabled = !state.enabled;
        const route = state.route;
        const live = this.GetObjectClassBySID(971355649700802)?.GetInstances()[0];
        if (route && route.player === live) route.move._Stop();
        state.route = null;
    }, true);
}

_MinutescapePatrolMove() {
    const state = this._minutescapePatrol;
    const layout = this.GetMainRunningLayout();
    if (!state?.enabled || layout?.GetName() !== "Dodge") return false;
    const variables = this.GetEventSheetManager();
    const hp = variables.GetEventVariableBySID(144141474833536);
    if (!(hp?.GetValue() > 0)) {
        state.route = null;
        return false;
    }
    const player = this.GetObjectClassBySID(971355649700802)?.GetInstances()[0];
    const move = player?.GetBehaviorSdkInstanceFromCtor(C3.Behaviors.MoveTo);
    if (!move) return false;

    const world = player.GetWorldInfo();
    const x = world.GetX(), y = world.GetY();
    const challenge = variables.GetEventVariableBySID(530499771236373)?.GetValue();
    if (challenge === "stuck") {
        // The challenge fixes the player's position. Evaluate threats at that
        // position and leave every move command to the stock events.
        let route = state.route;
        if (route?.player !== player || route.challenge !== challenge) {
            if (route?.player === player) route.move._Stop();
            route = state.route = { player, move, challenge };
        }
        this._MinutescapeAutoSkillsState(route);
        this._MinutescapeAvoidanceTarget(route, world, x, y, x, y, x, x, y, y);
        return false;
    }
    let left = 0, right = layout.GetWidth(), top = 0, bottom = layout.GetHeight();
    const walls = this.GetObjectClassBySID(253185647818588)?.GetInstances() ?? [];
    for (const wall of walls) {
        const pos = wall.GetWorldInfo();
        switch (wall.GetInstanceVariableValue(0)) {
            case "left": left = Math.max(left, pos.GetX() + 2.5); break;
            case "right": right = Math.min(right, pos.GetX() - 2.5); break;
            case "up": top = Math.max(top, pos.GetY() + 2.5); break;
            case "down": bottom = Math.min(bottom, pos.GetY() - 2.5); break;
        }
    }
    const margin = walls.length ? 18 : challenge === "fragile" ? 145 : 50;
    const insetX = Math.abs(world.GetWidth()) / 2 + margin;
    const insetY = Math.abs(world.GetHeight()) / 2 + margin;
    left += insetX;
    right -= insetX;
    top += insetY;
    bottom -= insetY;
    if (!(right - left > 12 && bottom - top > 12)) {
        // For a transient narrow box, use the stock controls instead of targeting through a wall.
        if (state.route?.player === player) state.route.move._Stop();
        state.route = null;
        return false;
    }

    let route = state.route;
    if (route?.player !== player || route.challenge !== challenge) {
        const distances = [Math.abs(y - top), Math.abs(x - right), Math.abs(y - bottom), Math.abs(x - left)];
        const edge = distances.indexOf(Math.min(...distances));
        route = state.route = { player, move, challenge, edge, joining: true };
    }

    const cut = Math.min(walls.length ? 70 : challenge === "fragile" ? 190 : 145,
        (right - left) / 5, (bottom - top) / 5);
    let tx = route.edge === 1 ? right : route.edge === 3 ? left : C3.clamp(x, left + cut, right - cut);
    let ty = route.edge === 0 ? top : route.edge === 2 ? bottom : C3.clamp(y, top + cut, bottom - cut);
    const distanceToSide = Math.hypot(tx - x, ty - y);
    if (!route.turning) {
        // Rejoin the same side after a resize or dodge, then resume the lap.
        route.joining = distanceToSide > (route.joining ? 4 : 8);
        if (!route.joining) {
            if (route.edge === 0) tx = right - cut;
            if (route.edge === 1) ty = bottom - cut;
            if (route.edge === 2) tx = left + cut;
            if (route.edge === 3) ty = top + cut;
            if (Math.hypot(tx - x, ty - y) <= 4) {
                route.edge = (route.edge + 1) % 4;
                route.turning = true;
            }
        }
    }
    if (route.turning) {
        tx = route.edge === 1 ? right : route.edge === 3 ? left : route.edge === 0 ? left + cut : right - cut;
        ty = route.edge === 0 ? top : route.edge === 2 ? bottom : route.edge === 1 ? top + cut : bottom - cut;
        if (Math.hypot(tx - x, ty - y) <= 4) route.turning = false;
    }
    this._MinutescapeAutoSkillsState(route);
    const dodge = this._MinutescapeAvoidanceTarget(route, world, x, y, tx, ty, left, right, top, bottom, cut);
    move._SetEnabled(true);
    move._AddWaypoint(dodge?.[0] ?? tx, dodge?.[1] ?? ty, true);
    return true;
}

_MinutescapeAvoidanceTarget(route, world, x, y, tx, ty, left, right, top, bottom, cut = 0) {
    const stuck = route.challenge === "stuck";
    const speed = stuck ? 0 : route.move._GetMaxSpeed() * route.player.GetActiveTimeScale();
    if (!(speed > 0) && !stuck) return null;
    const fragile = route.challenge === "fragile";
    const variables = this.GetEventSheetManager();
    const value = sid => variables.GetEventVariableBySID(sid)?.GetValue();
    const waveDuration = value(719031418869378) || 1;
    const timeScale = Math.max(0.1, this.GetTimeScale());
    const horizon = stuck ? Math.min(1.3, Math.max(0.3, (waveDuration + 0.18) / timeScale))
        : fragile ? 0.48 : 0.30;
    const isInside = ([px, py]) => px >= left && px <= right && py >= top && py <= bottom
        && Math.min(px - left, right - px) + Math.min(py - top, bottom - py) >= cut - 0.01;
    const safePoint = (px, py) => {
        px = C3.clamp(px, left, right);
        py = C3.clamp(py, top, bottom);
        const dx = Math.min(px - left, right - px);
        const dy = Math.min(py - top, bottom - py);
        const shift = Math.max(0, cut - dx - dy) / 2;
        return [px + (px - left === dx ? shift : -shift), py + (py - top === dy ? shift : -shift)];
    };
    const now = this.GetWallTime();
    const state = route.avoidance ??= { next: -1, target: null, previous: new WeakMap() };
    if (now < state.next) {
        const target = state.target;
        if (target && isInside(target)) return target;
        if (!target) return null;
    }
    state.next = now + (fragile ? 0.045 : 0.075);
    state.target = null;
    const skills = this._MinutescapeAutoSkillsState(route);
    skills.until.shrink = -1;
    // Let the short slow request expire naturally; its own effect can make the
    // next scan look safe and must not cause one-step on/off oscillation.
    const shieldElapsed = this.GetGameTime() - skills.shieldStarted;
    const shieldPrepaid = skills.shieldStarted != null && shieldElapsed >= 0 && shieldElapsed < 0.4;
    if (!shieldPrepaid) skills.until.shield = -1;

    const bulletClass = this.GetObjectClassBySID(591906528573192); // spr_bullet
    const boltClass = this.GetObjectClassBySID(563331159900904);   // active boss zap
    if (!bulletClass?.GetInstances().length && !boltClass?.GetInstances().length) return null;
    const actualScale = route.player.GetInstanceVariableValue(2);
    const normalScale = value(885360507674149);
    // Always compare the ordinary hitbox, even while the stock skill has shrunk it.
    const normalRatio = actualScale > 0 && normalScale > 0 ? normalScale / actualScale : 1;
    const normalHalfX = Math.abs(world.GetWidth()) * normalRatio / 2;
    const normalHalfY = Math.abs(world.GetHeight()) * normalRatio / 2;
    const halfX = normalHalfX + (fragile ? 12 : 6);
    const halfY = normalHalfY + (fragile ? 12 : 6);
    const travel = speed * horizon;
    const waveRange = value(118725652480139);
    const bulletSpeed = value(315580249027156) || 0;
    const projectileSpeed = Math.max(1000, 2.5 * bulletSpeed * this.GetTimeScale());
    const reach = Math.max(travel + projectileSpeed * horizon + Math.max(halfX, halfY) + 90,
        Number.isFinite(waveRange) ? waveRange : 0);
    let waveThreats = 0;
    let blueLaunches;
    const blueLaunchDelay = bullet => {
        if (!blueLaunches) {
            blueLaunches = new Map();
            for (const wait of variables.scheduledWaits?.() ?? []) {
                if (wait._event?.GetSID() !== 935658439976762 || !Number.isFinite(wait._time)) continue;
                for (const instance of wait._sols?.get(bulletClass)?._instances ?? []) {
                    blueLaunches.set(instance, Math.min(blueLaunches.get(instance) ?? Infinity, wait._time));
                }
            }
        }
        const until = (blueLaunches.get(bullet) ?? this.GetGameTime() + 0.75) - this.GetGameTime();
        return Math.max(0, until) / Math.max(0.01, this.GetTimeScale());
    };
    const rect = state.rect ??= C3.New(C3.Rect);
    rect.set(x - reach, y - reach, x + reach, y + reach);
    const instances = state.instances ??= [];
    const seen = state.seen ??= new Set();
    const risks = [];
    const collision = this.GetCollisionEngine();
    const collect = (objectClass, zap) => {
        if (!objectClass?.GetInstances().length) return;
        instances.length = 0;
        seen.clear();
        collision.GetCollisionCandidates(world.GetLayer(), objectClass, rect, instances);
        // A projectile can occupy more than one grid cell; visit it once.
        for (let i = 0; i < instances.length && i < 256 && seen.size < 128; ++i) {
            const bullet = instances[i];
            if (seen.has(bullet)) continue;
            seen.add(bullet);
            const info = bullet.GetWorldInfo();
            if (!info.IsCollisionEnabled() || (zap && !info.IsVisible())) continue;
            const animation = zap ? null : bullet.GetSdkInstance()._GetCurrentAnimationName();
            if (animation === "Green") continue;
            const priority = animation === "Purple" || animation === "Blue";
            const box = info.GetBoundingBox();
            const bx = (box.getLeft() + box.getRight()) / 2;
            const by = (box.getTop() + box.getBottom()) / 2;
            const rx = halfX + (box.getRight() - box.getLeft()) / 2;
            const ry = halfY + (box.getBottom() - box.getTop()) / 2;
            let vx = 0, vy = 0, turnRate = 0, launchDelay = 0;
            if (!zap) {
                const behavior = bullet.GetBehaviorSdkInstanceFromCtor(C3.Behaviors.Bullet);
                const scale = bullet.GetActiveTimeScale();
                vx = (behavior?._dx ?? 0) * scale;
                vy = (behavior?._dy ?? 0) * scale;
                if (animation === "Purple") {
                    turnRate = (25 * Math.PI / 180) * (bulletSpeed / 400) * scale;
                }
                if (animation === "Blue" && bullet.GetInstanceVariableValue(0) >= 2
                    && Math.hypot(vx, vy) < 1 && bulletSpeed > 0) {
                    // Stage 1 still tracks the player; only the locked phase has
                    // a fixed launch ray. Fired shots already expose real vx/vy.
                    launchDelay = blueLaunchDelay(bullet);
                    const angle = vx || vy ? Math.atan2(vy, vx) : info.GetAngle();
                    vx = Math.cos(angle) * 2.5 * bulletSpeed * scale;
                    vy = Math.sin(angle) * 2.5 * bulletSpeed * scale;
                }
                // Helix hazards are also positioned by event-sheet actions.
                if (!behavior || bullet.GetInstanceVariableValue(2) === "helix") {
                    const previous = state.previous.get(bullet);
                    if (previous) {
                        const elapsed = now - previous.time;
                        if (elapsed > 0 && elapsed <= 0.25) {
                            vx = (bx - previous.x) / elapsed;
                            vy = (by - previous.y) / elapsed;
                        }
                        previous.x = bx;
                        previous.y = by;
                        previous.time = now;
                    } else state.previous.set(bullet, { x: bx, y: by, time: now });
                }
            }
            const dx = bx - x, dy = by - y;
            if (!zap && Math.hypot(dx, dy) <= waveRange && dx * vx + dy * vy <= 0) ++waveThreats;
            // Cull hazards outside all positions the player and projectile can reach.
            const flight = Math.max(0, horizon - launchDelay);
            const nearX = Math.max(0, Math.min(dx, dx + vx * flight), -Math.max(dx, dx + vx * flight));
            const nearY = Math.max(0, Math.min(dy, dy + vy * flight), -Math.max(dy, dy + vy * flight));
            const curveReach = Math.hypot(vx, vy) * turnRate * horizon ** 2 / 2;
            if (nearX > rx + travel + curveReach || nearY > ry + travel + curveReach) continue;
            const separation = Math.hypot(Math.max(0, Math.abs(dx) - rx), Math.max(0, Math.abs(dy) - ry));
            const rank = launchDelay + separation / Math.max(1, speed + Math.hypot(vx, vy));
            risks.push({ dx, dy, vx, vy, rx, ry, rank, zap, priority, turnRate, launchDelay, animation });
        }
        instances.length = 0;
        seen.clear();
    };
    collect(bulletClass, false);
    collect(boltClass, true);
    const hasShield = this._MinutescapeSkillSlot("shield", true);
    if (!hasShield) this._MinutescapeAutoWavePlan(route, waveThreats);
    if (!risks.length) return null;
    risks.sort((a, b) => Number(b.priority) - Number(a.priority) || a.rank - b.rank);
    risks.length = Math.min(risks.length, fragile ? 24 : 12);

    // Look for a swept overlap of the two bounding boxes. Prefer paths which
    // avoid an overlap, then those with later and shorter exposure.
    const segmentCost = (dx, dy, vx, vy, rx, ry, seconds, offset) => {
        let enter = 0, exit = seconds;
        if (Math.abs(vx) < 0.001) {
            if (Math.abs(dx) > rx) return 0;
        } else {
            const a = (-rx - dx) / vx, b = (rx - dx) / vx;
            enter = Math.max(enter, Math.min(a, b));
            exit = Math.min(exit, Math.max(a, b));
        }
        if (Math.abs(vy) < 0.001) {
            if (Math.abs(dy) > ry) return 0;
        } else {
            const a = (-ry - dy) / vy, b = (ry - dy) / vy;
            enter = Math.max(enter, Math.min(a, b));
            exit = Math.min(exit, Math.max(a, b));
        }
        if (enter > exit) return 0;
        return 1 + (horizon - offset - enter + 3 * (exit - enter)) / horizon;
    };
    const linearCost = (dx, dy, vx, vy, mx, my, moving, limit, rx, ry, delay = 0) => {
        // Split on player arrival and projectile launch; neither velocity can
        // be applied for the whole interval when a locked Blue has not fired.
        let danger = 0;
        for (let t = 0; t < limit - 0.0001;) {
            const movingNow = t < moving - 0.0001;
            const flying = t >= delay - 0.0001;
            const end = Math.min(limit, movingNow ? moving : Infinity, flying ? Infinity : delay);
            const relX = (flying ? vx : 0) - (movingNow ? mx : 0);
            const relY = (flying ? vy : 0) - (movingNow ? my : 0);
            const step = end - t;
            danger = Math.max(danger, segmentCost(dx, dy, relX, relY, rx, ry, step, t));
            dx += relX * step;
            dy += relY * step;
            t = end;
        }
        return danger;
    };
    const pursuitCost = (threat, mx, my, moving, limit, rx, ry, ratio = 1) => {
        // Step the Purple turn toward each proposed player path. An inflated
        // straight-line hitbox would wrongly mark every nearby escape as unsafe.
        let { dx, dy } = threat;
        let angle = Math.atan2(threat.vy, threat.vx);
        const velocity = Math.hypot(threat.vx, threat.vy) * ratio;
        let danger = 0;
        for (let t = 0; t < limit - 0.0001;) {
            const movingNow = t < moving - 0.0001;
            const step = Math.min(0.06, limit - t, movingNow ? moving - t : Infinity);
            let turn = Math.atan2(-dy, -dx) - angle;
            if (turn > Math.PI) turn -= 2 * Math.PI;
            if (turn < -Math.PI) turn += 2 * Math.PI;
            const cap = threat.turnRate * ratio * step;
            angle += C3.clamp(turn, -cap, cap);
            if (angle > Math.PI) angle -= 2 * Math.PI;
            if (angle < -Math.PI) angle += 2 * Math.PI;
            const vx = Math.cos(angle) * velocity - (movingNow ? mx : 0);
            const vy = Math.sin(angle) * velocity - (movingNow ? my : 0);
            danger = Math.max(danger, segmentCost(dx, dy, vx, vy, rx, ry, step, t));
            dx += vx * step;
            dy += vy * step;
            t += step;
        }
        return danger;
    };
    const cost = (px, py, reduceX = 0, reduceY = 0, slowed = false) => {
        const dx = px - x, dy = py - y;
        const length = Math.hypot(dx, dy);
        const slowFactor = slowed ? value(946177079442771) : 1;
        const normalTime = value(627510714238268);
        const currentTime = this.GetTimeScale();
        const bulletRatio = slowed && currentTime > 0 ? slowFactor * normalTime / currentTime : 1;
        const playerRatio = slowed && route.player.GetActiveTimeScale() > 0
            ? (slowFactor + value(562609344460634)) * normalTime / route.player.GetActiveTimeScale() : 1;
        const effectiveSpeed = speed * playerRatio;
        const moving = effectiveSpeed > 0 ? Math.min(horizon, length / effectiveSpeed) : 0;
        const mx = moving > 0 ? dx * effectiveSpeed / length : 0;
        const my = moving > 0 ? dy * effectiveSpeed / length : 0;
        let sum = 0, peak = 0, priorityHits = 0;
        for (const threat of risks) {
            const { dx, dy } = threat;
            const vx = threat.vx * bulletRatio, vy = threat.vy * bulletRatio;
            const rx = threat.rx - reduceX, ry = threat.ry - reduceY;
            const delay = bulletRatio > 0 ? threat.launchDelay / bulletRatio : Infinity;
            if (reduceX > 0 && normalRatio <= 1.001) {
                // Collision events run before the stock ability size change.
                const beforeShrink = Math.min(horizon, 2 * this.GetDt1());
                const early = threat.turnRate > 0
                    ? pursuitCost(threat, mx, my, moving, beforeShrink, threat.rx, threat.ry, bulletRatio)
                    : linearCost(dx, dy, vx, vy, mx, my, moving, beforeShrink, threat.rx, threat.ry, delay);
                if (early > 0) return Infinity;
            }
            let danger;
            if (threat.turnRate > 0) {
                danger = pursuitCost(threat, mx, my, moving, horizon, rx, ry, bulletRatio);
            } else {
                danger = linearCost(dx, dy, vx, vy, mx, my, moving, horizon, rx, ry, delay);
            }
            if (danger > 0 && threat.priority) ++priorityHits;
            peak = Math.max(peak, danger);
            sum += danger;
        }
        // With at most 24 hazards, the timing/exposure part stays below 100.
        return 100 * priorityHits + peak + 0.25 * sum;
    };

    const escape = state.escape;
    if (escape && now < escape.until && isInside(escape.target)
        && Math.hypot(escape.target[0] - x, escape.target[1] - y) > 16
        && cost(...escape.target) === 0) {
        state.target = escape.target;
        return state.target;
    }
    state.escape = null;
    let best = cost(tx, ty);
    if (best === 0) return null;
    const choices = [[tx, ty]];
    const d = Math.hypot(tx - x, ty - y);
    const ux = d ? (tx - x) / d : 1, uy = d ? (ty - y) / d : 0;
    const crowded = risks.length >= 4;
    const roomAfter = (px, py) => {
        let clearance = Infinity;
        for (const threat of risks) {
            const flight = Math.max(0, horizon - threat.launchDelay);
            clearance = Math.min(clearance, Math.hypot(px - x - threat.dx - flight * threat.vx,
                py - y - threat.dy - flight * threat.vy) - Math.max(threat.rx, threat.ry));
        }
        const laneProgress = (px - x) * ux + (py - y) * uy;
        return clearance + 0.12 * laneProgress;
    };
    let bestRoom = -Infinity;
    const k = Math.SQRT1_2;
    const directions = [[k, -k], [k, k], [0, -1], [0, 1], [-k, -k], [-k, k], [-1, 0], [0, 0]];
    for (const distance of speed <= 0 ? [] : fragile ? [travel, travel / 2] : [travel]) {
        for (const [cos, sin] of directions) {
            const [px, py] = safePoint(x + (ux * cos - uy * sin) * distance, y + (uy * cos + ux * sin) * distance);
            choices.push([px, py]);
            const risk = cost(px, py);
            if (risk === 0 && crowded) {
                const room = roomAfter(px, py);
                if (room > bestRoom) {
                    bestRoom = room;
                    best = 0;
                    state.target = [px, py];
                }
                continue;
            }
            if (risk >= best - 0.02) continue;
            best = risk;
            state.target = [px, py];
            if (risk === 0) break;
        }
        if (best === 0 && !crowded) break;
    }
    if (best === 0 && crowded && state.target && Math.hypot(state.target[0] - x, state.target[1] - y) > 32) {
        // Continue a clear escape long enough to leave the cluster, but
        // reconsider immediately if the next sweep finds a new threat.
        state.escape = { target: state.target, until: now + 0.24 };
    }
    // Let the existing skill event shrink the player only when moving alone is
    // still unsafe and the smaller hitbox has a predicted collision-free path.
    const factor = value(671414873574080);
    const drain = value(204373541487551);
    const charge = value(450652746544817);
    if (best > 0 && this._MinutescapeSkillSlot("shrink") && factor > 0 && factor < 1 && drain >= 0
        && charge > drain * (horizon + 2 * this.GetDt1()) && value(634217739121904) >= 1) {
        const reduceX = normalHalfX * (1 - factor), reduceY = normalHalfY * (1 - factor);
        for (const [px, py] of choices) {
            const shrunk = cost(px, py, reduceX, reduceY);
            if (shrunk !== 0 && Math.floor(shrunk / 100) >= Math.floor(best / 100)) continue;
            skills.until.shrink = now + 0.12;
            state.target = px === tx && py === ty ? null : [px, py];
            break;
        }
    }
    // A directional shield must turn toward a real projectile before overlap.
    // Beams are deliberately excluded: the stock shield cannot block them.
    const target = state.target ?? [tx, ty];
    if (hasShield && best > 0) {
        const shieldDrain = value(757548987014003);
        const shieldCharge = value(468190106749655);
        const rewards = this.GetObjectClassByName("dict_challengeMultipliers")?.GetInstances()[0]
            ?.GetSdkInstance()?.GetDataMap();
        const shieldMultiplier = rewards?.get("noAbilities") ?? 1;
        const shieldCapacity = (value(617809584451828) ?? 100) * shieldMultiplier;
        const hp = value(144141474833536);
        const normalHealth = (value(601470905722665) || hp) * (rewards?.get("fragile") ?? 1);
        const needsEmergencyRed = stuck && hp < 0.3 * normalHealth;
        const canSpendOnRed = fragile || shieldCharge >= 0.9 * shieldCapacity && (!stuck || needsEmergencyRed);
        const dt = this.GetDt1();
        const shieldReady = this._MinutescapeSkillSlot("shield") && shieldDrain >= 0
            && shieldCharge > shieldDrain * (shieldPrepaid ? dt : 0.4 + dt);
        let incoming = null, danger = 0, covering = 0;
        const possible = [];
        const shieldWindow = Math.min(horizon, Math.max(2 * dt, (stuck ? 0.15 : 0.21) / timeScale));
        const length = Math.hypot(target[0] - x, target[1] - y);
        const mx = length ? (target[0] - x) * speed / length : 0;
        const my = length ? (target[1] - y) * speed / length : 0;
        const moving = speed > 0 ? Math.min(horizon, length / speed) : 0;
        for (const threat of risks) {
            // Allow an unavoidable Red hit to use the surplus near full charge.
            // Fragile always treats damaging Red shots as dangerous.
            if (threat.zap || (!canSpendOnRed && !threat.priority)) continue;
            const contact = (limit, padding) => threat.turnRate > 0
                ? pursuitCost(threat, mx, my, moving, limit, threat.rx + padding, threat.ry + padding)
                : linearCost(threat.dx, threat.dy, threat.vx, threat.vy, mx, my, moving, limit,
                    threat.rx + padding, threat.ry + padding, threat.launchDelay);
            const score = contact(shieldWindow, 15);
            const rank = score > 0 ? score + (threat.priority ? 100 : 0)
                + (stuck && threat.animation === "Blue" ? 5 : 0) : 0;
            if (rank > danger) { incoming = threat; danger = rank; }
            if (contact(horizon, 0) > 0) possible.push(threat);
        }
        if (shieldReady && incoming) {
            // Reserve a narrow lead for the game's next aim/collision steps.
            // Continue holding only if the next scan still sees a threat.
            skills.until.shield = now + Math.max(3 * dt, 0.4 / timeScale);
            const flight = Math.max(0, dt - incoming.launchDelay);
            skills.shieldAim = [x + incoming.dx + incoming.vx * flight,
                y + incoming.dy + incoming.vy * flight];
        }
        if (possible.length > 1) {
            const arc = [11, 27, 37, 48, 70, 90, 179][value(388455805093872)] ?? 11;
            const maxSpread = Math.cos(Math.min(180, 2 * arc) * Math.PI / 180);
            covering = possible.every(a => possible.every(b => a.dx * b.dx + a.dy * b.dy
                >= maxSpread * Math.hypot(a.dx, a.dy) * Math.hypot(b.dx, b.dy))) ? possible.length : 0;
        }
        const reserve = shieldDrain * (0.4 + Math.min(0.6, waveDuration));
        const cannotCover = possible.length > 1 && !covering;
        const needsWave = possible.some(threat => fragile || threat.priority) && (shieldCharge < reserve || cannotCover);
        // Stuck starts with enough health to absorb an occasional dash. Save
        // charges for when health drops or the short forecast shows a burst
        // large enough to threaten the remaining health.
        const predictedDamage = possible.reduce((total, threat) => total
            + (threat.animation === "Blue" ? 5 : threat.animation === "Purple" ? 2 : 1), 0);
        const stuckEmergency = hp <= 0.76 * normalHealth || predictedDamage >= hp * 0.6;
        if (needsWave && (!stuck || stuckEmergency)) {
            this._MinutescapeAutoWavePlan(route, waveThreats, stuck ? 3 : 2);
        }
    }
    // Slow Time retains its native player slowdown too. It buys decision time;
    // it is never treated as deleting a beam or granting invulnerability.
    const slowDrain = value(985590669122070);
    if (best > 0 && this._MinutescapeSkillSlot("slow") && slowDrain >= 0
        && value(990876506082785) > slowDrain * (horizon + 2 * this.GetDt1())
        && value(946177079442771) > 0 && value(946177079442771) < 1) {
        skills.until.slow = now + 0.18;
        let slowedBest = Infinity, slowedTarget = target;
        for (const [px, py] of choices) {
            const risk = cost(px, py, 0, 0, true);
            if (risk < slowedBest) { slowedBest = risk; slowedTarget = [px, py]; }
        }
        if (slowedBest === 0 || Math.floor(slowedBest / 100) < Math.floor(best / 100)) state.target = slowedTarget;
    }
    return state.target;
}

// Keep plans local to the live run and the exact equipped pair. Native events
// still own every ability's charges, size, time scale, effects and statistics.
_MinutescapeAutoSkillsState(route) {
    const variables = this.GetEventSheetManager();
    const value = sid => variables.GetEventVariableBySID(sid)?.GetValue();
    const loadout = `${value(477848051505523)}/${value(505640545931379)}`;
    let skills = route.skills;
    if (!skills || skills.loadout !== loadout) {
        skills = route.skills = { loadout, until: {}, shieldAim: null,
            shieldStarted: null, shock: null, waveNext: -1 };
        if (route.avoidance) route.avoidance.next = -1;
    }
    if (skills.shock) {
        const charging = value(708128531638183), duration = value(719031418869378);
        if (!this._MinutescapeSkillSlot("shockwave") || charging >= duration
            || this.GetGameTime() - skills.shock.started > duration + 0.5) {
            skills.shock = null;
            skills.until.shockwave = -1;
            skills.waveNext = this.GetGameTime() + (route.challenge === "stuck" ? 2.6 : 0.25);
        } else skills.until.shockwave = this.GetWallTime() + 0.12;
    }
    return skills;
}

_MinutescapeSkillSlot(skill, allowManual = false) {
    const variables = this.GetEventSheetManager();
    const value = sid => variables.GetEventVariableBySID(sid)?.GetValue();
    if (value(530499771236373) === "noAbilities") return 0;
    const group = { shrink: "Shrink", slow: "Slow Time", shield: "Shield", shockwave: "Shockwave" }[skill];
    const prefix = { shrink: "Shrink", slow: "Slow", shield: "Shield", shockwave: "Shockwave" }[skill];
    if (!group || !variables.GetEventGroupByName(group)?.IsGroupActive()) return 0;
    const left = value(477848051505523) === skill && variables.GetEventGroupByName(`${prefix} Left`)?.IsGroupActive();
    const right = value(505640545931379) === skill && variables.GetEventGroupByName(`${prefix} Right`)?.IsGroupActive();
    if (!allowManual && ((left && value(608732816899725)) || (right && value(287501796200871)))) return 0;
    return left && value(608732816899725) ? 608732816899725
        : right && value(287501796200871) ? 287501796200871
        : left ? 608732816899725 : right ? 287501796200871 : 0;
}

_MinutescapeAutoWavePlan(route, nearby, minimum = 3) {
    const skills = route.skills;
    const variables = this.GetEventSheetManager();
    const value = sid => variables.GetEventVariableBySID(sid)?.GetValue();
    // Wind up in advance for a cluster; don't spend a charge on one stray shot.
    // Once paid, keep holding through the original windup even if shots move away.
    if (nearby >= minimum && !skills.shock && this._MinutescapeSkillSlot("shockwave")
        && value(955318864596436) >= 1 && !value(186150369012403)
        && value(634217739121904) >= 1 && this.GetGameTime() >= skills.waveNext) {
        skills.shock = { started: this.GetGameTime() };
        skills.until.shockwave = this.GetWallTime() + 0.12;
    }
}

// Only the two held-single input flags may be synthesized. Each equipped
// ability runs through its own original side group and resource accounting.
_MinutescapeAutoSkillHeld(sid) {
    if (sid !== 608732816899725 && sid !== 287501796200871) return false;
    const patrol = this._minutescapePatrol, route = patrol?.route, skills = route?.skills;
    if (!patrol?.enabled || !skills || this.GetMainRunningLayout()?.GetName() !== "Dodge"
        || this._NeedsHandleSaveOrLoad() || this.GetLayoutManager().IsPendingChangeMainLayout()) return false;
    if (this.GetObjectClassBySID(971355649700802)?.GetInstances()[0] !== route.player) return false;
    const variables = this.GetEventSheetManager();
    const value = id => variables.GetEventVariableBySID(id)?.GetValue();
    if (route.challenge !== value(530499771236373)
        || skills.loadout !== `${value(477848051505523)}/${value(505640545931379)}`
        || !(value(144141474833536) > 0) || !(value(634217739121904) >= 1)) return false;
    const skill = value(sid === 608732816899725 ? 477848051505523 : 505640545931379);
    if (this._MinutescapeSkillSlot(skill) !== sid || !(skills.until[skill] >= this.GetWallTime())) return false;
    if (skill === "shockwave") return !!skills.shock && (value(186150369012403) || value(955318864596436) >= 1);
    const charge = value({ shrink: 450652746544817, slow: 990876506082785, shield: 468190106749655 }[skill]);
    const drain = value({ shrink: 204373541487551, slow: 985590669122070, shield: 757548987014003 }[skill]);
    if (!(drain >= 0)) return false;
    if (skill === "shield") {
        const shield = this.GetObjectClassByName("spr_playerShield")?.GetInstances()[0]?.GetWorldInfo();
        return charge > drain * (shield?.IsVisible() ? this.GetDt1() : 0.4 + this.GetDt1());
    }
    return charge > drain * this.GetDt1();
}

_MinutescapeAutoShieldAim() {
    const route = this._minutescapePatrol?.route;
    const slot = this._MinutescapeSkillSlot("shield");
    if (!slot || !this._MinutescapeAutoSkillHeld(slot) || !route?.skills?.shieldAim) return false;
    const shield = this.GetObjectClassByName("spr_playerShield")?.GetInstances()[0];
    const move = shield?.GetBehaviorSdkInstanceFromCtor(C3.Behaviors.MoveTo);
    if (!move) return false;
    const [x, y] = route.skills.shieldAim;
    move._AddWaypoint(x, y, true);
    return true;
}

// Called only when the stock shield's TriggerOnce actually pays its upfront
// charge. Use an automation-local clock; don't reset real mouse input timers.
_MinutescapeAutoShieldChargeStarted() {
    const slot = this._MinutescapeSkillSlot("shield");
    if (slot && this._MinutescapeAutoSkillHeld(slot)) {
        this._minutescapePatrol.route.skills.shieldStarted = this.GetGameTime();
    }
}

_MinutescapeAutoShieldPrepaid() {
    const slot = this._MinutescapeSkillSlot("shield");
    if (!slot || !this._MinutescapeAutoSkillHeld(slot)) return false;
    const started = this._minutescapePatrol.route.skills.shieldStarted;
    const elapsed = this.GetGameTime() - started;
    return started !== null && started !== undefined && elapsed >= 0 && elapsed <= 0.4;
}
