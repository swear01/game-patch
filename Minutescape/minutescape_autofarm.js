// F9 opts in to stock Play, Continue and Simulate actions. It never changes score or saves.
_MinutescapeAutoFarmInput() {
    if (this._minutescapeAutoFarm) return;
    const farm = this._minutescapeAutoFarm = { armed: false, layout: null, sent: false };
    globalThis.addEventListener("keydown", event => {
        if (event.code !== "F9" || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
        event.preventDefault();
        if (event.repeat) return;
        farm.armed = !farm.armed;
        if (farm.armed) {
            farm.sent = false;
            if (this._minutescapePatrol) this._minutescapePatrol.enabled = true;
        }
    }, true);
}

_MinutescapeAutoFarmTick() {
    const farm = this._minutescapeAutoFarm;
    if (!farm?.armed || this.IsSuspended()) return;
    const layout = this.GetMainRunningLayout();
    if (farm.layout !== layout) {
        farm.layout = layout;
        farm.sent = false;
    }
    if (farm.sent || !layout || this.IsLayoutFirstTick()
        || this.GetLayoutManager().IsPendingChangeMainLayout() || this._NeedsHandleSaveOrLoad()) return;

    const instance = name => this.GetObjectClassByName(name)?.GetInstances()[0];
    const isVisible = name => layout.GetLayerByName(name)?.IsVisible();
    const variable = sid => this.GetEventSheetManager().GetEventVariableBySID(sid)?.GetTypedValue();
    const name = layout.GetName();
    if (name === "Startup" || name === "Dodge") {
        if (name === "Startup") {
            // The first-run stock screen prompts for a click only after its intro.
            if (variable(424002672106400) !== true) return;
        } else {
            // Let the loss event award the score and finish its typewriter first.
            if (variable(442329147683199) !== false || !(variable(144141474833536) <= 0)
                || !isVisible("Post-Game")) return;
            const message = instance("txt_losingSentence")?.GetSdkInstance();
            if (!message || C3.Plugins.Text.Cnds.IsRunningTypewriterText.call(message)) return;
        }
        const mouse = instance("Mouse")?.GetSdkInstance();
        if (!mouse) return;
        farm.sent = true;
        mouse.Trigger(C3.Plugins.Mouse.Cnds.OnAnyClick);
        return;
    }

    if (name !== "Main Menu" && name !== "Upgrade") return;
    // Do not race the menu's load, the Upgrade layout's auto-save, or settings I/O.
    const storage = instance("LocalStorage")?.GetSdkInstance();
    if (!storage || C3.Plugins.LocalStorage.Cnds.IsProcessingGets.call(storage)
        || C3.Plugins.LocalStorage.Cnds.IsProcessingSets.call(storage)) return;

    if (name === "Upgrade") {
        if (isVisible("Black Screen") || !isVisible("Simulate Button")) return;
        const button = instance("spr_simulateButton")?.GetWorldInfo();
        const keyboard = instance("Keyboard")?.GetSdkInstance();
        if (!button?.IsVisible() || !keyboard) return;
        // Dispatch the stock Enter trigger without holding a key or touching the skill tree.
        const prior = keyboard._triggerWhich;
        keyboard._triggerWhich = 13;
        try {
            farm.sent = true;
            keyboard.Trigger(C3.Plugins.Keyboard.Cnds.OnKey);
        } finally {
            keyboard._triggerWhich = prior;
        }
        return;
    }

    if (variable(540273061315122) !== true
        || ["Credits", "Disclaimer", "Exit prompt", "Boss Disclaimer", "Boss prompt"].some(isVisible)) return;
    const play = this.GetObjectClassByName("txt_mainMenuButtons")?.GetInstances()
        .find(button => button.GetInstanceVariableValue(2) === "play")?.GetWorldInfo();
    const mouse = instance("Mouse")?.GetSdkInstance();
    if (!play?.IsVisible() || !mouse) return;
    const [x, y] = play.GetLayer().LayerToCanvasCss(play.GetX(), play.GetY());
    if (!(x >= 0 && x < this.GetCanvasCssWidth() && y >= 0 && y < this.GetCanvasCssHeight())) return;
    // Run the actual Play click without moving the cursor or emitting other mouse events.
    const prior = [mouse._mouseXcanvas, mouse._mouseYcanvas, mouse._triggerButton, mouse._triggerType];
    [mouse._mouseXcanvas, mouse._mouseYcanvas, mouse._triggerButton, mouse._triggerType] = [x, y, 0, 0];
    try {
        farm.sent = true;
        mouse.Trigger(C3.Plugins.Mouse.Cnds.OnObjectClicked);
    } finally {
        [mouse._mouseXcanvas, mouse._mouseYcanvas, mouse._triggerButton, mouse._triggerType] = prior;
    }
}
