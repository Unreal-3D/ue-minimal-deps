# ue-minimal-deps

**Precise, verifiable platform pruning for Unreal Engine's `GitDependencies` sync.**

A full UE source checkout pulls roughly 130,000-150,000 dependency files covering
every platform Epic ships. `GitDependencies` accepts repeated
`-exclude=<pattern>` arguments, but it matches whole directory segments,
case-insensitively, and reports nothing when a pattern is wrong. This repo ships
three drop-in profiles and a verifier that replays the exact matcher over your
engine's `Commit.gitdeps.xml`, so you can see what a profile keeps, what it cuts
on purpose, and what it would break.

The profiles are audited against **5.7.4, 5.8.3, 5.9 and ue6-main (UE6)**. One file
serves all four: version-specific names that no longer exist are reported as
`STALE` by the verifier instead of failing, and the newest names are always added
next to the old ones (CEF drops, UWP vcpkg triplets, the `.NET` RIDs). Engine
behaviour changes that affect which cuts are safe are detected rather than
assumed - see [`bBuildAllModules`](#bbuildallmodules-59).

## Which platforms each profile keeps

| Script | Host (the machine you build on) | Additional targets kept |
|---|---|---|
| `scripts/Setup_Minimal.sh` | macOS, host arch (x64 or arm64) | **iOS arm64**, **Android arm64** |
| `scripts/Setup_Minimal_linux.sh` | Linux, host arch (x86_64 or aarch64) | **Android arm64** |
| `scripts/Setup_Minimal.bat` | Windows x64 | **Android arm64** |

A profile always keeps the host platform's own binaries, host tools and .NET
runtime pack. The other host architecture, the other desktop platforms, tvOS
and visionOS are excluded. Android is arm64-v8a, with the Windows caveat below.

**iOS ships only with the macOS profile.** macOS and Linux keep Android
arm64-v8a only. Windows keeps arm64-v8a plus a small Android x86 residue
(42-54 files), because bare `x86` also holds WiX 3.8's 32-bit installer
toolchain and the Win32 DirectX/XAudio2/HLMedia libraries; it cuts `x86_64` and
`armeabi-v7a`. The Windows profile also keeps both CEF version branches; see
[Known limits](#known-limits).

## Quick start

Copy the profile for your host into the engine root, next to `Setup.sh` /
`Setup.bat`, and run it there:

```bash
cd /path/to/UnrealEngine
bash Setup_Minimal.sh dry          # preview, downloads nothing
bash Setup_Minimal.sh              # sync
bash Setup_Minimal.sh --force      # overwrite locally modified files
bash Setup_Minimal.sh --prompt     # prompt before overwriting
```

On Linux use `Setup_Minimal_linux.sh`; on Windows use `Setup_Minimal.bat`. The
scripts only work from an engine root; each checks for `Setup.sh`/`Setup.bat` and
`Engine/Build/Commit.gitdeps.xml` before doing anything. `bash` works even if the
file is not executable.

The Windows profile is the one that is run day to day, on 5.8.3 and on ue6-main
(UE6). It accepts two extra flags:

```bat
Setup_Minimal.bat --keep-metahuman   keep the MetaHuman payload and Protobuf
Setup_Minimal.bat --no-cache         do not keep the .git/ue-gitdeps blob cache
```

Without it the profile cuts the MetaHuman family and disables the MetaHumanSDK
plugin (see [Windows profile](#windows-profile)).

Excluded files are never downloaded and never deleted. Each profile also writes a
managed `.gitdepsignore` in the engine root, which GitDependencies reads even when
you run a plain `Setup.sh` / `Setup.bat` - delete that file to restore a full
sync.

## What the verifier checks

`tools/gitdeps_audit.py` reads `Commit.gitdeps.xml` and replays the real matcher:

- **MUST-KEEP** - paths that are load-bearing in non-obvious ways, such as the
  Windows consumers under `Apple/`, the AutomationTool iOS resources that UAT
  compiles on every host, and all three `EpicGames.Perforce.Native` builds that
  `EpicGames.Perforce.csproj` copies unconditionally.
- **DECLARED CUTS** - supported-platform-looking files cut on purpose, with the
  reason.
- **UNEXPECTED CUTS** - the same, with no declared reason. This is a bug; the
  tool exits non-zero.
- **STALE PATTERNS** - excludes that match nothing, the shape version drift takes.
- **MISSES** - dropped-platform payload still being downloaded.

The verifier models both layers: the `-exclude` arguments and the managed
`.gitdepsignore`, whose `!` rules re-include a few files after a broader cut.
A path is reported with the layer that actually removed it.

Run it from anywhere inside the engine; it walks up to the manifest:

```bash
python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile macos
python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile macos --host-arch arm64
python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --manifest /other/UE/Engine/Build/Commit.gitdeps.xml --profile linux
```

`tools/gitdeps_segments.py` explores the manifest's segment layout when you need
to find where a platform's payload lives.

The verifier only needs the manifest, not a checkout, so one profile can be
checked against every engine version you care about:

```bash
for M in /path/UE5.7/Engine/Build/Commit.gitdeps.xml \
         /path/UE5/Engine/Build/Commit.gitdeps.xml \
         /path/UE6/Engine/Build/Commit.gitdeps.xml; do
  for P in windows macos linux; do
    python3 tools/gitdeps_audit.py --manifest "$M" --profile "$P" \
      | grep -E '^(profile|size|RESULT|UNEXPECTED|  X )'
  done
done
```

## Verified file counts and sizes

Files kept, audited against every engine version this repo has been pointed at.
The byte column comes from the manifest's `<Blobs>` table, which 5.7.4 does not
have and 5.8+ does; it is the unpacked size on disk, while GitDependencies' own
"Updating dependencies" counter reads lower because the CDN transfers
compressed blobs (ue6-main: 28.1 GiB unpacked, ~12 GB of transfer):

| Engine | macOS x64 / arm64 | Windows x64 | Linux x64 / arm64 |
|---|---|---|---|
| 5.7.4 (146,315 files, 80.4 GiB) | 86,736 / 86,735 (40.4 GiB) | 84,720 (28.5 GiB) | 84,056 / 83,935 (39.0 GiB) |
| 5.8.3 (134,335 files, 85.2 GiB) | 96,117 / 96,116 (44.1 GiB) | 94,525 (27.1 GiB) | 93,759 / 93,643 (40.2 GiB) |
| 5.9 (135,530 files, 86.9 GiB) | 97,259 / 97,258 (45.2 GiB) | 95,872 (31.6 GiB) | 94,892 / 94,777 (41.3 GiB) |
| ue6-main / UE6 (136,346 files, 88.9 GiB) | 97,601 / 97,600 (44.9 GiB) | 96,093 (28.1 GiB) | 95,500 / 95,402 (42.4 GiB) |

The 5.7.4 counts predate the `.gitdepsignore` split; the difference is the
handful of Perforce/AutomationTool files the profiles now keep. The byte figures
are the Windows/macOS-x64/Linux-x64 unpacked footprint from the `<Blobs>` table.
5.9 keeps more than 5.8.3 on Windows because `bBuildAllModules` forces the
Protobuf and Perforce libs to stay (see below).

All 20 profile/architecture/engine combinations audited on 2026-11-14 pass with
no `UNEXPECTED CUTS` and no `MISSES`; every failure in the table above would be a
cut of a must-keep path. The exclusion rate drops in 5.8.3 because the .NET
runtime packs halved; compare absolute file counts, not percentages.

## Windows profile

`Setup_Minimal.bat` is not purely a platform cut. It also carries three
long-standing non-platform cuts that the macOS and Linux profiles only offer
commented out:

| Cut | Effect | To restore |
|---|---|---|
| `/Engine/Plugins/MetaHuman` + `/Engine/Plugins/Experimental/MetaHuman` + `/Engine/Plugins/Experimental/Toolsets/MetaHuman*` + `/Engine/Source/ThirdParty/Protobuf` | the MetaHuman plugin family (7.58 GiB on UE6, of which MetaHumanCharacter content alone is 6.49 GiB) plus its Protobuf libs (3.93 GiB) | re-run with `--keep-metahuman` |
| `/Engine/Content/Localization` | English-only editor UI | delete the line |
| `/Engine/Source/ThirdParty/Perforce` + `/Engine/Extras/P4VUtils` | no Perforce / ChangelistReview source control | re-enable those plugins and delete the lines |

The MetaHuman cut and the plugin state are one decision. `MetaHumanSDKEditor`
links the Protobuf static libraries, so the payload is only safe to cut while the
plugin is off. 5.8.3 ships MetaHumanSDK with `EnabledByDefault:false`; ue6-main
flips it to `true`. The Windows profile therefore checks
`Engine/Plugins/MetaHuman/MetaHumanSDK/MetaHumanSDK.uplugin` before syncing,
keeps a `.bak` next to it, and flips `EnabledByDefault` to false when (and only
when) it is still true. If the flip cannot be written (locked or read-only file)
the profile aborts with exit code 3 before downloading anything, rather than
producing a tree that fails to link. A `dry` run never edits the plugin.

`--keep-metahuman` does the opposite: it skips both cuts, restores the `.bak` so
the kept payload is usable again, and is consumed by the profile itself - it is
never forwarded to `Setup.bat`/GitDependencies, which would reject the unknown
parameter, print help and exit 0. Bridge stays enabled, as on 5.8.3, and tolerates
the disabled dependency.

**Build status:** the 5.8.3 editor builds with this combination. The ue6-main
editor has not been compiled yet (the host is missing the MSVC 14.50 toolset that
ue6-main requires), so treat the UE6 MetaHuman/Protobuf cut as payload-verified
and audit-verified, not yet build-verified.

Note that this is a tracked-file edit: after a normal run `git status` shows
`MetaHumanSDK.uplugin` modified, and the `.bak` sits next to it. Both are local
state, not something to commit to the engine.

For a pure platform profile, comment those lines out. The script header carries
the same list.

### `bBuildAllModules` (5.9+)

5.9's `Engine/Source/UnrealEditor.Target.cs` sets `bBuildAllModules = true`: the
editor target compiles every engine module, so a plugin's `EnabledByDefault` no
longer removes anything from the build. Those modules still link their
third-party libs, which means `/Engine/Source/ThirdParty/Protobuf`
(`MetaHumanSDKEditor`) and `/Engine/Source/ThirdParty/Perforce`
(`PerforceSourceControl`, `ChangelistReview`) have to stay. Measured on a 5.9
editor build: with them cut, the build reaches the last two link actions and dies
with `LNK1181` on `libprotobuf.lib` / `libclient.lib`.

The Windows profile detects the flag in the target file and drops those two
excludes automatically (the audit applies the same rule, so its counts match the
sync). The same flag makes the TIER C block unsafe on 5.9+ - those
default-disabled plugins are compiled and linked anyway.

On 5.9 a Windows sync therefore keeps 95,872 files / 31.6 GiB. The rest of the
profile - platform cuts, MetaHuman content, localization, P4VUtils - is
unchanged.

Measured on a fresh ue6-main clone (2026-11-05, Windows host): 96,093 files,
12.1 GB transferred by GitDependencies, 28.1 GiB unpacked on disk. Add the
engine's own git checkout (~4 GiB) and, unless `--no-cache` is passed, the
compressed blob cache in `.git/ue-gitdeps` (~11.2 GiB) for the directory total.
The optional TIER C block below removes another ~6.4 GiB unpacked on UE6.

### `.gitdepsignore`: cuts that must keep a few files

Three coarse segments also match files that UBT/UAT execute or compile on the
host, so they cannot be plain `-exclude` arguments:

| Segment | What else it hits |
|---|---|
| `IOS` | `Engine/Source/Programs/AutomationTool/IOS/Resources/*.png` - UAT compiles `IOS.Automation` on every host |
| `mac-x64`, `linux-x64`, `win-x64` | `EpicGames.Perforce.Native/<rid>/Release/*` - `EpicGames.Perforce.csproj` copies all three unconditionally when UAT compiles its script modules |

The profiles therefore write `<engine>/.gitdepsignore` with a broad cut and a
`!` exception per required file, for example:

```
**/IOS/**
!**/AutomationTool/IOS/Resources/*.png
**/mac-x64/**
!**/EpicGames.Perforce.Native/mac-x64/Release/EpicGames.Perforce.Native.dylib
```

GitDependencies reads that file automatically, applies the rules in order with
the last match winning, and `-exclude` still wins over any `!` exception. If a
`.gitdepsignore` already exists and was not written by the profile, the script
refuses to overwrite it.

The profile also cuts platform payload outside Win64 + Android arm64:
`WinArm64`, `ArtToolsOSX`, `UbaAgentHelperMac`, `LinuxArm64`, `LinuxAArch64`,
`linux32`, `linuxarm`, `overlay-arm64-ios`, `overlay-arm64-uwp`,
`overlay-x64-uwp` and `winuwp`. `WinRT` stays because it also contains Win64
FreeType libraries. The last four cover both spellings of the UWP triplets:
`winuwp` is the 5.x segment, `overlay-*-uwp` is what ue6-main uses.

## Known limits

- **The two silent traps are handled.** A bare `-force` (or `--force` together
  with `--prompt`) makes GitDependencies print help and exit 0; the profiles
  detect that and fail. `Setup.*` also persists per-run flags into git hooks;
  every profile rewrites both hooks with the exclude list only. See
  [mechanism.md](docs/mechanism.md).
- **Host architecture is chosen automatically.** The macOS and Linux profiles
  keep the running arch and drop the other .NET runtime pack. Because the bare
  `mac-x64`/`linux-x64`/`win-x64` segments are also reused outside the runtime
  tree, those cuts and their Perforce exceptions live in `.gitdepsignore`. See
  [platform-map.md](docs/platform-map.md#architecture-segments-are-reused-outside-the-runtime-pack-tree).
- **Android is arm64-v8a on macOS and Linux; Windows keeps a small x86
  residue.** All three cut `x86_64` and `armeabi-v7a`. Windows cannot cut bare
  `x86` because that segment also holds WiX 3.8's 32-bit installer toolchain and
  the Win32 DirectX/XAudio2/HLMedia libraries, so 42-54 Android x86 files remain.
  Comment out the Android ABI block if you need emulator or 32-bit ARM packaging.
- **The Windows profile keeps both CEF version branches.** On 5.7.4 that leaves
  the legacy 90.6.7/93.0.0 drops (~475 files) on disk. This is a version-branch
  choice, not a platform gap; the other profiles cut some of these drops where
  their CEF policy allows.
- **The macOS profile's bare `x86_64` ABI cut also takes the test-only Catch2
  `Mac/x86_64` slices in 5.8.3.** The editor does not link Catch2; the audit
  reports that cut separately. See
  [platform-map.md](docs/platform-map.md#where-the-mac-payloads-actually-are).
- **Excludes only affect downloads.** Engine source for every platform is in the
  git tree regardless. On 5.7.4 the macOS profile leaves ~18,800 git-tracked
  files (~417 MB) matching an exclude pattern on disk; none are manifest entries.
- **GitDependencies keeps its own blob cache.** Downloaded content is stored
  compressed in `<engine>/.git/ue-gitdeps` (11.2 GiB after a full ue6-main sync)
  in addition to the unpacked files. It is what makes the next engine bump cheap,
  so the profiles leave it on; delete the directory to reclaim the space, or pass
  `--no-cache` on Windows to never build it.
- **Version drift is real.** CEF drop names, the .NET pack versions, the Oodle
  layout and the CsvTools RIDs moved between 5.7.4, 5.8.3, 5.9 and ue6-main. Run
  the audit after every engine update and read `STALE PATTERNS` and `MISSES`.
  `--strict` makes a stale pattern or an absent must-keep entry fatal.
- **Windows git hooks need `MSYS_NO_PATHCONV`.** Git for Windows runs hooks
  through its MSYS `/bin/sh`, which rewrites a rooted exclude such as
  `/Engine/Plugins/MetaHuman` into `C:/Program Files/Git/Engine/Plugins/MetaHuman`.
  The pattern then excludes nothing and the payload comes back on the next
  `git checkout` / `git pull` - observed on a real 5.9 switch (7.9 GiB of
  MetaHuman content returned). The profile's hook sets `MSYS_NO_PATHCONV=1` and
  `MSYS2_ARG_CONV_EXCL='*'` before invoking GitDependencies. The direct
  `Setup_Minimal.bat` run is unaffected: cmd does no path rewriting.
- **ue6-main (UE6) specifically.** The 147 CEF drop was renamed from
  `147.1.5+g68529a5+chromium-147.0.7727.49` to
  `147.0.14+g76d2442+chromium-147.0.7727.138` (the profile lists both, and the
  unused pair shows up as STALE); `UbaAgentHelperMac`, `linuxarm` and `winuwp`
  no longer exist while the UWP vcpkg triplets became `overlay-arm64-uwp` /
  `overlay-x64-uwp`; MetaHumanSDK is now enabled by default and moved into the
  engine's dependency payload (7.58 GiB); and the whole manifest grew to 88.9 GiB.
  The Windows profile was audited against ue6-main on 2026-11-05: 96,093 files,
  28.1 GiB unpacked, no unexpected cuts, no missed platform payload.
- **Confidence:** macOS is field-tested end to end on a real 5.7.4 tree; Windows
  and Linux are manifest-audited on both versions only. The Linux profile has not
  been run on Linux hardware.
- **A plain `Setup.sh`/`Setup.bat` keeps the managed cuts.** The profile's
  `.gitdepsignore` stays in the engine root and is read by GitDependencies
  directly, so a plain Setup keeps the platform payload out. Delete that file
  (and run Setup without the profile) to re-expand the tree.

## Tests

The hook and argument-handling regression tests need no engine checkout:

```bash
bash tests/test_setup_hooks.sh
```

They cover the macOS/Linux hook rewrite, the Windows hook format, `dry`,
`--force`, `--prompt`, the `--force` + `--prompt` rejection, and the
GitDependencies invalid-argument path. The audit has its own matcher selftest:

```bash
python3 tools/gitdeps_audit.py --selftest
```

## Making your own profile

Run these from the engine root; `TOOLS` is the absolute path to this repo's
`tools/`:

```bash
cd /path/to/UnrealEngine
TOOLS=/path/to/ue-minimal-deps/tools

python3 "$TOOLS/gitdeps_segments.py" --platforms
python3 "$TOOLS/gitdeps_segments.py" --grep 'arm64|ios|android'
python3 "$TOOLS/gitdeps_audit.py" --from-script ./Setup_Custom.sh --audit-as macos
```

The per-profile metadata (`must_keep`, declared cuts, dropped markers) lives in
`tools/gitdeps_audit.py`. `must_keep` is the highest-value part: it pins paths
that are load-bearing in non-obvious ways, such as the Windows consumers under
`Apple/`. See [mechanism.md](docs/mechanism.md) for the matcher and the two silent
traps, and [platform-map.md](docs/platform-map.md) for where each platform's
payload lives.

## Docs and layout

| Path | Contents |
|---|---|
| [docs/mechanism.md](docs/mechanism.md) | how `-exclude` matches, both silent traps, exit codes, hook behaviour |
| [docs/platform-map.md](docs/platform-map.md) | where each platform's payload lives, the 5.7.4/5.8.3 layout changes, Intel Mac status |
| `scripts/` | the profiles (the source of truth) |
| `tools/` | the verifier and the segment explorer |
| `tests/` | hook/argument regression tests |

The `scripts/` entries are deployed into an engine root; `tools/`, `tests/` and
`docs/` are not. Python 3.8+ and nothing else.

## Not affiliated with Epic Games

This is an unofficial community tool. "Unreal Engine" and "Unreal" are trademarks
of Epic Games, Inc. Nothing here redistributes engine content - the tools read
Epic's own `Commit.gitdeps.xml` from your checkout and emit command-line
arguments. Engine source and dependencies remain under Epic's own terms.

Licensed under the MIT License; see [LICENSE](LICENSE).
