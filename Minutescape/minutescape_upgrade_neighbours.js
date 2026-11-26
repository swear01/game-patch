// Equivalent to stock Upgrade #346: sum the current levels of the four axial neighbours.
_MinutescapeUpgradeNeighbourXP() {
    const events = this.GetEventSheetManager();
    let index = this._minutescapeTreeIndex;
    if (index === undefined) {
        const nodes = this.GetObjectClassBySID(863615817121452)?.GetInstances();
        const origin = nodes?.[0]?.GetWorldInfo();
        if (!origin || nodes.length !== 83) {
            this._minutescapeTreeIndex = false;
            return false;
        }
        const x0 = origin.GetX(), y0 = origin.GetY();
        const tiles = new Map();
        for (const node of nodes) {
            const pos = node.GetWorldInfo();
            const x = (pos.GetX() - x0) / 300, y = (pos.GetY() - y0) / 300;
            const key = x + ',' + y;
            if (!Number.isInteger(x) || !Number.isInteger(y) || tiles.has(key)) {
                this._minutescapeTreeIndex = false;
                return false;
            }
            tiles.set(key, node);
        }
        index = this._minutescapeTreeIndex = {x0, y0, tiles};
    }
    if (!index) return false;

    const x = (events.GetEventVariableBySID(262092864662592)?.GetValue() - index.x0) / 300;
    const y = (events.GetEventVariableBySID(800054794806047)?.GetValue() - index.y0) / 300;
    const xp = events.GetEventVariableBySID(504116557224315);
    const current = xp?.GetValue();
    if (!Number.isFinite(current) || !index.tiles.has(x + ',' + y)) return false;
    const {tiles} = index;
    const level = (a, b) => tiles.get(a + ',' + b)?.GetInstanceVariableValue(7) ?? 0;
    const sum = level(x - 1, y) + level(x + 1, y) + level(x, y - 1) + level(x, y + 1);
    if (!Number.isFinite(sum)) return false;
    xp.SetValue(current + sum);
    return true;
}
