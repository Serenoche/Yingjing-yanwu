"use strict";

const UE = require("ue");
const MAX_WATCHERS = 32;
const MAX_PENDING_CHANGES = 256;
let bridge;

function valid(object) {
    return !!object && UE.KismetSystemLibrary.IsValid(object);
}

function positiveToken(value) {
    if (!/^[1-9][0-9]{0,9}$/.test(value)) return 0;
    const number = Number(value);
    return number <= 2147483647 ? number : 0;
}

function errorCode(error) {
    const code = error && error.message;
    return typeof code === "string" && /^[a-z0-9-]{1,60}$/.test(code) ? code : "native-call-failed";
}

function write(widget, message) {
    widget.SetText(UE.KismetTextLibrary.Conv_StringToText(message));
}

function install(gameInstance) {
    if (bridge || !valid(gameInstance)) return false;

    function control(type, name) {
        const existing = typeof type.Find === "function" ? type.Find(name, gameInstance) : null;
        return valid(existing) ? existing : UE.NewObject(type.StaticClass(), gameInstance, name);
    }

    const response = control(UE.TextBlock, "PBZFrostR3Response");
    if (!valid(response)) throw new Error("bridge-response-missing");
    write(response, "boot-started");
    let command, signal, frost, freezeTag;
    try {
        frost = UE.PBZBlueprintFunctionLibrary.MakeAttribute("Frost_Accumulation", UE.BasicAttributeSet.StaticClass());
        if (!frost) throw new Error("frost-attribute-missing");
        freezeTag = new UE.GameplayTag();
        freezeTag.TagName = "CharacterState.StatusInfliction.Frost.Effect";
        command = control(UE.TextBlock, "PBZFrostR3Command");
        signal = control(UE.Button, "PBZFrostR3Signal");
        if (!valid(command) || !valid(signal)) throw new Error("bridge-controls-missing");
    } catch (error) {
        write(response, `boot-error:${errorCode(error)}`);
        return false;
    }

    const watchers = new Map();
    const pending = [];
    const overflow = new Set();
    let timer;

    function deliver(watch, message) {
        if (watchers.get(watch.token) !== watch || !watch.active) return;
        write(response, message);
        // The private button stays detached. Lua recognizes this native
        // call as a signal after the original delegate stack has unwound.
        signal.SetClickMethod(0);
    }

    function flush() {
        timer = undefined;
        if (!valid(response) || !valid(signal)) {
            pending.length = 0;
            overflow.clear();
            return;
        }
        const events = pending.splice(0);
        const incomplete = [...overflow];
        overflow.clear();
        for (const event of events) deliver(event.watch, event.message);
        for (const watch of incomplete) {
            deliver(watch, `error|${watch.token}|event-queue-overflow`);
        }
    }

    function enqueue(watch, message) {
        if (pending.length >= MAX_PENDING_CHANGES) {
            // Return an error after the retained events, even if this watch
            // did not have a slot in the full queue yet.
            overflow.add(watch);
        } else {
            pending.push({ watch, message });
        }
        if (timer === undefined) timer = setTimeout(flush, 0);
    }

    function detach(watch) {
        watch.active = false;
        let removed = true;
        let cancelled = true;
        for (const entry of watch.tasks) {
            if (!valid(entry.task)) continue;
            try {
                if (entry.delegate) entry.delegate.Remove(entry.handler);
            } catch (_) {
                removed = false;
            } finally {
                try {
                    entry.task.Cancel();
                } catch (_) {
                    cancelled = false;
                }
            }
        }
        // Keep failed cancellations available for an explicit clear retry.
        if (cancelled) watchers.delete(watch.token);
        return removed && cancelled;
    }

    function bind(token, path) {
        if (watchers.has(token)) throw new Error("token-already-bound");
        if (watchers.size >= MAX_WATCHERS) throw new Error("too-many-watchers");
        if (typeof path !== "string" || path.length > 512 || !/^\/[\w./:-]+$/.test(path)) {
            throw new Error("invalid-actor-path");
        }
        const actor = UE.Actor.Find(path, null);
        const owner = valid(actor) && UE.GameplayStatics.GetGameInstance(actor);
        if (!valid(owner) || owner !== gameInstance || actor.IsActorBeingDestroyed() || !actor.IsAlive()) {
            throw new Error("actor-out-of-scope");
        }
        if (!valid(actor.AbilitySystemComponent) || !valid(actor.AttributeSetBase)) {
            throw new Error("attributes-not-ready");
        }
        const initial = UE.AttributeUtils.GetCharacterAttributeValue(actor, frost);
        if (!Number.isFinite(initial)) throw new Error("invalid-initial-value");
        const frozen = actor.AbilitySystemComponent.HasMatchingGameplayTag(freezeTag);

        const watch = { token, tasks: [], active: true };
        watchers.set(token, watch);
        function subscribe(task, event, handler) {
            if (!valid(task)) throw new Error("task-not-created");
            const entry = { task, handler };
            watch.tasks.push(entry);
            entry.delegate = task[event];
            entry.delegate.Add(handler);
            task.Activate();
        }
        try {
            subscribe(UE.AbilityAsync_WaitAttributeChanged.WaitForAttributeChanged(actor, frost, false),
                "Changed", (_attribute, current, previous) => {
                if (!watch.active || !Number.isFinite(current) || !Number.isFinite(previous) || current === previous) return;
                enqueue(watch, `change|${token}|${current}|${previous}`);
            });
            subscribe(UE.AbilityAsync_WaitGameplayTagCountChanged.WaitGameplayTagCountChangedOnActor(actor, freezeTag),
                "TagCountChanged", count => {
                if (watch.active) enqueue(watch, `freeze|${token}|${count > 0 ? 1 : 0}`);
            });
            enqueue(watch, `confirmed|${token}|${initial}`);
        } catch (_) {
            if (!detach(watch)) throw new Error("failed-bind-cleanup-unconfirmed");
            throw new Error("task-activation-failed");
        }
        return `bound|${token}|${initial}|${frozen ? 1 : 0}`;
    }

    function receive() {
        let token = 0;
        let message;
        try {
            const fields = UE.KismetTextLibrary.Conv_TextToString(command.GetText()).split("|");
            const verb = fields[0];
            token = positiveToken(fields[1]);
            if (verb === "ping" && token && fields.length === 2) {
                message = `pong|${token}|3`;
            } else if (verb === "bind" && token && fields.length === 3) {
                message = bind(token, fields[2]);
            } else if (verb === "unbind" && token && fields.length === 2) {
                const watch = watchers.get(token);
                if (watch && !detach(watch)) throw new Error("task-detach-unconfirmed");
                message = `unbound|${token}|0`;
            } else if (verb === "clear" && token && fields.length === 2) {
                const active = [...watchers.values()];
                let complete = true;
                for (const watch of active) {
                    if (!detach(watch)) complete = false;
                }
                if (!complete) throw new Error("task-detach-unconfirmed");
                message = `cleared|${token}|${active.length}`;
            } else {
                throw new Error("invalid-command");
            }
        } catch (error) {
            message = `error|${token}|${errorCode(error)}`;
        }
        // Command receipts are synchronous. No Lua call is made while the
        // private OnClicked delegate is processing a command.
        write(response, message);
    }

    try {
        signal.OnClicked.Add(receive);
        write(response, "boot-ready");
    } catch (error) {
        write(response, `boot-error:${errorCode(error)}`);
        return false;
    }
    bridge = { stop() {
        if (timer !== undefined) clearTimeout(timer);
        timer = undefined;
        pending.length = 0;
        overflow.clear();
        let complete = true;
        for (const watch of [...watchers.values()]) if (!detach(watch)) complete = false;
        if (!complete) throw new Error("task-detach-unconfirmed");
        signal.OnClicked.Remove(receive);
        write(response, "stopped");
    } };
    return true;
}

exports.stop = function stop() {
    if (bridge && bridge.stop) bridge.stop();
    bridge = undefined;
};

const gameInstance = require("puerts").argv.getByName("GameInstance");
if (install(gameInstance)) console.log("[PBZMOD] FrostEventR3 ready");
else console.warn("[PBZMOD] FrostEventR3 initialization incomplete");
