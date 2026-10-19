# ue-minimal-deps

**Precise, verifiable platform pruning for Unreal Engine's `GitDependencies` sync.**

A full UE source checkout pulls ~150,000 dependency files covering every platform
Epic ships. If you only build for some of them, most of that is dead weight you
download, unpack, and then never touch. `GitDependencies` has a `-exclude=` flag
that very few people know about, and — more importantly — almost nobody knows how
it actually matches, which makes it easy to use and easy to get silently wrong.

This repo is three things: an explanation of the mechanism, three ready-to-use
per-platform profiles, and a **verifier** that tells you whether a profile is
safe before you trust it.

## The mechanism in one paragraph

`Setup.sh` / `Setup.bat` hand off to `GitDependencies`, which accepts any number
of `-exclude=<pattern>` arguments. A pattern is matched against each file's path
**as a whole directory segment, case-insensitively** — not as a substring. So
`-exclude=Mac` removes `Engine/Binaries/Mac/...` but leaves
`Engine/Binaries/ThirdParty/DotNet/8.0.412/mac-arm64/...` alone, because `Mac`
and `mac-arm64` are different segments. A pattern that starts with `/` is instead
a prefix match from the repo root. Excluded files are **never downloaded and
never deleted**, which is what makes this safe to experiment with on an existing
tree. Full detail, including the exact source lines, is in
[docs/mechanism.md](docs/mechanism.md).

## Why it needs a verifier

`GitDependencies` accepts a wrong exclude list in total silence. A pattern that
matches nothing does nothing. A pattern that matches *too much* quietly drops a
platform you needed, and you find out weeks later when a build fails on a missing
file. There is no warning, no count, no dry-run diff of what you lost.

So this repo does not ask you to trust a list. It ships `tools/gitdeps_audit.py`,
which replays the exact matcher over your engine version's manifest and reports
what a profile keeps, what it cuts on purpose (with the reason), and — the part
that matters — any file belonging to a supported platform that got cut **without
being declared**. That last category is a bug, and the tool exits non-zero on it,
so it can gate a pull request.

