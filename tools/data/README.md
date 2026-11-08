# Runtime interoperability manifests

From the repository root:

```powershell
python tools/data/generate_runtime_data.py
python tools/data/generate_runtime_data.py --check
python tools/data/test_generate_runtime_data.py
```

This standard-library-only step builds `BossCatalog.lua`,
`GeneratedEncounterCatalog.lua` and `GeneratedArenaScenes.lua` in
`src/runtime/Scripts`. It does not launch or inspect a game process, read a save,
decrypt a package, or extract media.

The four JSON files under `config/` are curated functional MOD configuration:

- `BossCatalog.json`: 74 ordered actor identifiers, short names, class references,
  capsule dimensions and short compatibility notes written for the MOD. It is
  not a full cooked data-table export.
- `EncounterCatalog.json`: the MOD's encounter groups, stage order, names and
  availability flags, pinned to the curated actor manifest.
- `ArenaScenes.json`: the MOD's two supported scene routes, precise bell and
  story-actor identities, and placement/safety configuration.
- `ArenaProgression.json`: the MOD's cycle-to-equipment/skill-cap settings.

`create_encounter_catalog.py` rebuilds the authored encounter definitions from
the curated actor manifest. Change that canonical definition when changing a
combination or availability flag, then regenerate the Lua manifests.

Game names, symbols and asset-reference strings identify content in the user's
own compatible installation. They do not supply or license that content under
this project's MIT license. See the repository's third-party notices.

Images, textures, animations, audio, package exports, keys and game-save presets
are not supplied here. The separate art metadata may refer to local image files
or native textures; absent files must remain absent or be supplied locally by a
user who has the right to use them. Never substitute unrelated portraits or
claim a missing local preset is available.
