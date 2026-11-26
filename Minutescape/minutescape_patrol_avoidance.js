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
    const hp = this.GetEventSheetManager().GetEventVariableBySID(144141474833536);
    if (!(hp?.GetValue() > 0)) {
        state.route = null;
        return false;
    }
    const player = this.GetObjectClassBySID(971355649700802)?.GetInstances()[0];
    const move = player?.GetBehaviorSdkInstanceFromCtor(C3.Behaviors.MoveTo);
    if (!move) return false;

    const world = player.GetWorldInfo();
    const x = world.GetX(), y = world.GetY();
    let left = 0, right = layout.GetWidth(), top = 0, bottom = layout.GetHeight();
    for (const wall of this.GetObjectClassBySID(253185647818588)?.GetInstances() ?? []) {
        const pos = wall.GetWorldInfo();
        switch (wall.GetInstanceVariableValue(0)) {
            case "left": left = Math.max(left, pos.GetX() + 2.5); break;
            case "right": right = Math.min(right, pos.GetX() - 2.5); break;
            case "up": top = Math.max(top, pos.GetY() + 2.5); break;
            case "down": bottom = Math.min(bottom, pos.GetY() - 2.5); break;
        }
    }
    const insetX = Math.abs(world.GetWidth()) / 2 + 18;
    const insetY = Math.abs(world.GetHeight()) / 2 + 18;
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
    if (route?.player !== player) {
        const distances = [Math.abs(y - top), Math.abs(x - right), Math.abs(y - bottom), Math.abs(x - left)];
        const edge = distances.indexOf(Math.min(...distances));
        route = state.route = { player, move, edge, joining: true };
    }

    let tx = route.edge === 1 ? right : route.edge === 3 ? left : C3.clamp(x, left, right);
    let ty = route.edge === 0 ? top : route.edge === 2 ? bottom : C3.clamp(y, top, bottom);
    const distanceToSide = Math.hypot(tx - x, ty - y);
    // Rejoin the same side when it moves, rather than cutting diagonally to its new corner.
    // Use a wider rejoin threshold than arrival tolerance so a turn does not toggle the phase.
    route.joining = distanceToSide > (route.joining ? 4 : 8);
    if (!route.joining) {
        tx = route.edge < 2 ? right : left;
        ty = route.edge === 0 || route.edge === 3 ? top : bottom;
        if (Math.hypot(tx - x, ty - y) <= 4) {
            route.edge = (route.edge + 1) % 4;
            tx = route.edge < 2 ? right : left;
            ty = route.edge === 0 || route.edge === 3 ? top : bottom;
        }
    }
    const dodge = this._MinutescapeAvoidanceTarget(route, world, x, y, tx, ty, left, right, top, bottom);
    move._SetEnabled(true);
    move._AddWaypoint(dodge?.[0] ?? tx, dodge?.[1] ?? ty, true);
    return true;
}

_MinutescapeAvoidanceTarget(route, world, x, y, tx, ty, left, right, top, bottom) {
    const speed = route.move._GetMaxSpeed() * route.player.GetActiveTimeScale();
    if (!(speed > 0)) return null;
    const horizon = 0.30;
    const now = this.GetWallTime();
    const state = route.avoidance ??= { next: -1, target: null, previous: new WeakMap() };
    if (now < state.next) {
        const target = state.target;
        if (target && target[0] >= left && target[0] <= right && target[1] >= top && target[1] <= bottom) return target;
        if (!target) return null;
    }
    state.next = now + 0.075;
    state.target = null;

    const bulletClass = this.GetObjectClassBySID(591906528573192); // spr_bullet
    const boltClass = this.GetObjectClassBySID(563331159900904);   // active boss zap
    if (!bulletClass?.GetInstances().length && !boltClass?.GetInstances().length) return null;
    const halfX = Math.abs(world.GetWidth()) / 2 + 6;
    const halfY = Math.abs(world.GetHeight()) / 2 + 6;
    const travel = speed * horizon;
    const reach = travel + 1000 * horizon + Math.max(halfX, halfY) + 90;
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
            if (!zap && bullet.GetSdkInstance()._GetCurrentAnimationName() === "Green") continue;
            const box = info.GetBoundingBox();
            const bx = (box.getLeft() + box.getRight()) / 2;
            const by = (box.getTop() + box.getBottom()) / 2;
            const rx = halfX + (box.getRight() - box.getLeft()) / 2;
            const ry = halfY + (box.getBottom() - box.getTop()) / 2;
            let vx = 0, vy = 0;
            if (!zap) {
                const behavior = bullet.GetBehaviorSdkInstanceFromCtor(C3.Behaviors.Bullet);
                const scale = bullet.GetActiveTimeScale();
                vx = (behavior?._dx ?? 0) * scale;
                vy = (behavior?._dy ?? 0) * scale;
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
            // Cull hazards outside all positions the player and projectile can reach.
            const nearX = Math.max(0, Math.min(dx, dx + vx * horizon), -Math.max(dx, dx + vx * horizon));
            const nearY = Math.max(0, Math.min(dy, dy + vy * horizon), -Math.max(dy, dy + vy * horizon));
            if (nearX > rx + travel || nearY > ry + travel) continue;
            const rank = Math.max(0, nearX - rx) ** 2 + Math.max(0, nearY - ry) ** 2;
            risks.push({ dx, dy, vx, vy, rx, ry, rank });
        }
        instances.length = 0;
        seen.clear();
    };
    collect(bulletClass, false);
    collect(boltClass, true);
    if (!risks.length) return null;
    risks.sort((a, b) => a.rank - b.rank);
    risks.length = Math.min(risks.length, 12);

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
    const cost = (px, py) => {
        const dx = px - x, dy = py - y;
        const length = Math.hypot(dx, dy);
        const moving = Math.min(horizon, length / speed);
        const mx = length ? dx * speed / length : 0;
        const my = length ? dy * speed / length : 0;
        let sum = 0, peak = 0;
        for (const threat of risks) {
            const { dx, dy, vx, vy, rx, ry } = threat;
            const across = moving > 0 ? segmentCost(dx, dy, vx - mx, vy - my, rx, ry, moving, 0) : 0;
            const still = moving < horizon ? segmentCost(dx + (vx - mx) * moving, dy + (vy - my) * moving,
                vx, vy, rx, ry, horizon - moving, moving) : 0;
            const danger = Math.max(across, still) + 0.25 * Math.min(across, still);
            peak = Math.max(peak, danger);
            sum += danger;
        }
        return peak + 0.25 * sum;
    };

    let best = cost(tx, ty);
    if (best === 0) return null;
    const d = Math.hypot(tx - x, ty - y);
    const ux = d ? (tx - x) / d : 1, uy = d ? (ty - y) / d : 0;
    const k = Math.SQRT1_2;
    const directions = [[k, -k], [k, k], [0, -1], [0, 1], [-k, -k], [-k, k], [-1, 0], [0, 0]];
    for (const [cos, sin] of directions) {
        const px = C3.clamp(x + (ux * cos - uy * sin) * travel, left, right);
        const py = C3.clamp(y + (uy * cos + ux * sin) * travel, top, bottom);
        const risk = cost(px, py);
        if (risk >= best - 0.02) continue;
        best = risk;
        state.target = [px, py];
        if (risk === 0) break;
    }
    return state.target;
}
