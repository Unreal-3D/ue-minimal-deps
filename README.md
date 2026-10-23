# ue-minimal-deps

**Precise, verifiable platform pruning for Unreal Engine's `GitDependencies` sync.**

A full UE source checkout pulls roughly 130,000-150,000 dependency files covering
every platform Epic ships. `GitDependencies` accepts repeated
`-exclude=<pattern>` arguments, but it matches whole directory segments,
case-insensitively, and reports nothing when a pattern is wrong. This repo ships
three drop-in profiles and a verifier that replays the exact matcher over your
engine's `Commit.gitdeps.xml`, so you can see what a profile keeps, what it cuts
on purpose, and what it would break.

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

## Verified file counts

Files kept, audited against both engine versions. These are file counts, not
bytes - `Commit.gitdeps.xml` has no size field:

| Engine | macOS x64 / arm64 | Windows x64 | Linux x64 / arm64 |
|---|---|---|---|
| 5.7.4 (146,315 files) | 86,734 | 84,775 | 84,052 / 83,936 |
| 5.8.3 (134,335 files) | 96,120 / 96,119 | 94,592 | 93,760 / 93,646 |

The 5.7.4 counts predate the `.gitdepsignore` split; the difference is the
handful of Perforce/AutomationTool files the profiles now keep. The 5.8.3 counts
are current.

All ten profile/architecture combinations pass with no `UNEXPECTED CUTS` and no
`MISSES`. The exclusion rate drops in 5.8.3 because the .NET runtime packs
halved; compare absolute file counts, not percentages.

## Windows profile

`Setup_Minimal.bat` is not purely a platform cut. It also carries three
long-standing non-platform cuts that the macOS and Linux profiles only offer
commented out:

| Cut | Effect | To restore |
|---|---|---|
| `/Engine/Plugins/MetaHuman` + `/Engine/Source/ThirdParty/Protobuf` | the MetaHuman plugin family (~2.9 GiB) | disable the **MetaHuman** and **Bridge** plugins in your projects first, then delete the two lines. Bridge is enabled by default and depends on MetaHumanSDK, so disabling only MetaHuman still links `MetaHumanSDKEditor` against the cut Protobuf libraries |
| `/Engine/Content/Localization` | English-only editor UI | delete the line |
| `/Engine/Source/ThirdParty/Perforce` + `/Engine/Extras/P4VUtils` | no Perforce / ChangelistReview source control | re-enable those plugins and delete the lines |

For a pure platform profile, comment those lines out. The script header carries
the same list.

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
`linux32`, `linuxarm`, `overlay-arm64-ios` and `winuwp`. `WinRT` stays because it
also contains Win64 FreeType libraries.

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
- **Version drift is real.** CEF drop names, the .NET pack versions, the Oodle
  layout and the CsvTools RIDs moved between 5.7.4 and 5.8.3. Run the audit after
  every engine update and read `STALE PATTERNS` and `MISSES`. `--strict` makes a
  stale pattern or an absent must-keep entry fatal.
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
