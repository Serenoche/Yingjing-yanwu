-- Native collection row IDs and titles from DT_BonusMusic and the zh-Hans game strings.
-- Only identifiers and titles are recorded here. The game supplies all audio.
local tracks = {
    { "Deluxe01", "玉汝于成" },
    { "Deluxe02", "今昼如昨 2026 大笛吉他曲" },
    { "Deluxe03", "妙手空空" },
    { "Deluxe04", "天地共釂" },
    { "Deluxe11", "侠意于成" },
    { "Deluxe37", "神驰其间" },
    { "Deluxe58", "一整夜的雨 2026" },
    { "Deluxe59", "剑啸川河 2026" },
    { "Deluxe60", "殇阙 2026" },
    { "Deluxe62", "跋扈万里 2026" },
    { "Deluxe51", "三脸人偶" },
    { "Deluxe06", "鬼花轿子" },
    { "Deluxe07", "幻梦泡影" },
    { "Deluxe53", "醉剑千笑" },
    { "Deluxe22", "血色密谋" },
    { "Deluxe39", "白蛇赤炼" },
    { "Deluxe47", "嗔恨修罗" },
    { "Deluxe21", "忆少年时" },
    { "Deluxe31", "圣母秘密" },
    { "Deluxe15", "雨霁云开" },
    { "Deluxe32", "荡秽旧屋" },
    { "Deluxe29", "玉瓒琵琶" },
    { "Deluxe40", "葵 2026" },
    { "Deluxe41", "向阳而生" },
    { "Deluxe42", "铁玉合璧" },
    { "Deluxe61", "心湖（演唱：张靓颖）" },
    { "Deluxe57", "雨中秘密 2026" },
    { "Deluxe14", "冥火流星" },
    { "Deluxe13", "八卦童子" },
    { "Deluxe20", "雁字迟归" },
    { "Deluxe23", "婉约歌声" },
    { "Deluxe17", "红缨枪使" },
    { "Deluxe18", "何似飞鸿" },
    { "Deluxe35", "醒狮擂鼓" },
    { "Deluxe36", "狮尊归位" },
    { "Deluxe54", "凄声阵阵" },
    { "Deluxe44", "绝望剑意" },
    { "Deluxe16", "善恶三道" },
    { "Deluxe45", "残阳垂暮" },
    { "Deluxe30", "横刀披靡" },
    { "Deluxe25", "血滴荒行" },
    { "Deluxe12", "十日月星 尺八吉他曲" },
    { "Deluxe52", "十日月星 古琴曲" },
    { "Deluxe46", "古琴千岁" },
    { "Deluxe27", "独眼厉弓" },
    { "Deluxe63", "蛟龙洗巷 2026" },
    { "Deluxe19", "七巧郎君" },
    { "Deluxe49", "偃月青龙" },
    { "Deluxe48", "千钧雷当" },
    { "Deluxe55", "英雄终曲" },
    { "Deluxe28", "冰雪锢囚" },
    { "Deluxe50", "咫尺山巅" },
    { "Deluxe24", "力者锯者" },
    { "Deluxe43", "新的约定" },
    { "Deluxe65", "最后一役 2026" },
    { "Deluxe38", "赤黑传承" },
    { "Deluxe08", "魔堡觉醒 2026" },
    { "Deluxe09", "无愧于心" },
    { "Deluxe10", "魔渊往日" },
    { "Deluxe64", "赤黑诀别" },
    { "Deluxe26", "囚命之囚" },
    { "Deluxe33", "至高圣者" },
    { "Deluxe34", "圣母降临" },
    { "Deluxe05", "梦华出世" },
    { "Deluxe66", "劫（演唱：沙宝亮）" },
    { "Deluxe56", "六位时成" },
}

