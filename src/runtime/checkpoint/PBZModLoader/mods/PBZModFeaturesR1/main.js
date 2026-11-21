"use strict";

const UE = require("ue");
const bridgeId = "PBZModFeaturesR1";
const loaderStatuses = new Set(["loaded", "disabled", "failed", "stopped"]);
let bridge;

function valid(object) {
    return !!object && UE.KismetSystemLibrary.IsValid(object);
}

function write(widget, message) {
    widget.SetText(UE.KismetTextLibrary.Conv_StringToText(message));
}

function list(token) {
    const state = globalThis.__PBZModLoader;
    if (state && state.status === "loading") return `error|${token}|loader-pending`;
    if (!state || state.version !== 1 || state.status !== "ready" || !Array.isArray(state.mods)) {
        return `error|${token}|loader-unavailable`;
    }

    const lines = [`listed|${token}`];
    for (const mod of state.mods) {
        if (!mod || typeof mod.id !== "string" || !/^[A-Za-z0-9_-]+$/.test(mod.id)
            || mod.id.toLowerCase() === bridgeId.toLowerCase()) continue;
        const status = mod.reloadError === true ? "reload-blocked"
            : loaderStatuses.has(mod.status) ? mod.status : "unknown";
        lines.push(`${mod.id}|${status}`);
    }
    return lines.join("\n");
}

function install(gameInstance) {
    if (!valid(gameInstance)) throw new Error("game-instance-unavailable");

    // These controls never enter the viewport. The game instance owns them
    // so the Lua menu can find the same relay after returning to the title.
    function control(type, suffix) {
        const name = bridgeId + suffix;
        const existing = typeof type.Find === "function" ? type.Find(name, gameInstance) : null;
        return valid(existing) ? existing : UE.NewObject(type.StaticClass(), gameInstance, name);
    }

    const response = control(UE.TextBlock, "Response");
    const command = control(UE.TextBlock, "Command");
    const signal = control(UE.Button, "Signal");
    if (!valid(response) || !valid(command) || !valid(signal)) throw new Error("bridge-controls-missing");

    function receive() {
        let token = 0;
        let message;
        try {
            const request = UE.KismetTextLibrary.Conv_TextToString(command.GetText());
            const fields = /^list\|([1-9][0-9]{0,9})$/.exec(request);
            if (fields && Number(fields[1]) <= 2147483647) token = Number(fields[1]);
            message = token ? list(token) : "error|0|invalid-command";
        } catch (_) {
            message = `error|${token}|native-call-failed`;
        }
        write(response, message);
    }

    write(response, "boot-ready");
    signal.OnClicked.Add(receive);
    return { response, signal, receive };
}

exports.stop = function stop() {
    if (!bridge) return;
    const { response, signal, receive } = bridge;
    if (valid(response)) write(response, "stopped");
    if (valid(signal)) signal.OnClicked.Remove(receive);
    bridge = undefined;
};

bridge = install(require("puerts").argv.getByName("GameInstance"));
console.log("[PBZMOD] ModFeaturesR1 relay ready");
