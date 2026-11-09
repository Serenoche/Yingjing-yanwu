"""Validate the declarative encounter catalog and render its native Lua data.

No game or save access. The build imports encounter_catalog_lua(); this module
does not stage files unless its explicit --output command is invoked.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENCOUNTERS = ROOT / 'config/EncounterCatalog.json'
DEFAULT_BOSSES = ROOT / 'config/BossCatalog.json'
IDENTIFIER = re.compile(r'^[A-Za-z][A-Za-z0-9_]*$')
PAUSED_MEMBERS = set()  # Restored after native arena/phase validation in 1.0.3.


def _require(condition, reason):
    if not condition:
        raise ValueError(reason)


def _text(value, reason):
    _require(isinstance(value, str) and bool(value.strip())
             and not any(ord(char) < 32 for char in value), reason)
    return value


def _identifier(value, reason):
    _require(isinstance(value, str) and IDENTIFIER.fullmatch(value) is not None, reason)
    return value


def load_and_validate(encounter_path=None, boss_path=None):
    """Return normalized data with ordered entries; reject stale source pins."""
    encounter_path, boss_path = Path(encounter_path or DEFAULT_ENCOUNTERS), Path(boss_path or DEFAULT_BOSSES)
    boss_bytes = boss_path.read_bytes()
    bosses = json.loads(boss_bytes.decode('utf-8-sig'))
    source = json.loads(encounter_path.read_text(encoding='utf-8-sig'))
    _require(isinstance(bosses, dict) and isinstance(bosses.get('bosses'), list), 'Invalid BossCatalog object')
    boss_ids, folded_bosses = set(), set()
    for boss in bosses['bosses']:
        _require(isinstance(boss, dict), 'Invalid boss entry')
        identity = _identifier(boss.get('id'), 'Invalid boss ID')
        _require(identity.casefold() not in folded_bosses, f'Duplicate boss ID: {identity}')
        _text(boss.get('name'), f'Missing boss name: {identity}')
        _require(isinstance(boss.get('classPath'), str)
                 and re.fullmatch(r'/[A-Za-z0-9_./-]+_C', boss['classPath']) is not None,
                 f'Invalid boss class path: {identity}')
        boss_ids.add(identity)
        folded_bosses.add(identity.casefold())
    _require(bool(boss_ids), 'BossCatalog must not be empty')
    _require(isinstance(source, dict) and source.get('schemaVersion') == 1, 'Unsupported encounter schema')
    _require(source.get('sourceCatalog') == 'BossCatalog.json', 'Unexpected encounter source catalog')
    digest = hashlib.sha256(boss_bytes).hexdigest()
    _require(source.get('sourceCatalogSha256') == digest, 'Encounter catalog source hash does not match BossCatalog.json')
    categories, category_ids = [], set()
    _require(isinstance(source.get('categories'), list), 'Missing encounter categories')
    for category in source['categories']:
        _require(isinstance(category, dict), 'Invalid encounter category')
        identity = _identifier(category.get('id'), 'Invalid encounter category ID')
        _require(identity not in category_ids, f'Duplicate category: {identity}')
        category_ids.add(identity)
        categories.append({'id': identity, 'name': _text(category.get('name'), f'Missing category name: {identity}')})
    _require(category_ids == {'duel', 'gauntlet', 'group'}, 'Encounter categories must be duel, gauntlet and group')
    raw_entries = source.get('entries')
    _require(isinstance(raw_entries, list) and bool(raw_entries), 'Missing encounter entries')
    entries, used, duel_ids = [], set(), set()
    for order, entry in enumerate(raw_entries, 1):
        _require(isinstance(entry, dict), 'Invalid encounter entry')
        identity = _identifier(entry.get('id'), 'Invalid encounter ID')
        _require(identity.casefold() not in used, f'Duplicate encounter ID: {identity}')
        used.add(identity.casefold())
        name = _text(entry.get('name'), f'Missing encounter name: {identity}')
        category = entry.get('category')
        _require(category in category_ids, f'Unknown encounter category: {identity}')
        _require(type(entry.get('enabled')) is bool, f'Missing enabled flag: {identity}')
        enabled, status = entry['enabled'], entry.get('status')
        _require(status in {'ready', 'pending', 'disabled'}, f'Invalid encounter status: {identity}')
        _require(not enabled or status == 'ready', f'Enabled encounter is not ready: {identity}')
        notes = entry.get('notes')
        if notes is not None:
            _text(notes, f'Invalid encounter notes: {identity}')
        if status != 'ready':
            _require(not enabled and notes is not None, f'Unavailable encounter must explain why: {identity}')
        raw_stages = entry.get('stages')
        _require(isinstance(raw_stages, list), f'Missing encounter stages: {identity}')
        stages = []
        for index, stage in enumerate(raw_stages, 1):
            _require(isinstance(stage, dict) and isinstance(stage.get('members'), list)
                     and bool(stage['members']), f'Empty or invalid stage: {identity}/{index}')
            members = stage['members']
            _require(all(isinstance(member, str) and member in boss_ids for member in members),
                     f'Unknown stage member: {identity}/{index}')
            _require(len(set(members)) == len(members), f'Duplicate stage member: {identity}/{index}')
            stages.append({'members': members[:]})
        if enabled:
            _require(bool(stages), f'Enabled encounter has no stages: {identity}')
            _require(identity != 'gauntlet_lengtu' and all('BP_Monster_LengTu' not in stage['members'] for stage in stages),
                     'LengTu challenge has been retired')
            _require(identity != 'group_mob_rioters', 'Mob rioters group has been retired')
            _require(not any(PAUSED_MEMBERS.intersection(stage['members']) for stage in stages),
                     'Lion dancer encounters have been temporarily retired')
        if category == 'duel':
            _require(len(stages) == 1 and stages[0]['members'] == [identity] and identity in boss_ids,
                     f'Duel must wrap its original single boss ID: {identity}')
            duel_ids.add(identity)
        elif category == 'gauntlet' and enabled:
            native_lengtu = entry.get('adapter') == 'lengtu'
            _require(len(stages) >= 2 or (native_lengtu and identity == 'gauntlet_lengtu'
                and len(stages) == 1 and stages[0]['members'] == ['BP_Monster_LengTu']),
                f'Gauntlet requires sequential stages or its verified native summoner: {identity}')
        elif category == 'group' and enabled:
            _require(len(stages) == 1 and len(stages[0]['members']) >= 2,
                     f'Group requires one simultaneous multi-member stage: {identity}')
        normalized = {'id': identity, 'name': name, 'category': category, 'enabled': enabled,
                      'status': status, 'order': order, 'stages': stages}
        if entry.get('adapter') is not None:
            _require(entry['adapter'] == 'lengtu' and identity == 'gauntlet_lengtu', 'Unknown encounter adapter')
            normalized['adapter'] = entry['adapter']
            _require(entry.get('authoredPhaseCount') == 5 and entry.get('summonWaveCount') == 4,
                     'Native LengTu phase metadata differs from the audited abilities')
            normalized['authoredPhaseCount'], normalized['summonWaveCount'] = 5, 4
        if entry.get('portraitMembers') is not None:
            portraits = entry['portraitMembers']
            display_only = {'BP_Monster_FemaleDoll_Golden', 'BP_Monster_FemaleDoll_TieChiSan'}
            _require(isinstance(portraits, list) and len(portraits) <= 64 and len(set(portraits)) == len(portraits)
                and all(isinstance(member, str) and member in boss_ids | display_only for member in portraits),
                f'Invalid encounter portrait members: {identity}')
            normalized['portraitMembers'] = portraits[:]
        if notes is not None:
            normalized['notes'] = notes
        entries.append(normalized)
    exclusions, excluded_ids = [], set()
    _require(isinstance(source.get('duelExclusions'), list), 'Missing explicit duel exclusions')
    for entry in source['duelExclusions']:
        _require(isinstance(entry, dict), 'Invalid duel exclusion')
        identity = entry.get('bossId')
        _require(isinstance(identity, str) and identity in boss_ids and identity not in excluded_ids,
                 f'Unknown or duplicate duel exclusion: {identity}')
        excluded_ids.add(identity)
        exclusions.append({'bossId': identity, 'reason': _text(entry.get('reason'), f'Missing exclusion reason: {identity}')})
    _require(excluded_ids == boss_ids - duel_ids, 'Duel exclusions must exactly cover omitted original boss IDs')
    return {'schemaVersion': 1, 'sourceCatalogSha256': digest,
            'categories': categories, 'entries': entries, 'duelExclusions': exclusions}


def _lua(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return '{' + ', '.join(_lua(item) for item in value) + '}'
    if isinstance(value, dict):
        return '{' + ', '.join('[' + _lua(key) + '] = ' + _lua(item) for key, item in value.items()) + '}'
    raise ValueError(f'Unsupported generated Lua value: {type(value).__name__}')


def encounter_catalog_lua(encounter_path=None, boss_path=None):
    """Build imports this function and stages its bytes as GeneratedEncounterCatalog.lua."""
    return ('-- Generated from validated EncounterCatalog.json; do not edit.\nreturn '
            + _lua(load_and_validate(encounter_path, boss_path)) + '\n').encode('utf8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--encounters', type=Path)
    parser.add_argument('--bosses', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    data = encounter_catalog_lua(args.encounters, args.bosses)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(data)
    print(f'Validated encounter Lua: {len(data)} bytes -> {args.output}')


if __name__ == '__main__':
    main()
