local bindCheckpoint = require("XiguCheckpoint")

return bindCheckpoint({
    id = "pengmeng",
    name = "斧老大斩落处",
    runtimeModule = "XiguBossArena",
    checkpointCreatesBell = true,
    bellSaveId = "BrokenBell_TheEnd01",
    retiredBell = "BP_MelodiousBell_StoneCrane_C_UAID_60CF8480990921F902_2125991278",
    bellGround = {
        X = -48965,
        Y = 261285,
        Z = -24458,
    },
    reviveClearance = 2100,
    phaseReturnPoints = { {
        X = -50590,
        Y = 260180,
        Z = -24593,
    }, {
        X = -50720,
        Y = 260295,
        Z = -24591,
    }, {
        X = -50520,
        Y = 260010,
        Z = -24595,
    } },
    spawnClearance = 1400,
    phaseSpawnClearance = 1400,
    spawnTrace = {
        top = -24435,
        bottom = -24830,
        worldStaticFallback = true,
    },
    spawnPoints = { {
        X = -52188.465,
        Y = 258599.81,
        Z = -24613.5,
    }, {
        X = -52570,
        Y = 259920,
        Z = -24602,
    }, {
        X = -51255,
        Y = 258430,
        Z = -24608,
    }, {
        X = -53835,
        Y = 259155,
        Z = -24586,
    }, {
        X = -53500,
        Y = 257990,
        Z = -24602,
    }, {
        X = -51270,
        Y = 259790,
        Z = -24597,
    } },
    combatBoundary = { {
        X = -53876,
        Y = 256501,
    }, {
        X = -52877,
        Y = 256574,
    }, {
        X = -51792,
        Y = 256719,
    }, {
        X = -49809,
        Y = 257794,
    }, {
        X = -49272,
        Y = 258434,
    }, {
        X = -49206,
        Y = 259671,
    }, {
        X = -48785,
        Y = 261310,
    }, {
        X = -49520,
        Y = 261910,
    }, {
        X = -50523,
        Y = 262238,
    }, {
        X = -51320,
        Y = 262890,
    }, {
        X = -56022,
        Y = 259039,
    } },
    fogDoors = { "BP_FogDoor_C_UAID_BCFCE7058A987D9B02_1624981930", "BP_FogDoor_C_UAID_BCFCE7058A987D9B02_1319427929" },
    cinematicProps = {
        SkeletalMeshActor_UAID_BCFCE7078B5A85A502_1245251076 = "Seq014 彭猛斧头",
        SkeletalMeshActor_UAID_BCFCE7078B5A86A502_1302412280 = "Seq014 锁链石一",
        SkeletalMeshActor_UAID_BCFCE7078B5A86A502_1302506281 = "Seq014 锁链石二",
        SkeletalMeshActor_UAID_BCFCE7078B5A86A502_1302568282 = "Seq014 锁链石三",
        SkeletalMeshActor_UAID_BCFCE7078B5A86A502_1302632283 = "Seq014 锁链石四",
    },
    checkpointActors = {
        BP_AISpawner_C_UAID_E89C25A75434C84902_1754973530 = true,
        BP_AISpawnerTriggerVolume_C_UAID_E89C25A75434C84902_1755020532 = true,
        BP_MobDomain_C_UAID_E89C25A75434C84902_1755017531 = true,
        BP_FogDoor_C_UAID_BCFCE7058A987D9B02_1624981930 = true,
        BP_FogDoor_C_UAID_BCFCE7058A987D9B02_1319427929 = true,
    },
    storySpawner = "BP_AISpawner_C_UAID_E89C25A75434C84902_1754973530",
    storyTrigger = "BP_AISpawnerTriggerVolume_C_UAID_E89C25A75434C84902_1755020532",
    storyDomain = "BP_MobDomain_C_UAID_E89C25A75434C84902_1755017531",
    chiLianUltimate = {
        center = {
            X = -52300,
            Y = 259220,
            Z = -24600,
        },
        snakes = { {
            X = -50850,
            Y = 257780,
            Z = -24600,
        }, {
            X = -50780,
            Y = 260520,
            Z = -24590,
        }, {
            X = -53720,
            Y = 260420,
            Z = -24590,
        }, {
            X = -53780,
            Y = 257840,
            Z = -24600,
        } },
    },
    lionArena = {
        center = {
            X = -52220,
            Y = 259040,
            Z = -23590,
        },
        extent = {
            X = 1870,
            Y = 1400,
            Z = 1200,
        },
        exits = { {
            X = -53450,
            Y = 259000,
            Z = -24590,
        }, {
            X = -50890,
            Y = 259040,
            Z = -24580,
        }, {
            X = -52185,
            Y = 257900,
            Z = -24600,
        }, {
            X = -52220,
            Y = 260270,
            Z = -24593,
        } },
    },
})