-- Start with the matching native opening. For tracks that span two states,
-- request the loop near the Wwise exit cue of the first segment.
local combat = {
    Deluxe14 = { "PangZhen", "HuoLiuXing_P1", "HuoLiuXing_P2", 92.9 },
    Deluxe15 = { "LuJiaCun", "VillageDeepInside_Engage" },
    Deluxe17 = { "PangZhen", "ChangHong_P1" },
    Deluxe18 = { "PangZhen", "ChangHong_P2" },
    Deluxe20 = { "PangZhen", "BackStreet2_Engage", ostIntro = 112.7 },
    Deluxe23 = { "PangZhen", "GuWanYue_Engage" },
    Deluxe24 = { "DuanHun", "LiJu_P2", ostIntro = 194.4 },
    Deluxe25 = { "VS2", "Boss_Big", ostIntro = 15.5 },
    Deluxe26 = { "DuanHun", "LengTu_P1", ostIntro = 30.0 },
    Deluxe27 = { "PangZhen", "DuYan_Engage" },
    Deluxe28 = { "FuJiZhiLin", "Ice_Engage" },
    Deluxe29 = { "LuJiaCun", "Yuzan", ostIntro = 35.7 },
    Deluxe30 = { "VS2", "Boss_Small" },
    Deluxe34 = { "DuanHun", "MengHua" },
    Deluxe35 = { "PangZhen", "WuShi_P1", ostIntro = 16.0 },
    Deluxe36 = { "PangZhen", "WuShi_P2" },
    Deluxe37 = { "FuJiZhiLin", "Forest1_2_Engage" },
    Deluxe38 = { "XiGu", "MoYuan_P0" },
    Deluxe39 = { "FuJiZhiLin", "SnakebattleP1", "SnakebattleP2", 205.6 },
    Deluxe40 = { "LuJiaCun", "MuXiaoKui_P1", ostIntro = 39.8 },
    Deluxe41 = { "LuJiaCun", "MuXiaoKui_P2" },
    Deluxe42 = { "FuJiZhiLin", "YuYaoTieGui_Engage" },
    Deluxe44 = { "ZhengDaoDaYing", "JianOu_P2", "JianOu_P3", 115.3 },
    Deluxe45 = { "ZhengDaoDaYing", "CampInside_Engage" },
    Deluxe46 = { "PangZhen", "YanQianSui_Engage" },
    Deluxe47 = { "FuJiZhiLin", "BanyanTreeBoss" },
    Deluxe48 = { "XiMengShanZhuang", "LeiDang_P1" },
    Deluxe49 = { "XiMengShanZhuang", "YuDing_Engage", ostIntro = 15.25 },
    Deluxe50 = { "DuanHun", "DH_Part2_Engage", ostIntro = 193.3 },
    Deluxe51 = { "FuJiZhiLin", "HunDun_P1" },
    Deluxe53 = { "FuJiZhiLin", "DrunkSword" },
    Deluxe54 = { "ZhengDaoDaYing", "CampCenter_Engage" },
    Deluxe55 = { "XiMengShanZhuang", "LeiDang_P2" },
    Deluxe57 = { "PangZhen", "TownOfDeath_Engage" },
    Deluxe58 = { "FuJiZhiLin", "AboveFall_Engage" },
    Deluxe59 = { "XiMengShanZhuang", "XM_Elite_Engage" },
    Deluxe60 = { "Prologue", "YoungPractice_Engage_01", "YoungPractice_Engage_02", 48.8 },
    Deluxe62 = { "Prologue", "Duel_Engage_02", ostIntro = 2.72 },
    Deluxe63 = { "PangZhen", "YouLongBang_Engage" },
    Deluxe64 = { "XiGu", "MoYuan_P1", "MoYuan_P2", 49.0 },
}

-- Stock PBZMusicVolume combat states. Shared encounter music is grouped
-- by the region and phase that owns the game's authored Wwise event.
local bosses = {}
local function bind(region, state, targets, loopState, introSeconds)
    local cue = { region, state, loopState, introSeconds }
    for _, id in ipairs(targets) do bosses["BP_Monster_" .. id] = cue end
end

bind("XiGu", "EliteMonster_Engage", { "MobMan_Elite_Sword" })
bind("XiGu", "PengMeng_Engage", { "PengMeng_Axe" })
bind("XiGu", "GouZhe_Engage", { "HookMan" })
bind("XiGu", "GouZhe_P2_Engage", { "HookMan_P2" })
bind("XiGu", "GhostBride_Engage", { "AHua_GuiTouDao" })
bind("XiGu", "QingDaoFu", { "Scavenger" })
bind("XiGu", "MoYuan_P1", { "MoTian" }, "MoYuan_P2", 49.0)
bind("XiGu", "MoYuan_P0", { "MoTian_LongZhu_01" })

bind("FuJiZhiLin", "DrunkSword", { "HuaQianXIao" })
bind("FuJiZhiLin", "Jingye_TieKuang", { "LuanShi", "JingYe" })
bind("FuJiZhiLin", "SnakebattleP1", { "ChiLian" })
bind("FuJiZhiLin", "SnakebattleP2", { "ChiLian_P2" })
bind("FuJiZhiLin", "HunDun_P1", { "YuCong_FirstTime", "YuCong", "YuCong_P1", "YuCong_WuLi" })
bind("FuJiZhiLin", "HunDun_P2", { "YuCong_HunDun" })
bind("FuJiZhiLin", "HunDun_P3", { "YuCong_Bing" })
bind("FuJiZhiLin", "YuYaoTieGui_Engage", { "Yuu", "TieGui" })

