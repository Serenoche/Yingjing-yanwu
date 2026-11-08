"""Build challenge definitions from stable IDs without changing BossCatalog."""
import hashlib
import json
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'config/BossCatalog.json'
OUTPUT = ROOT / 'config/EncounterCatalog.json'

DUEL_EXCLUSIONS = {
    'BP_Monster_LengTu': '梦差冷荼及其原生场景已撤下；保留底层数据供历史与画像解析。',
    'BP_Monster_MoTian_LongZhu_01': '移除金面具黑衣人单挑入口。',
    'BP_Monster_Maddoctor_Elite': '移除神医单挑入口。',
    'BP_Monster_YuCong': '玉琮暂采用统一P1入口；原战斗本体保留在BossCatalog。',
    'BP_Monster_YuCong_WuLi': '钢刃保留用于连战或群战，不单独列出。',
    'BP_Monster_YuCong_Bing': '寒冰保留用于连战或群战，不单独列出。',
    'BP_Monster_YuCong_HunDun': '混沌保留用于连战或群战，不单独列出。',
}

GAUNTLETS = [
    ('hookman', '穷途末路', [['HookMan'], ['HookMan_P2']]),
    ('chilian', '镜中蛇', [['ChiLian'], ['ChiLian_P2']]),
    ('yucong', '三位一体', [['YuCong_P1'], ['YuCong_WuLi', 'YuCong_Bing', 'YuCong_HunDun']]),
    ('muxiaokui', '少主的决意', [['MuXiaoKui'], ['MuXiaoKui_P2'], ['Yuu', 'TieGui']]),
    ('huashan', '绝命鸳鸯', [['HuaShan_Blue'], ['HuaShan_JianOu', 'EMei_Sword_Top']]),
    ('guichai_red', '身不由己', [['GuiChai_Red'], ['GuiChai_Red_P2']]),
    ('changhong', '雷鸣枪骑', [['ChangHong_Spear'], ['ChangHong_P2']]),
    ('liondancer', '最后的传承', [['LionDancer'], ['LionDancer_P2']]),
    ('mboss', '绝望的背叛', [['MBoss'], ['MBossVariants']]),
    ('leidang', '忠义之虎', [['LeiDang'], ['LeiDang_P2']]),
    ('powerman', '伽刚特尔', [['PowerMan'], ['PowerMan_P2']]),
    ('lengtu', '梦差：冷荼', [['LengTu']]),
    ('zuoshang', '宿命对决', [['ZuoShang_Ending'], ['ZuoShang_P2']]),
    ('miefa', '灭法之法', [['QiShu_Huo'], ['QiShu_Lei'], ['QiShu_Du'], ['QiShu_Bing']]),
    ('guaimian', '怪面之乱', [['HuaQianXIao'], ['LuanShi'], ['JingYe'], ['ChiLian'], ['ChiLian_P2']]),
    ('rocksolid', '坚如磐石', [['Zhuobi'], ['WuXuan']]),
]

GROUPS = [
    ('mob_rioters', '痴狂暴徒', [['MobMan_Elite_Sword', 'MobMan_Elite']]),
    ('guichai', '鬼差队', [['GuiChai_Yellow_MoDao', 'GuiChai_Yellow_ShuangGou', 'GuiChai_Cyan_ShuangYue']]),
    ('dancers', '轻歌曼舞', [['GuWanYue', 'YanQianSui']]),
    ('order_masters', '组织高手', [['ChangHong_Spear', 'LeiDang']]),
    ('yucong', '玉琮', [['YuCong_WuLi', 'YuCong_Bing', 'YuCong_HunDun']]),
    ('last_will', '最后的意志', [['WuLengShuang', 'YuBi']]),
    ('thunder_tiger', '雷鸣虎啸', [['ChangHong_P2', 'LeiDang_P2']]),
]

