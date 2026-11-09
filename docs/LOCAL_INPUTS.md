# Local-only inputs and release assembly

The repository contains the original MOD source and curated interoperability
metadata. It does **not** contain a game installation, game images, save-template
payloads, an extracted game package, UE4SS binaries, or anyone's personal saves,
Steam identifiers, challenge history or loadout preferences. The MIT license for
this project does not grant rights to third-party game content.

A clean clone can check the source and build the native save barrier. It cannot
produce a complete usable binary distribution without the separately supplied
local inputs below. Missing inputs cause a clear error; the tools do not download
them, invent placeholder data, or extract them from a running game.

## Requirements

- Windows x64, Python 3.10 or newer, MSVC with the Windows SDK, and the .NET
  Framework C# compiler. See [BUILD.md](BUILD.md) for component build commands.
- The supported local `platform/steam/PBZ.exe`, fingerprint
  `4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423`
  (`CL-302256_JKS-17280`). Assembly reads this file to authenticate the preset
  bundle. It never starts or copies the executable, exports its key material,
  attaches to a process, or changes a game file.
- The locally obtained PBZ-compatible UE4SS release
  `phantombladezero_ue4ss_v3.0.1-1195-g1ceefac8.zip`, SHA-256
  `0b6b7f9430502c1fbeadb09740e586063dce42fe4f7d7a3ee7be51c9bd6ca304`.
  Only the eight explicitly listed loader/license/helper files are selected.
  Other UE4SS archives and generic releases are rejected. Obtain it separately
  under its applicable license; the repository does not fetch or vendor it.
- A compatible, sanitized **eighteen-private-block** `PBZS` template bundle that
  you have the right to use. This is not a normal account's `PBZSaveGame.sav`.
  No preset-authoring/export tool or game-derived baseline is provided here.
  The bundle must have precisely the canonical private IDs and order accepted
  by `src/save_tool/container.hpp`: nine Night presets and nine Lake presets,
  including each scene's training, cycles 0–6 and Lao entries. No ordinary slot
  or `__Advanced__` account block is permitted. Assembly authenticates the
  directory and every sealed block with Windows CNG, without decompressing
  their contents. Therefore authors must sanitize the *contents* separately;
  successful authentication is not a semantic privacy or gameplay audit.
- Thirteen local UI images and their original **source** `Manifest.json`.
  The directory must contain exactly these files plus the manifest:

  ```text
  home-test.png          home-practice.png      home-challenge.jpg
  ink-background.png     challenge-zhan.png
  soul-0.png ... soul-6.png                     soul-lao.png
  ```

  The source manifest has `schemaVersion: 1`, owner
  `PBZTestArena.NativeUiAssets.v1`, `dataSha256` equal to the repository's
  `NativeUiAssetsData.lua` (the same contents with Git's LF/CRLF normalization
  are also accepted), and exactly thirteen file entries. Each entry needs
  `file`, `sha256`, `bytes`, `width` and `height`. Actual image hashes, lengths,
  dimensions and PNG CRCs are checked. Dimensions must also match the native
  UI metadata. The simplified deployed `UiAssets/Manifest.json` omits
  `dataSha256` and is **not** a substitute for this source manifest. Source
  provenance fields are never copied into the release manifest. Images may be
  game-derived or independently authored; you must have the necessary rights
  and preserve the declared visual/layout contract. No images are supplied or
  licensed by this repository.

Put these files under the ignored `local-inputs/` directory, for example:

```text
local-inputs/
  UE4SS-release.zip
  PrivatePresets.pbzs
  UIAssets/
    Manifest.json
    ...the thirteen actual PNG/JPG files...
```

Keep the game executable in its own installation; do not copy it into the
repository. Never commit local inputs, generated binaries, personal saves or
the assembled distribution. The `local-inputs/`, `build/` and `dist/`
directories are ignored for this reason.

## Build and assemble

Run from the repository root, in an x64 MSVC developer terminal:

```powershell
python tools/data/generate_runtime_data.py --output build/generated
python tools/build.py native --component all --tests --output build `
  --presets local-inputs/PrivatePresets.pbzs
python tools/build.py installer --output build
python tools/assemble_release.py --build-dir build --data-dir build/generated `
  --assets-dir local-inputs/UIAssets --presets local-inputs/PrivatePresets.pbzs `
  --ue4ss-zip local-inputs/UE4SS-release.zip `
  --game-exe "X:/YourLibrary/PBZ/platform/steam/PBZ.exe" `
  --output dist/yingjing-yanwu-local --version local
```

Use `tools/build.py --help` for explicit compiler/SDK paths. SaveTool embeds
the SHA-256 of the supplied local preset bundle at compilation. Assembly must
receive that **same bundle**; it never replaces the compiled fingerprint with
a different one. Rebuild SaveTool if the legitimate templates change. Optional
legacy eight-block ownership migration is enabled only when the component was
built with its separate `--legacy-presets` input; that old bundle is not shipped.

Assembly validates the component manifests and actual x64 PE files. It checks
the three generated Lua modules against the current `config/` inputs, selects
the explicit runtime allowlist, and creates the installer's required 78-file
`NativeEnemyRuntime/Payload` plus `PayloadHashes.json`. It writes a complete
`IntegratedMenu/Tools/Build.json` compatible with the installer while retaining
the compiled game's and presets' fingerprints. The retired `ChallengeUI.lua`
is not included. The pinned archive supplies the external `UEHelpers` module.

The output is a **new** directory below this repository's ignored `dist/`.
Existing output is never overwritten. Validation finishes before output is
written; an interrupted filesystem write may leave a `.assemble-*` staging
directory, but it does not replace an existing release. No install/uninstall,
PowerShell GUI, game process or save decompression is run by the assembler.

## Result and limits

```text
dist/yingjing-yanwu-local/
  影境演武安装器.exe
  IntegratedMenu/
    ...installer scripts...
    PrivatePresets.pbzs
    Tools/PBZSaveTool.exe
    Tools/Build.json
    Tools/JSON-LICENSE.MIT
  NativeEnemyRuntime/
    Payload/...78 verified files...
    PayloadHashes.json
  BuildProvenance.json
  PackageManifest.json
  SHA256SUMS.txt
  LICENSE
  README.md
  THIRD_PARTY_NOTICES.md
```

The release's `README.md` comes from `docs/RELEASE_README.md` and explains manual
installation. Source build documentation and source files are not bundled into
the installer distribution.

`BuildProvenance.json` records hashes and sanitized build metadata, not absolute
input paths, the game executable, key material, original source-manifest paths,
ordinary saves or personal reports. Integrity checks establish local input
consistency; they are not a third-party code signature or permission to
redistribute supplied content. Full distribution of locally supplied images,
templates and UE4SS remains subject to their own rights and licenses.

The installer and CNG tool use Unicode Windows paths, but the pinned game's Lua
runtime uses narrow file APIs. Chinese/non-ASCII **game-directory** compatibility
has not been established. The GUI calls out that limit; assembly success alone
does not prove live in-game behavior. Local release assembly and synthetic
tests do not replace a separately authorized compatible-game test.
