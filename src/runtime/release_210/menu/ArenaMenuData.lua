-- Arena display names, bell titles, region assignments and native preview art.
local Data = {
    scenes = {
        xigu = { region = "悲泣溪谷", image = "T_Map_XiGu", bellName = "三面封印地" },
        pengmeng = { region = "悲泣溪谷", image = "T_NLES_023", bellName = "斧老大斩落处" },
        cangang = { region = "悲泣溪谷", image = "T_NLES_002", bellName = "锈刃凉亭" },
        ahua = { region = "悲泣溪谷", image = "T_NLES_017", bellName = "血肉花田" },
        waterfall = { region = "悲泣溪谷", image = "T_NLES_007" },
        scavenger = { region = "悲泣溪谷", image = "T_QingDaoFu" },
        longzhu = { region = "悲泣溪谷", image = "T_DP001_005" },
        forest_bridge = { region = "血色森林", image = "T_LZSJ_003" },
        forest_trap = { region = "血色森林", image = "T_LZSJ_004", bellName = "亡命徒陷阱" },
        forest_iron_fist = { region = "血色森林", image = "T_LZSJ_007", label = "镜林入口", bellName = "镜林入口" },
        forest_silk_tree = { region = "血色森林", image = "T_LZSJ_010", label = "丝线缠绕的巨树" },
        forest_silk_tree_yucong = { region = "血色森林", image = "T_LZSJ_010", label = "丝线缠绕的巨树·雪",
            bellName = "丝线缠绕的巨树" },
        lake = { region = "陆家村地区", image = "T_BrokenBell_LJC_02" },
        lujia_zhuobi = { region = "陆家村地区", image = "T_Map_LuJiaCun", label = "陆家村口", bellName = "陆家村口" },
        lujia_bihai = { region = "陆家村地区", image = "T_SXC_02_01", label = "飞贼密道入口" },
        lujia_biyuan = { region = "陆家村地区", image = "T_SXC_02_04", label = "圣母雕像场", bellName = "圣母雕像场" },
        lujia_yuzan = { region = "陆家村地区", image = "T_SXC_02_03", label = "人偶试验场", bellName = "人偶试验场" },
        lujia_yanru = { region = "陆家村地区", image = "T_BrokenBell_LJC_01", label = "灭法之法·炎", bellName = "灭法之法" },
        lujia_danghui = { region = "陆家村地区", image = "T_SXC_01_04", label = "残偶弃置坑底" },
        zhengdaodaying_wanjun = { region = "正道大营", image = "T_YXZR_016", label = "大营正门", bellName = "箭塔之下" },
        zhengdaodaying_sangaota = { region = "正道大营", image = "T_YXZR_012", label = "三高塔", bellName = "三高塔" },
        zhengdaodaying_wulengshuang = { region = "正道大营", image = "T_YXZR_010", label = "幽禁之地" },
        zhengdaodaying_yubi = { region = "正道大营", image = "T_YXZR_009", label = "校场" },
        pangzhen_south_gate = { region = "庞镇地区", image = "T_SZ_002", label = "南门廊桥大石阶", bellName = "南门廊桥大石阶" },
        pangzhen_zhanqi = { region = "庞镇地区", image = "T_SZ_016", label = "黄家宅邸前路口", bellName = "黄家宅邸前路口" },
        pangzhen_wuxuan = { region = "庞镇地区", image = "T_SZ_005", label = "圆形戏台", bellName = "圆形戏台" },
        pangzhen_guwanyue = { region = "庞镇地区", image = "T_SZ_007", label = "戏声缥缈的水塘", bellName = "戏声缥缈的水塘" },
        pangzhen_youlong = { region = "庞镇地区", image = "T_Map_PangZhen", label = "浅水塘", bellName = "浅水塘" },
        pangzhen_changhong = { region = "庞镇地区", image = "T_SZ_023", label = "祠堂广场", size = "大型" },
        pangzhen_lion = { region = "庞镇地区", image = "T_SZ_025", label = "舞狮馆深处", bellName = "舞狮馆深处" },
        pangzhen_gouhun = { region = "庞镇地区", image = "T_SZ_032", label = "码头货栈", bellName = "码头货栈" },
        pangzhen_leiting = { region = "庞镇地区", image = "T_BrokenBell_Houjie_01", label = "灭法之法·雷", bellName = "灭法之法·雷" },
        meiguhu = { region = "梅谷湖", image = "T_MGH_004", label = "梅谷乐坊船坞" },
        meiguhu_duyan = { region = "梅谷湖", image = "T_MGH_003", label = "独眼之岛船坞" },
        meiguhu_youlong = { region = "梅谷湖", image = "T_MGH_007" },
        meiguhu_ajin = { region = "梅谷湖", image = "T_MGH_008", label = "陆家村浅滩船坞" },
        meiguhu_duanchang = { region = "梅谷湖", image = "T_MGH_011" },
        meiguhu_fengxue = { region = "梅谷湖", image = "T_LYZ_014" },
        meiguhu_guhe = { region = "梅谷湖", image = "T_MGH_01", label = "灭法之法·蛊", bellName = "灭法之法" },
        meiguhu_huodao = { region = "梅谷湖", image = "T_SZ_030" },
        jialongshan_tiesha = { region = "枷笼山", image = "T_DDSD_002" },
        jialongshan_bifeng = { region = "枷笼山", image = "T_DDSD_005" },
        jialongshan_yanyan = { region = "枷笼山", image = "T_DDSD_006", label = "宗祠外山门", bellName = "宗祠外山门" },
        jialongshan_jademask = { region = "枷笼山", image = "T_DDSD_007", label = "圣母娘娘宗祠" },
        jialongshan_huangxingzi = { region = "枷笼山", image = "T_DDSD_007", bellName = "宗祠内殿" },
        jialongshan_huangxingzi_p2 = { region = "枷笼山", image = "T_JJYBP_Brokenbell_01", label = "锯轮幻境", bellName = "锯轮幻境" },
        leidang = { region = "戏梦山庄", image = "T_XM_007" },
        ximeng_qiufeng = { region = "戏梦山庄", image = "T_XM_003" },
        ximeng_yuding = { region = "戏梦山庄", image = "T_XM_012" },
        night = { region = "断魂山", image = "T_TheEnd01", label = "故屋幻景" },
        duanhun_lizhe = { region = "断魂山", image = "T_DH_003" },
        duanhun_menghua = { region = "断魂山", image = "T_DH_004", label = "断魂崖" },
    },
    -- Single bosses for the scenes without recommendations in their map data.
    bossScenes = {
        BP_Monster_YuCong_FirstTime = "xigu",
        BP_Monster_PengMeng_Axe = "pengmeng",
        BP_Monster_MobMan_Elite_Sword = "cangang",
        BP_Monster_AHua_GuiTouDao = "ahua",
        BP_Monster_HookMan = "waterfall",
        BP_Monster_HookMan_P2 = "waterfall",
        BP_Monster_Scavenger = "scavenger",
        BP_Monster_QiShu_Bing = "scavenger",
        BP_Monster_MoTian = "longzhu",
        BP_Monster_HuaQianXIao = "forest_bridge",
        BP_Monster_JingYe = "forest_trap",
        BP_Monster_LuanShi = "forest_iron_fist",
        BP_Monster_ChiLian = "forest_silk_tree",
        BP_Monster_ChiLian_P2 = "forest_silk_tree",
        BP_Monster_YuCong_P1 = "forest_silk_tree_yucong",
        BP_Monster_Zhuobi = "lujia_zhuobi",
        BP_Monster_CanQu_BiHai = "lujia_bihai",
        BP_Monster_BiYuan = "lujia_biyuan",
        BP_Monster_FemaleVessel_YuZan = "lujia_yuzan",
        BP_Monster_QiShu_Huo = "lujia_yanru",
        BP_Monster_Danghui = "lujia_danghui",
        BP_Monster_MuXiaoKui = "lake",
        BP_Monster_MuXiaoKui_P2 = "lake",
        BP_Monster_Yuu = "lake",
        BP_Monster_TieGui = "lake",
        BP_Monster_YanQianSui = "meiguhu",
        BP_Monster_LeiDang = "leidang",
        BP_Monster_LeiDang_P2 = "leidang",
        BP_Monster_ZuoShang_Ending = "night",
        BP_Monster_ZuoShang_P2 = "night",
    },
    exclusiveScenes = {
        leidang = { BP_Monster_LeiDang = true, BP_Monster_LeiDang_P2 = true, gauntlet_leidang = true },
        forest_bridge = { BP_Monster_HuaQianXIao = true },
        forest_trap = { BP_Monster_JingYe = true },
        lujia_danghui = { BP_Monster_Danghui = true },
        pangzhen_south_gate = {
            BP_Monster_GuiChai_Red = true, BP_Monster_GuiChai_Red_P2 = true, gauntlet_guichai_red = true,
        },
        pangzhen_gouhun = { BP_Monster_GuiChai_Yellow_ShuangGou = true },
        ximeng_qiufeng = { BP_Monster_YingMei_RedShadowBoneBlade = true },
        jialongshan_yanyan = { BP_Monster_YanYan_Club = true },
        zhengdaodaying_yubi = { BP_Monster_YuBi = true },
        jialongshan_tiesha = { BP_Monster_MobMan_Elite = true },
        meiguhu_huodao = { BP_Monster_HuoDaoDuiZhang = true },
        meiguhu_guhe = { BP_Monster_QiShu_Du = true },
    },
    soloScenes = {
        meiguhu = true, longzhu = true, pangzhen_zhanqi = true, pangzhen_wuxuan = true,
        pangzhen_youlong = true, meiguhu_youlong = true, meiguhu_duanchang = true,
        zhengdaodaying_wanjun = true, zhengdaodaying_sangaota = true, zhengdaodaying_wulengshuang = true,
        cangang = true, ahua = true, waterfall = true, scavenger = true,
        forest_iron_fist = true, lujia_zhuobi = true, lujia_bihai = true, lujia_biyuan = true,
        lujia_yuzan = true, lujia_yanru = true, pangzhen_guwanyue = true,
        pangzhen_lion = true, pangzhen_leiting = true, meiguhu_ajin = true, ximeng_yuding = true,
        jialongshan_jademask = true, jialongshan_huangxingzi = true,
    },
    sceneMechanicBosses = {
        BP_Monster_ChiLian_P2 = true,
        BP_Monster_LionDancer_P2 = true,
        BP_Monster_LeiDang_P2 = true,
        BP_Monster_MBoss = true,
        BP_Monster_ZuoShang_Ending = true,
        BP_Monster_LengTu = true,
        BP_Monster_JingYe = true,
        BP_Monster_ChangHong_P2 = true,
        BP_Monster_Scavenger = true,
        BP_Monster_DuYanBoss = true,
        BP_Monster_HookMan_P2 = true,
        BP_Monster_HuaShan_Blue = true,
        BP_Monster_HuaShan_RedTroop_BigBro = true,
    },
    music = {
        Deluxe60 = { region = "序章", cover = "T_Deluxe60", seconds = 103, boss = "左殇（序章切磋）" },
        Deluxe62 = { region = "序章", cover = "T_Deluxe62", seconds = 283 },
        Deluxe51 = { region = "悲泣溪谷", cover = "T_Deluxe51", seconds = 126, boss = "三张脸的诡异魔偶" },
        Deluxe06 = { region = "悲泣溪谷", cover = "T_Deluxe06", seconds = 298, boss = "新娘阿花" },
        Deluxe38 = { region = "悲泣溪谷", cover = "T_Deluxe38", seconds = 211, boss = "魔渊" },
        Deluxe10 = { region = "悲泣溪谷", cover = "T_Deluxe10", seconds = 196, boss = "魔渊" },
        Deluxe64 = { region = "悲泣溪谷", cover = "T_Deluxe64", seconds = 217, boss = "暗魔天堡之主：魔渊" },
        Deluxe37 = { region = "血色森林", cover = "T_Deluxe37", seconds = 220 },
        Deluxe58 = { region = "血色森林", cover = "T_Deluxe58", seconds = 129 },
        Deluxe53 = { region = "血色森林", cover = "T_Deluxe53", seconds = 231, boss = "剑痴：花千笑" },
        Deluxe39 = { region = "血色森林", cover = "T_Deluxe39", seconds = 439, boss = "双蛇夫人：白赤练" },
        Deluxe47 = { region = "血色森林", cover = "T_Deluxe47", seconds = 253, boss = "人面榕树" },
        Deluxe42 = { region = "血色森林", cover = "T_Deluxe42", seconds = 200, boss = "玉妖、铁鬼" },
        Deluxe28 = { region = "血色森林", cover = "T_Deluxe28", seconds = 108 },
        Deluxe31 = { region = "陆家村地区", cover = "T_Deluxe31", seconds = 204 },
        Deluxe15 = { region = "陆家村地区", cover = "T_Deluxe15", seconds = 205 },
        Deluxe32 = { region = "陆家村地区", cover = "T_Deluxe32", seconds = 174 },
        Deluxe29 = { region = "陆家村地区", cover = "T_Deluxe29", seconds = 168, boss = "乐师偶：玉瓒" },
        Deluxe40 = { region = "陆家村地区", cover = "T_Deluxe40", seconds = 176, boss = "组织少主：沐小葵" },
        Deluxe41 = { region = "陆家村地区", cover = "T_Deluxe41", seconds = 278, boss = "沐小葵：铁玉女王" },
        Deluxe54 = { region = "正道大营", cover = "T_Deluxe54", seconds = 259 },
        Deluxe44 = { region = "正道大营", cover = "T_Deluxe44", seconds = 249, boss = "大师兄的绝望剑意" },
        Deluxe45 = { region = "正道大营", cover = "T_Deluxe45", seconds = 152 },
        Deluxe57 = { region = "庞镇地区", cover = "T_Deluxe57", seconds = 233 },
        Deluxe14 = { region = "庞镇地区", cover = "T_Deluxe14", seconds = 326, boss = "鬼差队长：火流星" },
        Deluxe13 = { region = "庞镇地区", cover = "T_Deluxe13", seconds = 94 },
        Deluxe20 = { region = "庞镇地区", cover = "T_Deluxe20", seconds = 230 },
        Deluxe23 = { region = "庞镇地区", cover = "T_Deluxe23", seconds = 185, boss = "女妖骨婉约" },
        Deluxe17 = { region = "庞镇地区", cover = "T_Deluxe17", seconds = 160, boss = "组织高手：长鸿" },
        Deluxe18 = { region = "庞镇地区", cover = "T_Deluxe18", seconds = 230, boss = "长鸿：雷电枪骑" },
        Deluxe35 = { region = "庞镇地区", cover = "T_Deluxe35", seconds = 116, boss = "舞狮尊主" },
        Deluxe36 = { region = "庞镇地区", cover = "T_Deluxe36", seconds = 297, boss = "舞狮尊主：烈焰" },
        Deluxe27 = { region = "庞镇地区", cover = "T_Deluxe27", seconds = 139, boss = "独眼弓客" },
        Deluxe63 = { region = "庞镇地区", cover = "T_Deluxe63", seconds = 194, boss = "水行帮主：游龙" },
        Deluxe12 = { region = "梅谷湖", cover = "T_Deluxe12", seconds = 227 },
        Deluxe52 = { region = "梅谷湖", cover = "T_Deluxe52", seconds = 257 },
        Deluxe46 = { region = "梅谷湖", cover = "T_Deluxe46", seconds = 230, boss = "琴女烟千岁" },
        Deluxe30 = { region = "枷笼山", cover = "T_Deluxe30", seconds = 133, boss = "横刀：毕峰" },
        Deluxe25 = { region = "枷笼山", cover = "T_Deluxe25", seconds = 244, boss = "昆仑叛教者：荒行子" },
        Deluxe59 = { region = "戏梦山庄", cover = "T_Deluxe59", seconds = 201 },
        Deluxe19 = { region = "戏梦山庄", cover = "T_Deluxe19", seconds = 144 },
        Deluxe49 = { region = "戏梦山庄", cover = "T_Deluxe49", seconds = 162, boss = "偃月刀偶：玉鼎" },
        Deluxe48 = { region = "戏梦山庄", cover = "T_Deluxe48", seconds = 180, boss = "组织高手：雷当" },
        Deluxe55 = { region = "戏梦山庄", cover = "T_Deluxe55", seconds = 208, boss = "雷当：独臂虎" },
        Deluxe50 = { region = "断魂山", cover = "T_Deluxe50", seconds = 353 },
        Deluxe24 = { region = "断魂山", cover = "T_Deluxe24", seconds = 364, boss = "力者和锯者" },
        Deluxe43 = { region = "断魂山", cover = "T_Deluxe43", seconds = 203 },
        Deluxe65 = { region = "断魂山", cover = "T_Deluxe65", seconds = 216 },
        Deluxe26 = { region = "断魂山", cover = "T_Deluxe26", seconds = 377, boss = "梦差：冷荼" },
        Deluxe33 = { region = "断魂山", cover = "T_Deluxe33", seconds = 154 },
        Deluxe34 = { region = "断魂山", cover = "T_Deluxe34", seconds = 204, boss = "梦华圣母" },
        Deluxe05 = { region = "断魂山", cover = "T_Deluxe05", seconds = 105, boss = "梦华圣母" },
        Deluxe01 = { region = "其他原声", cover = "T_Deluxe01", seconds = 75 },
        Deluxe02 = { region = "其他原声", cover = "T_Deluxe02", seconds = 153 },
        Deluxe03 = { region = "其他原声", cover = "T_Deluxe03", seconds = 210 },
        Deluxe04 = { region = "其他原声", cover = "T_Deluxe04", seconds = 157 },
        Deluxe11 = { region = "其他原声", cover = "T_Deluxe11", seconds = 189 },
        Deluxe07 = { region = "其他原声", cover = "T_Deluxe07", seconds = 149 },
        Deluxe22 = { region = "其他原声", cover = "T_Deluxe22", seconds = 182 },
        Deluxe21 = { region = "其他原声", cover = "T_Deluxe21", seconds = 145 },
        Deluxe61 = { region = "其他原声", cover = "T_Deluxe67", seconds = 279 },
        Deluxe16 = { region = "其他原声", cover = "T_Deluxe16", seconds = 180 },
        Deluxe08 = { region = "其他原声", cover = "T_Deluxe08", seconds = 320 },
        Deluxe09 = { region = "其他原声", cover = "T_Deluxe09", seconds = 113 },
        Deluxe66 = { region = "其他原声", cover = "T_Deluxe66", seconds = 282 },
        Deluxe56 = { region = "其他原声", cover = "T_Deluxe56", seconds = 76 },
    },
}