DUEL_NAMES = {'BP_Monster_ZuoShang_Ending': '组织冥主：左殇'}
ENTRY_METADATA = {
    'BP_Monster_LionDancer': {
        'enabled': False, 'status': 'disabled',
        'notes': '舞狮尊主相关战斗暂时下架，待后续调整；保留原始名称、成员与阶段，方便恢复。',
    },
    'BP_Monster_LionDancer_P2': {
        'enabled': False, 'status': 'disabled',
        'notes': '舞狮尊主相关战斗暂时下架，待后续调整；保留原始名称、成员与阶段，方便恢复。',
    },
    'gauntlet_liondancer': {
        'enabled': False, 'status': 'disabled',
        'notes': '舞狮尊主相关战斗暂时下架，待后续调整；保留原始名称、成员与阶段，方便恢复。',
    },
    'gauntlet_lengtu': {
        'enabled': False, 'status': 'disabled',
        'notes': '此挑战及其原生场景已撤下；原始首领与画像数据仅供历史记录解析。',
        'adapter': 'lengtu', 'authoredPhaseCount': 5, 'summonWaveCount': 4,
        'portraitMembers': ['BP_Monster_Scavenger', 'BP_Monster_GuiChai_Cyan_ShuangYue',
                            'BP_Monster_GuiChai_Yellow_MoDao', 'BP_Monster_YuBi', 'BP_Monster_FemaleVessel_YuDing',
                            'BP_Monster_FemaleDoll_Golden', 'BP_Monster_FemaleDoll_TieChiSan'],
    },
    'group_mob_rioters': {
        'enabled': False, 'status': 'disabled',
        'notes': '痴狂暴徒组合入口已撤下；保留原始成员与名称供旧配置及历史记录解析，两个单体挑战保持可用。',
    },
}


def make_catalog(source_bytes):
    bosses = json.loads(source_bytes)['bosses']
    known = {boss['id']: boss for boss in bosses}
    if len(known) != 74 or not DUEL_EXCLUSIONS.keys() <= known.keys():
        raise ValueError('The expected 74-boss source or a filtered ID changed')
    entries = [{'id': boss['id'], 'name': DUEL_NAMES.get(boss['id'], boss['name']), 'category': 'duel',
                'enabled': True, 'status': 'ready', 'stages': [{'members': [boss['id']]}]}
               for boss in bosses if boss['id'] not in DUEL_EXCLUSIONS]
    for category, definitions in [('gauntlet', GAUNTLETS), ('group', GROUPS)]:
        for suffix, name, stages in definitions:
            entry = {'id': category + '_' + suffix, 'name': name, 'category': category,
                     'enabled': True, 'status': 'ready',
                     'stages': [{'members': ['BP_Monster_' + member for member in members]} for members in stages]}
            entries.append(entry)
    for entry in entries:
        entry.update(deepcopy(ENTRY_METADATA.get(entry['id'], {})))
        for stage in entry['stages']:
            if not stage['members'] or len(stage['members']) != len(set(stage['members'])) or any(member not in known for member in stage['members']):
                raise ValueError('Invalid encounter stage: ' + entry['id'])
        if entry['enabled'] and not entry['stages']:
            raise ValueError('An enabled encounter must have at least one stage')
    if len({entry['id'] for entry in entries}) != len(entries):
        raise ValueError('Encounter IDs must be unique')
    return {'schemaVersion': 1, 'sourceCatalog': 'BossCatalog.json',
            'sourceCatalogSha256': hashlib.sha256(source_bytes).hexdigest(),
            'categories': [{'id': 'duel', 'name': '一决高下（对决）'}, {'id': 'gauntlet', 'name': '血战到底（连战）'}, {'id': 'group', 'name': '一夫当关（群战）'}],
            'stageSemantics': 'stages按顺序进行；同一stage.members中的角色同时出现。',
            'duelExclusions': [{'bossId': key, 'reason': reason} for key, reason in DUEL_EXCLUSIONS.items()],
            'entries': entries}


def main():
    original = SOURCE.read_bytes()
    catalog = make_catalog(original)
    OUTPUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    if SOURCE.read_bytes() != original:
        raise RuntimeError('Read-only source changed during catalog creation')
    print(json.dumps({'output': str(OUTPUT), 'entries': len(catalog['entries']),
                      'counts': {category: sum(entry['category'] == category for entry in catalog['entries']) for category in ['duel', 'gauntlet', 'group']},
                      'pending': [entry['id'] for entry in catalog['entries'] if not entry['enabled']]}))


if __name__ == '__main__':
    main()
