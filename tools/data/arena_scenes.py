"""Validate scene settings shared by save staging and native runtime."""
import json
import math
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / 'config/ArenaScenes.json'


def _vector(value, keys):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValueError('Invalid arena transform')
    if any(type(value[key]) not in (int, float) or not math.isfinite(value[key]) for key in keys):
        raise ValueError('Non-finite arena transform')


def load_scenes():
    data = json.loads(SOURCE.read_text(encoding='utf-8-sig'))
    if data.get('schemaVersion') != 1 or data.get('defaultScene') != 'night':
        raise ValueError('Invalid arena scene schema')
    if [scene['id'] for scene in data['scenes']] != ['night', 'lake']:
        raise ValueError('Unexpected arena scenes')
    for scene in data['scenes']:
        expected = {'night': ('PBZ_Duanhun_WP', 'BrokenBell_TheEnd01'),
                    'lake': ('PBZ_Zhengdaodaying_WP', 'BrokenBell_LJC_02')}[scene['id']]
        if (scene['map'], scene['bellSaveId']) != expected:
            raise ValueError('Unexpected arena map or bell')
        for key in ('anchor', 'reviveLocation'):
            _vector(scene[key], ('X', 'Y', 'Z'))
        for key in ('rotation', 'camera'):
            _vector(scene[key], ('Pitch', 'Yaw', 'Roll'))
        _vector(scene['bell']['location'], ('X', 'Y', 'Z'))
        _vector(scene['bell']['interactionPoint'], ('X', 'Y', 'Z'))
        _vector(scene['bell']['rotation'], ('Pitch', 'Yaw', 'Roll'))
        if len(scene['spawnPoints']) != 6:
            raise ValueError('Each scene requires six spawn choices')
        for point in scene['spawnPoints']:
            _vector(point, ('X', 'Y'))
        for index, point in enumerate(scene['spawnPoints']):
            for other in scene['spawnPoints'][index + 1:]:
                if math.hypot(point['X'] - other['X'], point['Y'] - other['Y']) < 750:
                    raise ValueError('Spawn choices must respect the runtime occupied radius of 750 cm')
        trace = scene['spawnTrace']
        if not trace['top'] > trace['bottom']:
            raise ValueError('Invalid scene ground trace')
        if scene['gameModeOptions'] != '':
            raise ValueError('Unexpected adult arena game mode')
        if 'loadingLocation' in scene or 'spawnSafety' in scene:
            raise ValueError('Retired daylight/high-altitude spawning is not allowed')
        if scene['id'] == 'night' and any(key in scene for key in ('nativeBell', 'bellManagerPatch', 'lengtuSpawn', 'storyActors')):
            raise ValueError('Retired native scene policy must not attach to the night arena')
        if scene['id'] == 'lake':
            if scene.get('nativeBell') is not True or scene['bell'].get('class') != 'BP_MelodiousBell_C' or scene['bell'].get('actorName') != 'BP_MelodiousBell_C_UAID_60CF8480978B070103_1488601147':
                raise ValueError('Lake requires its exact original native bell actor')
            if scene.get('bellManagerPatch') != dict.fromkeys(('SaveBellID', 'RecentlyInteractedBellID', 'BrokenBellID'), 'BrokenBell_LJC_02'):
                raise ValueError('Lake must preserve its original broken-bell classification')
            scope = scene.get('scope', {})
            _vector(scope, ('minX', 'maxX', 'minY', 'maxY', 'minZ', 'maxZ'))
            if any(scope['min' + axis] >= scope['max' + axis] for axis in ('X', 'Y', 'Z')):
                raise ValueError('Invalid lake identity scope')
            if any(not all(scope['min' + axis] <= point[axis] <= scope['max' + axis] for axis in ('X', 'Y'))
                   for point in scene['spawnPoints']):
                raise ValueError('Lake spawn choices must stay in the exact arena identity scope')
            if 'lengtuSpawn' in scene:
                raise ValueError('Retired ColdTu policy must not attach to lake')
            for actor in scene.get('storyActors', []):
                if not all(isinstance(actor.get(key), str) and actor[key] for key in ('class', 'name')) or set(actor) - {'class', 'name', 'domain', 'npc'}:
                    raise ValueError('Invalid exact lake story actor identity')
    return data


def _lua(value):
    if isinstance(value, str): return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool): return 'true' if value else 'false'
    if type(value) in (int, float) and math.isfinite(value): return repr(value)
    if isinstance(value, list): return '{' + ', '.join(_lua(v) for v in value) + '}'
    if isinstance(value, dict): return '{' + ', '.join('[' + _lua(k) + '] = ' + _lua(v) for k, v in value.items()) + '}'
    raise ValueError('Unsupported scene data')


def arena_scenes_lua():
    return ('-- Generated from ArenaScenes.json; do not edit.\nreturn ' + _lua(load_scenes()) + '\n').encode('utf8')


if __name__ == '__main__':
    output = Path(__file__).resolve().parents[2] / 'src/runtime/Scripts/GeneratedArenaScenes.lua'
    output.write_bytes(arena_scenes_lua())
    print('Validated the original night and lake arena scene data')
