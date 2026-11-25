-- Batch-one rules only. Nothing in this module reads or mutates a game object.
local Catalog = {}

Catalog.version = 1
Catalog.weaponId = "黑伤"
Catalog.rules = {
    fireMaximum = 5, fireDuration = 4, fireTick = 1, fireDamage = 0.1,
    burstMinimum = 3, burstDamage = 0.6, burstRadius = 3,
    edgeMaximum = 3, edgeDuration = 8, edgeDamage = 0.6,
    retainMinimum = 2, retainedEdge = 1,
    echoDelay = 0.6, echoDamage = 0.6, echoFire = 2, echoRadius = 1.5,
}
Catalog.effects = {
    ignite_blade = {name="引火入刃", kind="core", direction="fire", requires={}},
    heartfire_slash = {name="焚心重斩", kind="boon", direction="fire", requires={"ignite_blade"}},
    rekindle = {name="灰中复燃", kind="boon", direction="fire", requires={"heartfire_slash"}},
    store_edge = {name="藏锋", kind="core", direction="parry", requires={}},
    retain_edge = {name="留锋", kind="boon", direction="parry", requires={"store_edge"}},
    temper_edge = {name="淬火藏锋", kind="fusion", direction="mixed", requires={"ignite_blade","store_edge"}},
    return_cut = {name="回锋·二段", kind="stance", direction="mixed", requires={}},
}
Catalog.presets = {
    furnace = {
        name="回炉重击", summary="轻击挂火，重击与回斩连续引爆",
        effects={"ignite_blade","heartfire_slash","rekindle","return_cut"},
    },
    temper = {
        name="淬火一击", summary="弹反蓄锋，重击点火并爆发",
        effects={"ignite_blade","heartfire_slash","store_edge","temper_edge","return_cut"},
    },
}

function Catalog.build(ids)
    assert(type(ids)=="table", "effect list required")
    local selected, count = {}, {stance=0,fusion=0}
    for index,id in ipairs(ids) do
        assert(type(id)=="string" and Catalog.effects[id], "unknown effect at "..index)
        assert(not selected[id], "duplicate effect: "..id)
        selected[id]=true
        local kind=Catalog.effects[id].kind
        if count[kind] then count[kind]=count[kind]+1; assert(count[kind]<=1,"too many "..kind.." effects") end
    end
    for id in pairs(selected) do
        for _,required in ipairs(Catalog.effects[id].requires) do
            assert(selected[required], id.." requires "..required)
        end
    end
    assert(selected.ignite_blade or selected.store_edge, "at least one core required")
    return selected
end

function Catalog.preset(id)
    local preset=assert(Catalog.presets[id], "unknown preset")
    return Catalog.build(preset.effects)
end

return Catalog