It also reports **stale patterns**: exclude arguments that match nothing in the
manifest. That is not harmful on its own, but it is the shape every silent-drift
bug takes — the exclusion that was supposed to drop a platform stops matching
because the directory was renamed or version-bumped, and nothing else says so.
Running the profiles against 5.8.3 is what surfaced the .NET version pin going
stale, and the whole 5.8.3 layout change (CsvTools growing from one runtime RID to
twenty-five, `EpicGames.Oodle` moving to a `runtimes/<rid>/native` layout, and
.NET 10's `dotnet-format` Windows shims appearing inside every SDK).

Abridged output from the 5.7.4 run (`...` marks elided lines):

```
$ python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile macos
profile        : macos - macOS host (x64 or arm64) + iOS arm64 + Android arm64
manifest       : /Users/you/UnrealEngine/Engine/Build/Commit.gitdeps.xml
engine root    : /Users/you/UnrealEngine
host arch      : x86_64   DotNet runtime pack versions: 8.0.300, 8.0.412
exclude args   : 52
files          : 146315  kept 86734  cut 59581 (40.7% excluded)

MUST-KEEP      : 37/37 present and kept

DECLARED CUTS  : supported-platform-looking files cut on purpose
    9297  the Mac .NET runtime pack this host never executes (see --host-arch).
      12  non-arm64 Android ABIs (32-bit ARM, x86 emulator)
       5  inert Unix/Windows assets inside the KEPT Mac .NET SDK ...

UNEXPECTED CUTS: supported-platform-looking files cut with no declared reason
  (none)

MISSES         : dropped-platform payload still being downloaded
  (none)

STALE PATTERNS : 4/52 exclude patterns match nothing in this manifest
  - cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138+v2_windows64
  - cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_linux64
  ...

SHADOWED       : 6 patterns only match paths an earlier pattern already excludes
  - aarch64-unknown-linux-gnueabi
  - win-x86
  ...

RESULT         : PASS (with stale patterns)
```

`STALE PATTERNS` here is the macOS profile on 5.7.4, so the CEF drops that only
exist in 5.8.3 (`147.1.5`, `+v2_windows64`) are the four doing no work. The
shadowed ones are a different thing: `aarch64-unknown-linux-gnueabi` is inside
`Unix`, which the same profile already excludes, so it can never be the first
match. The two are reported apart because only the first is drift; on 5.8.3 the
same profile reports 6 stale (`linuxarm` and `winuwp` really are gone, from the
Oodle relayout and the UWP cleanup) and 6 shadowed.

`--strict` additionally makes an absent must-keep path or a stale pattern fatal,
which is what you want in CI once you have settled on one engine version.

### Running the verifier

The scripts go *into* the engine root; the tools stay in this repo. Run them
with the engine root as the working directory and an absolute path to the tool:

```bash
cd /path/to/UnrealEngine

# audit the profile you are on (default host arch = this machine)
python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile macos

# audit the branch your machine would not take
python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile macos --host-arch arm64

# a different checkout
python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --manifest /other/UE/Engine/Build/Commit.gitdeps.xml --profile linux
```

With no `--manifest` the tool looks for `Engine/Build/Commit.gitdeps.xml` in the
current directory and then in every parent, so running it from anywhere inside
the engine works. Nothing is downloaded or modified; it only reads the manifest.

## Profiles

Every profile is verified against **two** engine versions, because the manifest
layout moves between releases and a profile that silently stops matching is the
main failure mode this repo exists to prevent. Counts are files, not bytes —
`Commit.gitdeps.xml` carries no size field. Measure your own tree with `du -sh`
before and after if you want the disk figure.

UE **5.7.4** — 146,315 manifest files:

| Profile | Host + targets | Exclude args | Files kept | Cut |
|---|---|---|---|---|
| `scripts/Setup_Minimal.sh` | macOS host + iOS arm64 + Android arm64 | 52 / 53 | 86,734 | 40.7% |
| `scripts/Setup_Minimal.bat` | Windows x64 host + Android arm64, plus non-platform cuts (see below) | 30 | 88,820 | 39.3% |
| `scripts/Setup_Minimal_linux.sh` | Linux host + Android arm64 | 57 | 84,052 / 83,936 | 42.6% |

UE **5.8.3** — 134,335 manifest files:

| Profile | Host + targets | Files kept | Cut |
|---|---|---|---|
| `scripts/Setup_Minimal.sh` | macOS host + iOS arm64 + Android arm64 | 96,115 | 28.5% |
| `scripts/Setup_Minimal.bat` | Windows x64 host + Android arm64, plus non-platform cuts (see above) | 98,864 | 26.4% |
| `scripts/Setup_Minimal_linux.sh` | Linux host + Android arm64 | 93,755 / 93,648 | 30.2% / 30.3% |

The exclusion rate drops in 5.8.3 because the .NET runtime packs halved — they are
the single biggest cut, and the SDK shrank from ~9,300 files per RID in 5.7.4 to
~5,040 in 5.8.3.

The scripts only work from an engine root: copy one next to `Setup.sh` /
`Setup.bat` and run it *there*. Each script checks for `Setup.sh` and
`Engine/Build/Commit.gitdeps.xml` before doing anything, so a wrong directory
fails immediately instead of half-syncing. `bash Setup_Minimal.sh` works too —
the file does not have to be executable.

```bash
cd /path/to/UnrealEngine
bash Setup_Minimal.sh dry          # preview, downloads nothing
bash Setup_Minimal.sh              # sync
bash Setup_Minimal.sh --force      # overwrite locally modified files
```

### The Windows profile is not purely a platform cut

`Setup_Minimal.bat` also carries three long-standing non-platform cuts that the
macOS and Linux scripts only offer commented out. They are active by default, so
read this before you use it:

| Cut | Effect | To restore |
|---|---|---|
| `/Engine/Plugins/MetaHuman` + `/Engine/Source/ThirdParty/Protobuf` | the MetaHuman plugin family (~2.9 GiB) | disable MetaHumanSDK in your projects first, then delete the two lines |
| `/Engine/Content/Localization` | English-only editor UI | delete the line |
| `/Engine/Source/ThirdParty/Perforce` + `/Engine/Extras/P4VUtils` | no Perforce / ChangelistReview source control | re-enable those plugins and delete the lines |

The audit tool checks *platform* safety; it does not second-guess these — they are
declared intent, not accidental cuts. If you want the same shape as the other two
profiles (platform pruning only), comment them out. The `.bat` header carries the
same list.

### Intel Mac support status (checked 2026-10-17)

This is worth writing down because it came up as a disagreement, and the answer
turns out to depend on which layer you look at.

**The claim:** Epic dropped Intel Mac support in UE 5.8.

**What the 5.8.3 source tree shows** — five signals, all unchanged from 5.7.4:

| Signal | 5.8.3 |
|---|---|
| `Engine/Config/BaseEngine.ini:3439` | `TargetArchitecture=MacTargetArchitectureUniversal` (byte-identical to 5.7.4) |
| `UEBuildMac.cs:105` | `base(new[] { UnrealArch.X64, UnrealArch.Arm64 })` |
| `UEBuildMac.cs:242-246` | still resolves `DefaultArchitecture=...intel` to `UnrealArch.X64`, throwing only if `SupportedArchitecture` excludes it |
| `Mac/SetupDotnet.sh:47` | still `ARCH=x64; [ $(uname -m) == arm64 ] && ARCH=arm64` -> `DotNet/10.0/mac-$ARCH` |
| manifest | still ships `DotNet/10.0/mac-x64` (5,040 files) and `EpicGames.Perforce.Native/mac-x64` |

One signal even points the other way: 5.8.3's new `Catch2/v3.11.0/lib/Mac/` ships
**both** `arm64/` and `x86_64/`, where 5.7.4's Catch2 had no split at all.

**The likely reconciliation:** an official support change - no longer shipping
prebuilt Intel Mac editor binaries, or an announced deprecation - would not
necessarily show up in the source tree or in `Commit.gitdeps.xml` at all. A source
build can keep working long after the binary distribution stops. So the claim can
be true about *support status* while the tree still carries the x64 code path.
Those are different questions, and this repo only has access to the second one.

**What it means for the profiles: nothing, either way.** On Apple Silicon
`HOST_ARCH` is `arm64`, so the profile already drops `mac-x64` and keeps
`mac-arm64` - exactly what "Intel is gone" implies. The x64 branch is only reached
on an Intel Mac, which is the one machine that needs the x64 runtime pack to run
UnrealBuildTool. Removing the branch would save nothing on an Apple Silicon
machine and would break the engine on an Intel one.

To remove it anyway, in `scripts/Setup_Minimal.sh`:

```sh
-if [ "$HOST_ARCH" = "arm64" ]; then
-	KEEP_RID="mac-arm64"
-	for DOTNET_VERSION in $DOTNET_VERSIONS; do
-		EXCLUDES+=("-exclude=/Engine/Binaries/ThirdParty/DotNet/$DOTNET_VERSION/mac-x64")
-	done
-else
-	KEEP_RID="mac-x64"
-	EXCLUDES+=(-exclude=mac-arm64)
-fi
+# Intel Mac hosts are not supported from UE 5.8, so drop mac-x64 everywhere.
+KEEP_RID="mac-arm64"
+for DOTNET_VERSION in $DOTNET_VERSIONS; do
+	EXCLUDES+=("-exclude=/Engine/Binaries/ThirdParty/DotNet/$DOTNET_VERSION/mac-x64")
+done
```

Only for an engine version where you are certain - the failure mode is a Mac that
cannot run UnrealBuildTool.

### Where the Mac payloads actually are

Worth knowing when reasoning about the above: UE's Mac third-party libraries are
mostly **universal binaries in flat directories**, not architecture-split ones, so
there is little to gain by declaring "Mac is arm64-only". The complete set of
architecture-split Mac directories in 5.7.4 is four, and all four are arm64-only
already:

```
Engine/Source/ThirdParty/abseil/20240722.0/lib/Mac/arm64/      90 files
Engine/Source/ThirdParty/Protobuf/30.0/bin/Mac/arm64/          12
Engine/Source/ThirdParty/Protobuf/30.0/lib/Mac/arm64/           6
Engine/Source/ThirdParty/cares/1.19.1/lib/Mac/arm64/            1
```

5.8.3 adds `Catch2/v3.11.0/lib/Mac/{arm64,x86_64}/` (2 files each). Everything
else Mac - ICU, CEF, OpenSSL, Python, svn - is universal or flat. So the only
arch-dependent Mac cut worth making is the `mac-x64` .NET runtime pack, which the
ARM branch already takes.

The macOS profile's bare `x86`/`x86_64` Android-ABI excludes also take the
`Catch2/.../Mac/x86_64/` slices along with the emulator payload. That is
test-only payload (the editor does not link Catch2), and the audit reports it as
a separate declared cut so it is visible instead of being mislabelled as
Android payload.

### Host architecture is chosen automatically, and the branches differ

Dropping the payload your host never executes is the biggest cut available, but
the two hosts sometimes need *differently spelled* patterns for the same idea —
and that asymmetry is the single most valuable thing the audit tool caught while
this was being written. In both cases below, the bare segment name is safe in one
direction and silently destructive in the other, because the segment is reused
outside the runtime-pack tree:

| | Safe bare form | Why the mirror is not safe |
|---|---|---|
| macOS | `-exclude=mac-arm64` — appears nowhere outside the DotNet tree | `-exclude=mac-x64` also removes `EpicGames.Perforce.Native/mac-x64`, the only Perforce native library that exists for Mac |
| Linux | `-exclude=linux-arm64` — appears nowhere outside the DotNet tree | `-exclude=linux-x64` also removes `EpicGames.Perforce.Native/linux-x64`, the Android deploy tool, and the OidcToken helper |

So on the ARM branch of each profile the cut is root-anchored to the DotNet tree
instead. That needs a version number, and the version moves (5.7.4 ships two
runtime packs, `8.0.300` and `8.0.412`; 5.8.3 ships one, `10.0`), so both scripts
enumerate it from the manifest rather than hard-coding it:

```sh
DOTNET_VERSIONS=$(sed -n 's|.*ThirdParty/DotNet/\([0-9][0-9.]*\)/.*|\1|p' \
	Engine/Build/Commit.gitdeps.xml | sort -u)
for DOTNET_VERSION in $DOTNET_VERSIONS; do
	EXCLUDES+=("-exclude=/Engine/Binaries/ThirdParty/DotNet/$DOTNET_VERSION/mac-x64")
done
```

The audit tool expands that same loop, so the two cannot disagree. A hard-coded
pin was the first version of this and it went stale the moment 5.8.3 arrived,
silently keeping ~9 GB of runtime pack the host never runs.

### Confidence levels

Being explicit about this, because it is the difference between a tool and a
guess. All three profiles are manifest-audited against **both** engine versions,
on every host architecture they support — ten combinations, all passing:

- **macOS** — audited on both manifests, *and* exercised end to end on a real
  5.7.4 tree: argument acceptance, the exclude counts and hook generation were
  checked against the actual `GitDependencies` binary.
- **Windows** — audit only. The cut list started as a working 5.8.3 setup; it is
  audited against both manifests, but has not been re-run on a 5.7.4 host.
- **Linux** — audit only, both host architectures, both manifests. **Not
  field-tested on a Linux host.** Run the audit before you rely on it.

## The two traps

Both are silent failures that cost real time, and both are in
[docs/mechanism.md](docs/mechanism.md) with the source references.

**1. A bare `-force` breaks the sync without telling you.** `Setup.sh` looks for
the double-dash `--force`/`--prompt` to decide whether to add `--prompt`. Pass
`-force` and it adds `--prompt` too; `GitDependencies` then consumes `--prompt`,
leaves `-force` unconsumed, treats it as an invalid parameter, prints its help
text, and **exits 0**. Nothing downloads and nothing looks wrong. All three
scripts normalize a bare `-force` to `--force` (the `.bat` only in the
single-token case, so use the double-dash spellings when combining arguments),
and they reject `--force` together with `--prompt`, which reaches the same
unconsumed-argument path.

**2. The git hooks can discard your exclude list — or keep a per-run flag.**
On macOS, `Setup.sh` registers `post-checkout`/`post-merge` as symlinks to
`GitDependenciesHook.sh`, which runs `GitDependencies` with **no arguments** — so
the next `git pull` re-downloads every platform and quietly undoes your work. On
Linux and Windows, `Setup.sh`/`Setup.bat` write the raw argument list into the
hooks, which preserves the excludes but also persists `--dry-run` or `--force`
from a one-off run: future pulls then download nothing, or overwrite locally
modified files. All three profiles rewrite both hooks after every run with the
exclude list only, including after `dry`.

## Tests

The profile hook and argument-handling regression tests need no engine checkout:

```bash
bash tests/test_setup_hooks.sh
```

## Making your own profile

Run these from the engine root; `TOOLS` is the absolute path to this repo's
`tools/` directory (both are stdlib-only Python 3, no dependencies):

```bash
cd /path/to/UnrealEngine
TOOLS=/path/to/ue-minimal-deps/tools

# 1. what platform-ish directory names exist, and where do they live?
python3 "$TOOLS/gitdeps_segments.py" --platforms

# 2. dig into anything unfamiliar
python3 "$TOOLS/gitdeps_segments.py" --grep 'arm64|ios|android'
python3 "$TOOLS/gitdeps_segments.py" --tree Engine/Binaries/ThirdParty/DotNet

# 3. write your script, then check it (the script is parsed, never executed)
python3 "$TOOLS/gitdeps_audit.py" --from-script ./Setup_Custom.sh --audit-as macos
```

The audit tool's per-profile metadata — the `must_keep` list, the declared cuts,
the dropped-platform markers — lives in `tools/gitdeps_audit.py`. To support a
new profile, add an entry to `PROFILES` there and a script to `scripts/`.

`must_keep` is the highest-value part and worth writing carefully: it is the list
of paths that are load-bearing in *non-obvious* ways. On Windows, for example,
`Engine/{Binaries,Source}/ThirdParty/Apple/` must survive even though the profile
drops everything Apple, because the Win64 editor build links
`MetalShaderConverter/Windows/metalirconverter.dll` and
`ProResLib/lib/windows/ProRes64_VS2017.lib`. That is exactly the kind of thing a
naive `-exclude=Apple` gets wrong.

## Known limits

- **Savings are reported in files, not bytes.** `Commit.gitdeps.xml` has no size
  attribute, so the tools cannot compute a byte total. The biggest single win in
  every profile is the .NET runtime packs — `DotNet/{8.0.300,8.0.412}/<rid>` is
  ~57k of the manifest's 146k files across six RIDs, and a host only ever
  executes its own (`SetupDotnet.sh` picks `mac-$ARCH` / `win-$ARCH`).
  `GitDependencies` does total them itself while syncing: the macOS profile on
  5.7.4 reports **19,994 MiB across 86,734 files**. That is the payload the
  profile downloads, not a disk figure — unpacked size and filesystem block
  overhead are higher.
- **Android is arm64-v8a only** in all three profiles. That drops 32-bit ARM and
  the x86/x86_64 emulator ABIs. Comment out the "Android ABIs" block in a script
  if you need emulator builds. The Windows profile deliberately leaves bare
  `x86` alone — that segment also holds WiX 3.8's 32-bit installer toolchain and
  the Win32 DirectX/XAudio2/HLMedia libraries, which are not worth risking for
  ~40 small static libs. On macOS and Linux those are already dead weight, so
  those profiles do use bare `x86`.
- **The macOS and Linux profiles are host-architecture aware.** Each keeps the
  architecture it is running on and drops the other. `uname -m` is normalized
  first, so `aarch64` on Linux and `arm64` on macOS both take the ARM branch.
  Set `--host-arch` on the audit tool to check the branch you are not on.
- **Linux host tools are not arch-split.** There is no
  `Engine/Binaries/LinuxArm64` in the manifest, so `Engine/Binaries/Linux` is
  kept on both architectures. Linux `aarch64` is primarily a *target* platform in
  UE; this profile trims the download set correctly for either host, but it has
  not been exercised on ARM hardware.
- **Excludes only affect downloads.** Engine *source* for every platform is in the
  git tree regardless. This is about the dependency payload, not `Engine/Platforms`.
  Measured on 5.7.4 with the macOS profile: **18,821 git-tracked files (417 MB)
  still match an exclude pattern and stay on disk**, and not one of them is a
  manifest entry. 152 MB of that is `Engine/Binaries/DotNET/GitDependencies`,
  which ships a runner for every host RID in git — `-exclude=linux-x64` does not
  touch it. Another 130 MB is the Windows/Linux Python stdlib
  (`Engine/Binaries/ThirdParty/Python3/Win64` alone is 2,869 tracked `.py` files
  under an excluded segment). The rest is headers and small sources. If you need
  that gone, it has to come out of git, not out of the exclude list.
- **A plain `Setup.sh` re-expands the tree.** Excluded files are not deleted, so
  running the stock script fills everything back in. Always sync through a profile.
- **Version drift is real and the profiles span two engine versions.** CEF drop
  names, the DotNet runtime-pack versions, the `EpicGames.Oodle` layout and the
  `CsvTools` runtime RIDs all changed between 5.7.4 and 5.8.3. A pattern that no
  longer matches anything is harmless, but a *renamed* directory is a silently
  missed cut. Run the audit after every engine update and read both the
  `STALE PATTERNS` and `MISSES` sections. `--strict` makes a stale pattern and an
  absent `MUST-KEEP` entry fatal (`MISSES` stays informational), and the audit
  reports those absent entries for the same drift reason.
- **A must-keep entry ending in `/` is a prefix check** — "at least one file
  survives under here". Used where a versioned third-party tree moves its internal
  layout between releases, which is the difference between a useful pin and one
  that just reports drift on every upgrade.

## Not affiliated with Epic Games

This is an unofficial community tool. "Unreal Engine" and "Unreal" are trademarks
of Epic Games, Inc. Nothing here redistributes engine content — the tools read
Epic's own `Commit.gitdeps.xml` from your checkout and emit command-line
arguments. Engine source and dependencies remain under Epic's own terms.

Licensed under the MIT License; see [LICENSE](LICENSE).

## Layout

```
scripts/   drop-in per-platform setup scripts (the source of truth for each profile)
tools/     gitdeps_audit.py    - verifies a profile against a manifest (CI-gateable)
           gitdeps_segments.py - explores the manifest's segment layout
tests/     test_setup_hooks.sh - hook/argument regression tests (no engine needed)
docs/      mechanism.md        - the -exclude semantics, with source references
           platform-map.md     - where UE 5.7.4 keeps each platform's payload
LICENSE    MIT
```

The `scripts/` entries are deployed into an engine root; `tools/`, `tests/` and
`docs/` are not. Python 3.8+ and nothing else.
