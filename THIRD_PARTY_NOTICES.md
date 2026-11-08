# Third-party notices

## Original project implementation

The repository's original Lua, C++, C#, PowerShell and Python implementation,
documentation, and original MOD configuration are provided under the root MIT
license. This does not relicense any third-party work or grant rights in a game,
its trademarks or its resources.

## nlohmann/json 3.11.3

`src/save_tool/vendor/json.hpp` is the unmodified single-header distribution of
[JSON for Modern C++](https://github.com/nlohmann/json/tree/v3.11.3), copyright
2013–2023 Niels Lohmann. The upstream MIT license is retained at
[`src/save_tool/vendor/LICENSE.MIT`](src/save_tool/vendor/LICENSE.MIT), along with
copyright and component notices in the header itself. Those upstream notices
remain applicable; the root project's copyright line does not replace them.

## Phantom Blade Zero / 影之刃零

Game names, short actor names, class paths, native function names, texture paths,
placement coordinates and binary fingerprints are curated interoperability
references to a compatible, locally owned installation. They are not a bulk
cooked-table export or a license to redistribute the referenced game content.

No game executable, extracted model, texture, animation, audio, video, media
payload, save container or save-derived preset is distributed in this source
repository. `NativeUiAssetsData.lua` contains layout and resource-reference
metadata only. The PNG/JPG files it references, including generated portrait
derivatives, must be supplied separately by a user entitled to use them.

The root MIT license covers the original selection, configuration and
implementation work only. It does not assert copyright in game symbols,
artwork or trademarks, or authorize use beyond the rights a user already has.

## Unreal Engine and UE4SS

The MOD integrates with the game's Unreal runtime through UE4SS interfaces.
Unreal Engine and UE4SS are external dependencies, not components relicensed by
this project. No UE4SS binary or Unreal Engine source is included here.

Full local assembly requires an independently obtained, compatible UE4SS
release. Consult that exact distribution's license and retain its notices when
redistributing any binary package. The assembler's version/hash checks verify
compatibility; they do not supply distribution rights.

## Build and CI dependencies

Python, Microsoft build tools, the Windows SDK, .NET Framework and GitHub Actions
are external tools under their own terms. Native binaries, installers and local
inputs are excluded from this source release.
