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
    move._SetEnabled(true);
    move._AddWaypoint(tx, ty, true);
    return true;
}