bind("LuJiaCun", "ZhuoBi", { "Zhuobi" })
bind("LuJiaCun", "Lament_01_Engage", { "CanQu_BiHai" })
bind("LuJiaCun", "Lament_02_Engage", { "BiYuan" })
bind("LuJiaCun", "Yuzan", { "FemaleVessel_YuZan" })
bind("LuJiaCun", "MieFaBoss_Engage", { "QiShu_Bing", "QiShu_Huo", "QiShu_Du", "QiShu_Lei" })
bind("LuJiaCun", "DangHui", { "Danghui" })
bind("LuJiaCun", "MuXiaoKui_P1", { "MuXiaoKui" })
bind("LuJiaCun", "MuXiaoKui_P2", { "MuXiaoKui_P2" })

bind("ZhengDaoDaYing", "XiaoXue_Engage", { "XiaoXue" })
bind("ZhengDaoDaYing", "WanJun", { "WanJun_JinGua" })
bind("ZhengDaoDaYing", "NvJianKe", { "EMei_Sword_Top" })
bind("ZhengDaoDaYing", "JianOu_P1", { "HuaShan_Blue" })
bind("ZhengDaoDaYing", "JianOu_P2", { "HuaShan_JianOu" })
bind("ZhengDaoDaYing", "WuLengShuang", { "WuLengShuang" })
bind("ZhengDaoDaYing", "YuBi", { "YuBi" })
bind("ZhengDaoDaYing", "Doctor", { "Maddoctor_Elite" })

bind("PangZhen", "HuoLiuXing_P1", { "GuiChai_Red" })
bind("PangZhen", "HuoLiuXing_P2", { "GuiChai_Red_P2" })
bind("PangZhen", "GuiChaiElite_Engage", { "GuiChai_Yellow_MoDao", "GuiChai_Yellow_ShuangGou", "GuiChai_Cyan_ShuangYue" })
bind("PangZhen", "XueJianke_Engage", { "HuaShan_RedTroop_BigBro" })
bind("PangZhen", "DuYan_Engage", { "DuYanBoss" })
bind("PangZhen", "YouLongBang_Engage", { "YouLong_Harpoon", "YouLong_SecondBrother" })
bind("PangZhen", "YanQianSui_Engage", { "YanQianSui" })
bind("PangZhen", "WuXuan_Engage", { "HuoDaoDuiZhang", "WuXuan" })
bind("PangZhen", "GuWanYue_Engage", { "GuWanYue" })
bind("PangZhen", "ChangHong_P1", { "ChangHong_Spear" })
bind("PangZhen", "ChangHong_P2", { "ChangHong_P2" })
bind("PangZhen", "WuShi_P1", { "LionDancer" })
bind("PangZhen", "WuShi_P2", { "LionDancer_P2" })
bind("PangZhen", "FengXueDaoKe_Engage", { "FengXueDaoKe" })

bind("VS2", "Monster_Elite", { "MobMan_Elite", "YanYan_Club" })
bind("VS2", "Boss_Small", { "GreatBladeMan" })
bind("VS2", "Boss_Middle", { "JadeMaskMan" })
bind("VS2", "Boss_Big", { "MBoss" })
bind("VS2", "Boss_Big_P2", { "MBossVariants" })
bind("XiMengShanZhuang", "XM_Part2_Engage", { "YingMei_RedShadowBoneBlade" })
bind("XiMengShanZhuang", "YuDing_Engage", { "FemaleVessel_YuDing" })
bind("XiMengShanZhuang", "LeiDang_P1", { "LeiDang" })
bind("XiMengShanZhuang", "LeiDang_P2", { "LeiDang_P2" })
bind("DuanHun", "LiJu_P1", { "PowerMan" })
bind("DuanHun", "LiJu_P2", { "PowerMan_P2" })
bind("DuanHun", "LengTu_P1", { "LengTu" })
bind("DuanHun", "MengHua", { "MengHua" })
bind("DuanHun", "ZuoShang_P1", { "ZuoShang_Ending" })
bind("DuanHun", "ZuoShang_P2", { "ZuoShang_P2" })

-- DT_BonusMusic row Deluxe61 points at the replacement vocal event.
return { tracks = tracks, combat = combat, eventOverrides = { Deluxe61 = "Deluxe67" }, bosses = bosses }