local function supportsScopedScenes(mode, encounter)
    return (mode == "practice" or mode == "challenge") and encounter and encounter.selectable
        and (encounter.category == "duel" or encounter.category == "gauntlet")
end

function Data.allowsScene(id, mode, encounter)
    local owners = Data.exclusiveScenes[id]
    if not owners and not Data.soloScenes[id] then return true end
    if not supportsScopedScenes(mode, encounter) then return false end
    if owners then return owners[encounter.id] == true end
    for _, stage in ipairs(encounter.stages) do
        for _, member in ipairs(stage.members) do
            if Data.sceneMechanicBosses[member.id] then return false end
        end
    end
    return true
end

-- Default routes may use the encounters' original maps for scene mechanics.
function Data.allowsAuthoredScene(id, mode, encounter, preferred, stageIndex)
    if not supportsScopedScenes(mode, encounter) then return false end
    local index = stageIndex or 1
    local stage = encounter.stages[index]
    if not stage then return false end
    local owners = Data.exclusiveScenes[id]
    if owners then
        if encounter.category ~= "gauntlet" or stage.sceneId ~= id then return false end
        for _, member in ipairs(stage.members) do
            if not owners[member.id] then return false end
        end
        return true
    end
    return Data.soloScenes[id] == true and (stage.sceneId == id or (index == 1 and preferred == id))
end

return Data
