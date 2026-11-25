local bindCheckpoint = require("XiguCheckpoint")

local scenes = { {
    id = "cangang",
    name = "锈刃凉亭",
    runtimeModule = "XiguBossArena",
    walkIn = true,
    bellSaveId = "BrokenBell_TheEnd01",
    bellGround = {
        X = -24899.746,
        Y = 290349.72,
        Z = -26580.318,
    },
    entryGround = {
        X = -24780.914,
        Y = 290333.84,
        Z = -26575.1,
    },
    reviveClearance = 2100,
    spawnClearance = 1400,
    phaseSpawnClearance = 1200,
    spawnPoints = { {
        X = -20575,
        Y = 291850,
        Z = -26495.4,
    }, {
        X = -19750,
        Y = 292450,
        Z = -26462.9,
    }, {
        X = -21000,
        Y = 293250,
        Z = -26545.6,
    }, {
        X = -22275,
        Y = 291650,
        Z = -26553.0,
    }, {
        X = -21250,
        Y = 291150,
        Z = -26540.3,
    }, {
        X = -19750,
        Y = 291400,
        Z = -26513.3,
    } },
    phaseReturnPoints = { {
        X = -22700,
        Y = 290650,
        Z = -26561.7,
    }, {
        X = -22650,
        Y = 290550,
        Z = -26569.3,
    }, {
        X = -22550,
        Y = 290700,
        Z = -26555.1,
    } },
    combatBoundary = { {
        X = -23500,
        Y = 290250,
        Z = 0,
    }, {
        X = -21400,
        Y = 290125,
        Z = 0,
    }, {
        X = -18800,
        Y = 291100,
        Z = 0,
    }, {
        X = -18850,
        Y = 293725,
        Z = 0,
    }, {
        X = -20750,
        Y = 294075,
        Z = 0,
    }, {
        X = -23100,
        Y = 293650,
        Z = 0,
    } },
    combatHeight = {
        min = -26763.0,
        max = -25862.9,
    },
    spawnTrace = {
        top = -26287.9,
        bottom = -26748.0,
        worldStaticFallback = true,
        localGround = true,
    },
    storySpawners = { "BP_AISpawner_C_UAID_E89C25A751202B5402_1470310185" },
    checkpointActors = {
        BP_AICombatTriggerVolume_C_UAID_60CF8480990909AF02_1782592844 = true,
        BP_AISpawnerTriggerVolume_C_UAID_E89C25A75120EB5202_1865256523 = true,
        BP_FogDoor_C_UAID_BCFCE7058A98779C02_1900432489 = true,
        BP_FogDoor_C_UAID_BCFCE788D449245F02_2115887038 = true,
        BP_MobDomain_C_UAID_E89C25A75120EB5202_2003149524 = true,
        BP_AISpawner_C_UAID_E89C25A751202B5402_1470310185 = true,
    },
    openStoryDoors = { "BP_FogDoor_C_UAID_BCFCE7058A98779C02_1900432489" },
    chiLianUltimate = {
        center = {
            X = -20950,
            Y = 291800,
            Z = -26509.6,
        },
        snakes = { {
            X = -22200,
            Y = 291000,
            Z = -26548.6,
        }, {
            X = -20000,
            Y = 291550,
            Z = -26503.1,
        }, {
            X = -19500,
            Y = 293000,
            Z = -26480.6,
        }, {
            X = -21125,
            Y = 293625,
            Z = -26616.5,
        } },
    },
    lionArena = {
        center = {
            X = -21100,
            Y = 291950,
            Z = -25499.8,
        },
        extent = {
            X = 1975,
            Y = 1575,
            Z = 1240,
        },
        exits = { {
            X = -22250,
            Y = 291250,
            Z = -26515.9,
        }, {
            X = -19800,
            Y = 291850,
            Z = -26484.0,
        }, {
            X = -20800,
            Y = 290700,
            Z = -26622.2,
        }, {
            X = -20875,
            Y = 293150,
            Z = -26520.5,
        } },
    },
    arenaOnlyBell = true,
    componentPointMask = true,
    bossRecovery = true,
    combatFog = "BP_FogDoor_C_UAID_BCFCE788D449245F02_2115887038",
    roadFogs = { {
        name = "铃铛右侧楼梯",
        scaleZ = 1.28,
        points = { {
            X = -26250,
            Y = 290350,
            Z = -26250,
        }, {
            X = -26250,
            Y = 291350,
            Z = -26125,
        }, {
            X = -26250,
            Y = 292275,
            Z = -25950,
        }, {
            X = -26250,
            Y = 292580,
            Z = -25875,
        } },
    } },
    retiredBell = "BP_MelodiousBell_C_UAID_74563CC57EE2E73C02_1922111565",
    checkpointCreatesBell = true,
    zuoShangAnchors = {
        yaw = -146.69,
        ground = { {
            X = -20500,
            Y = 292100,
            Z = -26479.7,
        }, {
            X = -20950,
            Y = 291800,
            Z = -26509.6,
        }, {
            X = -20250,
            Y = 292250,
            Z = -26467.5,
        }, {
            X = -21650,
            Y = 291350,
            Z = -26528.6,
        } },
    },
}, {
    id = "ahua",
    name = "血肉花田",
    runtimeModule = "XiguBossArena",
    walkIn = true,
    bellSaveId = "BrokenBell_TheEnd01",
    bellGround = {
        X = -69950,
        Y = 209250,
        Z = -19546.1,
    },
    entryGround = {
        X = -70170,
        Y = 209430,
        Z = -19548.4,
    },
    reviveClearance = 2100,
    spawnClearance = 1400,
    phaseSpawnClearance = 1200,
    spawnPoints = { {
        X = -72133.96,
        Y = 211477.27,
        Z = -19522.533,
    }, {
        X = -71400,
        Y = 211150,
        Z = -19531.8,
    }, {
        X = -71175,
        Y = 212350,
        Z = -19536.2,
    }, {
        X = -70600,
        Y = 213100,
        Z = -19473.3,
    }, {
        X = -70300,
        Y = 212225,
        Z = -19482.0,
    }, {
        X = -69575,
        Y = 211625,
        Z = -19516.4,
    } },
    phaseReturnPoints = { {
        X = -70150,
        Y = 210150,
        Z = -19558.9,
    }, {
        X = -70025,
        Y = 210300,
        Z = -19555.8,
    }, {
        X = -70125,
        Y = 210400,
        Z = -19554.6,
    } },
    combatBoundary = { {
        X = -73400,
        Y = 210050,
        Z = 0,
    }, {
        X = -70000,
        Y = 209850,
        Z = 0,
    }, {
        X = -69000,
        Y = 210500,
        Z = 0,
    }, {
        X = -68100,
        Y = 211900,
        Z = 0,
    }, {
        X = -68325,
        Y = 213300,
        Z = 0,
    }, {
        X = -71400,
        Y = 213440,
        Z = 0,
    }, {
        X = -73400,
        Y = 213475,
        Z = 0,
    } },
    combatHeight = {
        min = -19783.4,
        max = -18884.2,
    },
    spawnTrace = {
        top = -19309.2,
        bottom = -19768.4,
        worldStaticFallback = true,
        localGround = true,
    },
    storySpawners = { "BP_AISpawner_C_UAID_E89C25A75434C44402_2043733559" },
    checkpointActors = {
        BP_AICombatTriggerVolume_C_UAID_BCFCE704F725B7C402_1918799910 = true,
        BP_AISpawnerTriggerVolume_C_UAID_E89C25A75434C44402_2043692557 = true,
        BP_FogDoor_C_UAID_BCFCE7058A98C29C02_2117606456 = true,
        BP_FogDoor_C_UAID_BCFCE7058A98C39C02_1344455633 = true,
        BP_MobDomain_C_UAID_E89C25A75434C44402_2043730558 = true,
        BP_AISpawner_C_UAID_E89C25A75434C44402_2043733559 = true,
    },
    openStoryDoors = { "BP_FogDoor_C_UAID_BCFCE7058A98C29C02_2117606456", "BP_FogDoor_C_UAID_BCFCE7058A98C39C02_1344455633" },
    chiLianUltimate = {
        center = {
            X = -70000,
            Y = 212100,
            Z = -19485.7,
        },
        snakes = { {
            X = -70800,
            Y = 211400,
            Z = -19528.7,
        }, {
            X = -69075,
            Y = 210950,
            Z = -19550.8,
        }, {
            X = -69150,
            Y = 212150,
            Z = -19514.8,
        }, {
            X = -70650,
            Y = 212850,
            Z = -19494.1,
        } },
    },
    lionArena = {
        center = {
            X = -70750,
            Y = 211675,
            Z = -18522.9,
        },
        extent = {
            X = 2250,
            Y = 1750,
            Z = 1240,
        },
        exits = { {
            X = -70450,
            Y = 212475,
            Z = -19483.4,
        }, {
            X = -69850,
            Y = 210325,
            Z = -19552.7,
        }, {
            X = -68700,
            Y = 211450,
            Z = -19547.4,
        }, {
            X = -70500,
            Y = 211700,
            Z = -19514.4,
        } },
    },
    arenaOnlyBell = true,
    componentPointMask = true,
    bossRecovery = true,
    roadFogs = { {
        name = "花田入口",
        scaleZ = 3.0,
        points = { {
            X = -69366.61106000001,
            Y = 208411.23843,
            Z = -19647.472999941805,
        }, {
            X = -68392.67088,
            Y = 209775.9017,
            Z = -19647.4730000673,
        }, {
            X = -67629.6729,
            Y = 210823.2998,
            Z = -19647.47300016485,
        } },
    } },
    retiredBell = "BP_MelodiousBell_Flow_C_UAID_60CF8480990914C402_1442932014",
    checkpointCreatesBell = true,
    zuoShangAnchors = {
        yaw = -94.4,
        ground = { {
            X = -69950,
            Y = 212650,
            Z = -19461.3,
        }, {
            X = -70000,
            Y = 212100,
            Z = -19485.7,
        }, {
            X = -69925,
            Y = 212925,
            Z = -19458.0,
        }, {
            X = -70075,
            Y = 211275,
            Z = -19522.2,
        } },
    },
}, {
    id = "waterfall",
    name = "大瀑布",
    runtimeModule = "XiguBossArena",
    walkIn = true,
    bellSaveId = "Bell_NLES_007",
    bellGround = {
        X = -58421.28,
        Y = 196991.55,
        Z = -17597.242,
    },
    entryGround = {
        X = -58328.73,
        Y = 197076.62,
        Z = -17566.3,
    },
    reviveClearance = 2100,
    spawnClearance = 1400,
    phaseSpawnClearance = 1200,
    spawnPoints = { {
        X = -66050,
        Y = 194225,
        Z = -17882.7,
    }, {
        X = -66925,
        Y = 194950,
        Z = -17906.1,
    }, {
        X = -65125,
        Y = 193650,
        Z = -17890.6,
    }, {
        X = -66975,
        Y = 193725,
        Z = -17905.6,
    }, {
        X = -64575,
        Y = 194825,
        Z = -17902.5,
    }, {
        X = -65425,
        Y = 195550,
        Z = -17898.9,
    } },
    phaseReturnPoints = { {
        X = -64050,
        Y = 195875,
        Z = -17902.7,
    }, {
        X = -64200,
        Y = 195975,
        Z = -17899.7,
    }, {
        X = -64100,
        Y = 195750,
        Z = -17898.9,
    } },
    combatBoundary = { {
        X = -68550,
        Y = 193275,
        Z = 0,
    }, {
        X = -65350,
        Y = 192675,
        Z = 0,
    }, {
        X = -63125,
        Y = 193700,
        Z = 0,
    }, {
        X = -62600,
        Y = 194850,
        Z = 0,
    }, {
        X = -64000,
        Y = 196650,
        Z = 0,
    }, {
        X = -65400,
        Y = 196800,
        Z = 0,
    }, {
        X = -68600,
        Y = 195825,
        Z = 0,
    } },
    combatHeight = {
        min = -18116.1,
        max = -17282.7,
    },
    spawnTrace = {
        top = -17707.7,
        bottom = -18101.1,
        worldStaticFallback = true,
        localGround = true,
    },
    storySpawners = { "BP_AISpawner_C_UAID_0A6230820DE8866302_2033638867", "BP_AISpawner_C_UAID_E89C25A75434C14402_1164908023" },
    checkpointActors = {
        BP_AICombatTriggerVolume_C_UAID_60CF848099090FFB02_1797190346 = true,
        BP_AISpawnerTriggerVolume_C_UAID_E89C25A75434C14402_1169200024 = true,
        BP_FogDoor_C_UAID_BCFCE7058A987E9C02_1911293727 = true,
        BP_FogDoor_C_UAID_BCFCE7058A987E9C02_2082254728 = true,
        BP_MobDomain_C_UAID_E89C25A75434C14402_1199167025 = true,
        BP_AISpawner_C_UAID_0A6230820DE8866302_2033638867 = true,
        BP_AISpawner_C_UAID_E89C25A75434C14402_1164908023 = true,
        BP_SpecialMove_UpRunning_C_UAID_BCFCE7058A98F77D02_2139624829 = true,
        BP_SpecialMove_UpRunning_C_UAID_BCFCE7058A98FA7D02_1733779346 = true,
    },
    openStoryDoors = { "BP_FogDoor_C_UAID_BCFCE7058A987E9C02_1911293727", "BP_FogDoor_C_UAID_BCFCE7058A987E9C02_2082254728" },
    chiLianUltimate = {
        center = {
            X = -66000,
            Y = 194725,
            Z = -17895.8,
        },
        snakes = { {
            X = -67400,
            Y = 193700,
            Z = -17917.2,
        }, {
            X = -64700,
            Y = 193750,
            Z = -17883.3,
        }, {
            X = -64750,
            Y = 195850,
            Z = -17893.9,
        }, {
            X = -67000,
            Y = 195900,
            Z = -17912.7,
        } },
    },
    lionArena = {
        center = {
            X = -65350,
            Y = 194625,
            Z = -16890.6,
        },
        extent = {
            X = 2300,
            Y = 1430,
            Z = 1240,
        },
        exits = { {
            X = -66900,
            Y = 194450,
            Z = -17888.1,
        }, {
            X = -64150,
            Y = 194450,
            Z = -17893.1,
        }, {
            X = -66000,
            Y = 193550,
            Z = -17882.3,
        }, {
            X = -65500,
            Y = 195650,
            Z = -17899.6,
        } },
    },
    checkpointBell = {
        id = "Bell_NLES_007",
        name = "MelodiousBell_UAID_74563CC57EE2E73C02_1922182620",
        classPath = "/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C",
        ignoreActivationTags = false,
    },
    arenaOnlyBell = true,
    componentPointMask = true,
    bossRecovery = true,
    roadFogs = { {
        name = "大瀑布铃后道路",
        scaleZ = 1.24,
        points = { {
            X = -59225,
            Y = 198350,
            Z = -17525,
        }, {
            X = -57575,
            Y = 198350,
            Z = -17525,
        }, {
            X = -56350,
            Y = 198350,
            Z = -17525,
        } },
    } },
    blockedTraversal = {
        BP_SpecialMove_UpRunning_C_UAID_BCFCE7058A98F77D02_2139624829 = true,
        BP_SpecialMove_UpRunning_C_UAID_BCFCE7058A98FA7D02_1733779346 = true,
    },
    zuoShangAnchors = {
        yaw = 30.53,
        ground = { {
            X = -66475,
            Y = 194450,
            Z = -17896.0,
        }, {
            X = -66000,
            Y = 194725,
            Z = -17895.8,
        }, {
            X = -66700,
            Y = 194300,
            Z = -17892.3,
        }, {
            X = -65300,
            Y = 195150,
            Z = -17899.8,
        } },
    },
}, {
    id = "scavenger",
    name = "清道夫豢养处",
    runtimeModule = "XiguBossArena",
    walkIn = true,
    bellSaveId = "Bell_QingDaoFu",
    bellGround = {
        X = -83790.62,
        Y = 205281.02,
        Z = 2016686.6,
    },
    entryGround = {
        X = -83681.98,
        Y = 205337.7,
        Z = 2016691.3,
    },
    reviveClearance = 2100,
    spawnClearance = 1400,
    phaseSpawnClearance = 1200,
    spawnPoints = { {
        X = -87475,
        Y = 202850,
        Z = 2015489.4,
    }, {
        X = -88200,
        Y = 203600,
        Z = 2015489.4,
    }, {
        X = -86500,
        Y = 202100,
        Z = 2015489.4,
    }, {
        X = -86850,
        Y = 204100,
        Z = 2015497.1,
    }, {
        X = -88250,
        Y = 202450,
        Z = 2015489.4,
    }, {
        X = -86150,
        Y = 203125,
        Z = 2015494.7,
    } },
    phaseReturnPoints = { {
        X = -84750,
        Y = 204850,
        Z = 2015539.7,
    }, {
        X = -84850,
        Y = 204775,
        Z = 2015540.4,
    }, {
        X = -84875,
        Y = 204900,
        Z = 2015544.2,
    } },
    combatBoundary = { {
        X = -89000,
        Y = 201650,
        Z = 0,
    }, {
        X = -86000,
        Y = 201675,
        Z = 0,
    }, {
        X = -85000,
        Y = 202575,
        Z = 0,
    }, {
        X = -84325,
        Y = 204100,
        Z = 0,
    }, {
        X = -84275,
        Y = 205400,
        Z = 0,
    }, {
        X = -88700,
        Y = 205225,
        Z = 0,
    }, {
        X = -89700,
        Y = 203200,
        Z = 0,
    } },
    combatHeight = {
        min = 2015279.4,
        max = 2016097.1,
    },
    spawnTrace = {
        top = 2015672.1,
        bottom = 2015294.4,
        worldStaticFallback = true,
        localGround = true,
    },
    storySpawners = { "BP_AISpawner_C_UAID_74563C6A7033A3D002_1370340626" },
    checkpointActors = {
        BP_FogDoor_C_UAID_E89C25A750C7BADA02_2084108616 = true,
        PBZ_MobDomain_C_UAID_74563C6A7033A3D002_1370221595 = true,
        BP_AICombatTriggerVolume_C_UAID_E89C25A750C79BDC02_1597949596 = true,
        BP_AISpawnerTriggerVolume_C_UAID_74563C6A7033A3D002_1370338625 = true,
        BP_AISpawner_C_UAID_74563C6A7033A3D002_1370340626 = true,
    },
    openStoryDoors = { "BP_FogDoor_C_UAID_E89C25A750C7BADA02_2084108616" },
    chiLianUltimate = {
        center = {
            X = -87400,
            Y = 203250,
            Z = 2015489.9,
        },
        snakes = { {
            X = -88600,
            Y = 202300,
            Z = 2015492.4,
        }, {
            X = -86300,
            Y = 202650,
            Z = 2015490.8,
        }, {
            X = -86400,
            Y = 204350,
            Z = 2015511.9,
        }, {
            X = -88425,
            Y = 204425,
            Z = 2015489.4,
        } },
    },
    lionArena = {
        center = {
            X = -86600,
            Y = 203400,
            Z = 2016491.3,
        },
        extent = {
            X = 2130,
            Y = 1700,
            Z = 1240,
        },
        exits = { {
            X = -88125,
            Y = 203250,
            Z = 2015489.4,
        }, {
            X = -85750,
            Y = 203300,
            Z = 2015519.4,
        }, {
            X = -87300,
            Y = 202050,
            Z = 2015489.4,
        }, {
            X = -87150,
            Y = 204200,
            Z = 2015496.3,
        } },
    },
    arenaOnlyBell = true,
    componentPointMask = true,
    bossRecovery = true,
    roadFogs = { {
        name = "高台铃后通道",
        scaleZ = 1.08,
        points = { {
            X = -83600,
            Y = 206400,
            Z = 2016660,
        }, {
            X = -83150,
            Y = 205735,
            Z = 2016660,
        }, {
            X = -82600,
            Y = 204975,
            Z = 2016660,
        } },
    } },
    entryPathStart = {
        X = -84950,
        Y = 205070,
        Z = 2015539.8,
    },
    checkpointBell = {
        id = "Bell_QingDaoFu",
        name = "BP_MelodiousBell_C_UAID_E89C25A750C791D602_1624784120",
        classPath = "/Game/PBZContent/Blueprint/Item/BP_MelodiousBell.BP_MelodiousBell_C",
    },
    zuoShangAnchors = {
        yaw = 31.12,
        ground = { {
            X = -87875,
            Y = 202975,
            Z = 2015489.4,
        }, {
            X = -87400,
            Y = 203250,
            Z = 2015489.9,
        }, {
            X = -88100,
            Y = 202825,
            Z = 2015489.4,
        }, {
            X = -86700,
            Y = 203675,
            Z = 2015493.9,
        } },
    },
}, {
    id = "longzhu",
    name = "龙柱试炼场",
    runtimeModule = "XiguBossArena",
    walkIn = true,
    bellSaveId = "Bell_DP_001",
    bellGround = {
        X = -39197.156,
        Y = 233272.02,
        Z = 10009004.0,
    },
    entryGround = {
        X = -39094.63,
        Y = 233204.89,
        Z = 10009036.7,
    },
    reviveClearance = 2100,
    spawnClearance = 1400,
    phaseSpawnClearance = 1200,
    spawnPoints = { {
        X = -39100,
        Y = 236600,
        Z = 10008869.0,
    }, {
        X = -40000,
        Y = 235950,
        Z = 10008859.0,
    }, {
        X = -38275,
        Y = 236000,
        Z = 10008873.7,
    }, {
        X = -39000,
        Y = 235600,
        Z = 10008829.0,
    }, {
        X = -40125,
        Y = 235200,
        Z = 10008869.4,
    }, {
        X = -37925,
        Y = 235275,
        Z = 10008919.6,
    } },
    phaseReturnPoints = { {
        X = -39095,
        Y = 234325,
        Z = 10008885.4,
    }, {
        X = -39225,
        Y = 234400,
        Z = 10008880.4,
    }, {
        X = -38975,
        Y = 234375,
        Z = 10008872.3,
    } },
    combatBoundary = { {
        X = -40400,
        Y = 234375,
        Z = 0,
    }, {
        X = -39575,
        Y = 234040,
        Z = 0,
    }, {
        X = -38575,
        Y = 234040,
        Z = 0,
    }, {
        X = -37350,
        Y = 234825,
        Z = 0,
    }, {
        X = -37250,
        Y = 235775,
        Z = 0,
    }, {
        X = -37700,
        Y = 236450,
        Z = 0,
    }, {
        X = -38625,
        Y = 236825,
        Z = 0,
    }, {
        X = -39700,
        Y = 236825,
        Z = 0,
    }, {
        X = -40550,
        Y = 236025,
        Z = 0,
    }, {
        X = -40750,
        Y = 235175,
        Z = 0,
    } },
    combatHeight = {
        min = 10008619.0,
        max = 10009519.6,
    },
    spawnTrace = {
        top = 10009094.6,
        bottom = 10008634.0,
        worldStaticFallback = true,
        localGround = true,
    },
    storySpawners = { "BP_AISpawner_C_UAID_E89C25A7512096DC02_423d05e8b5826f73_1075469218", "BP_AISpawner_C_UAID_E89C25A7512096DC02_423d05e8b5826f73_1579899219" },
    checkpointActors = {
        BP_FogDoor_C_UAID_E89C25A751204BF202_423d05e8b5826f73_1161163403 = true,
        BP_MobDomain_C_423d05e8b5826f73_0 = true,
        BP_MobDomain_C_UAID_BCFCE7058A98B4E502_423d05e8b5826f73_1660020056 = true,
        BP_MobDomain_C_UAID_BCFCE7058A98B4E502_423d05e8b5826f73_1662521057 = true,
        BP_MobDomain_C_UAID_BCFCE7058A98B4E502_423d05e8b5826f73_1664358058 = true,
        BP_MobDomain_C_UAID_BCFCE7058A98B4E502_423d05e8b5826f73_1668369059 = true,
        BP_AISpawnerTriggerVolume_C_423d05e8b5826f73_0 = true,
        BP_FogDoor_C_423d05e8b5826f73_0 = true,
        BP_AISpawner_C_UAID_E89C25A7512096DC02_423d05e8b5826f73_1075469218 = true,
        BP_AISpawner_C_UAID_E89C25A7512096DC02_423d05e8b5826f73_1579899219 = true,
    },
    openStoryDoors = { "BP_FogDoor_C_UAID_E89C25A751204BF202_423d05e8b5826f73_1161163403", "BP_FogDoor_C_423d05e8b5826f73_0" },
    chiLianUltimate = {
        center = {
            X = -39000,
            Y = 235475,
            Z = 10008831.7,
        },
        snakes = { {
            X = -40050,
            Y = 234900,
            Z = 10008883.5,
        }, {
            X = -38000,
            Y = 234900,
            Z = 10008915.6,
        }, {
            X = -38250,
            Y = 236450,
            Z = 10008879.7,
        }, {
            X = -40000,
            Y = 236150,
            Z = 10008859.0,
        } },
    },
    lionArena = {
        center = {
            X = -39025,
            Y = 235500,
            Z = 10009830.7,
        },
        extent = {
            X = 1450,
            Y = 1320,
            Z = 1240,
        },
        exits = { {
            X = -40200,
            Y = 235250,
            Z = 10008875.6,
        }, {
            X = -37825,
            Y = 235275,
            Z = 10008928.9,
        }, {
            X = -39050,
            Y = 234525,
            Z = 10008853.1,
        }, {
            X = -39025,
            Y = 236450,
            Z = 10008860.2,
        } },
    },
    checkpointBell = {
        id = "Bell_DP_001",
        name = "BP_BrokenBell_C_UAID_BCFCE7058A984EF202_1842238806",
        classPath = "/Game/PBZContent/Blueprint/Item/BP_BrokenBell.BP_BrokenBell_C",
        ignoreActivationTags = false,
    },
    arenaOnlyBell = true,
    componentPointMask = true,
    bossRecovery = true,
    zuoShangAnchors = {
        yaw = -94.72,
        ground = { {
            X = -38950,
            Y = 236025,
            Z = 10008839.1,
        }, {
            X = -39000,
            Y = 235475,
            Z = 10008831.7,
        }, {
            X = -38925,
            Y = 236300,
            Z = 10008850.4,
        }, {
            X = -39075,
            Y = 234650,
            Z = 10008840.1,
        } },
    },
} }

for _, scene in ipairs(scenes) do bindCheckpoint(scene) end
return scenes
