// Only Upgrade's existing right-button events call this. Pan by displacement,
// not the Touch plugin's speed estimate times the engine's capped delta.
_MinutescapeUpgradeDrag(start) {
    const layout = this.GetMainRunningLayout();
    if (layout?.GetName() !== "Upgrade") return false;
    const mouse = this.GetSingleGlobalObjectClassByCtor(C3.Plugins.Mouse)
        ?.GetSingleGlobalInstance()?.GetSdkInstance();
    const layer = layout.GetLayerByIndex(0);
    if (!mouse || !layer) return false;
    const x = C3.Plugins.Mouse.Exps.AbsoluteX.call(mouse);
    const y = C3.Plugins.Mouse.Exps.AbsoluteY.call(mouse);
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
        this._minutescapeDragPoint = null;
        return false;
    }

    const previous = this._minutescapeDragPoint;
    this._minutescapeDragPoint = { layout, x, y };
    if (start || previous?.layout !== layout || (x === previous.x && y === previous.y)) return true;

    // Convert both positions using the same current camera transform so zoom,
    // display scaling, and the motion of the camera itself cannot feed back.
    const [px, py] = layer.CanvasCssToLayer_DefaultTransform(previous.x, previous.y);
    const [cx, cy] = layer.CanvasCssToLayer_DefaultTransform(x, y);
    if (![px, py, cx, cy].every(Number.isFinite)) return false;
    layout.SetScrollX(layout.GetScrollX() + px - cx);
    layout.SetScrollY(layout.GetScrollY() + py - cy);
    return true;
}
