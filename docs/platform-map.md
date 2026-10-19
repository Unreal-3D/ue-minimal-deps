# Where UE 5.7.4 keeps each platform's payload

A map of the directory segments that carry platform identity in
`Engine/Build/Commit.gitdeps.xml`, measured on 5.7.4. File counts are the number
of manifest entries with that segment in their path; they are a size proxy, not a
byte total (the manifest has no size field).

Regenerate any of this on your own checkout. Run from the engine root, with an
absolute path to the tool (it lives in this repo, not in the engine):

```bash
cd /path/to/UnrealEngine
TOOLS=/path/to/ue-minimal-deps/tools
python3 "$TOOLS/gitdeps_segments.py" --platforms          # the survey
python3 "$TOOLS/gitdeps_segments.py" --tree <prefix>      # the layout under a tree
python3 "$TOOLS/gitdeps_segments.py" --grep 'arm64|ios'   # chase something unfamiliar
```

## The segments that matter

| Segment | Files | Top parent | Notes |
|---|---|---|---|
| `Mac` | 2,684 | `Engine/Binaries/ThirdParty/Python3` | macOS host payload. Distinct from `macos`/`osx`/`mac-arm64`. |
| `IOS` | 467 | `Engine/Build` | iOS build tools, third-party libs, editor icons. |
| `TVOS` | 98 | `Engine/Build` | Also `OodleNetwork/.../lib/TVOS`, `ICU/.../TVOS`. |
| `VisionOS` | 69 | `Engine/Platforms` | |
| `Android` | 518 | `Engine/Source/ThirdParty` | Plus `Engine/Build/Android`, `DotNet/Android`. |
| `Win64` | 4,159 | `Engine/Binaries/ThirdParty/Python3` | |
| `WinArm64` | 2,747 | `Engine/Binaries/ThirdParty/Python3` | Separate segment; `Win64` does not cover it. |
| `Win32` | 18 | `Engine/Source/ThirdParty/libOpus` | Vestigial, but safe to drop. |
| `Windows` | 345 | `Engine/Source/ThirdParty` | DirectX, Detours, NVIDIA. Not covered by `Win64`. |
| `Unix` | 691 | `Engine/Source/ThirdParty/abseil/.../lib` | **Linux payload only** — see the warning below. |
| `Linux` | 1,227 | `Engine/Binaries/ThirdParty/Python3` | |
| `LinuxArm64` | 206 | `Engine/Source/ThirdParty/vcpkg` | |
| `linux64` / `linux32` / `linuxarm` | 16 / 13 / 3 | OpenVR, Steamworks | |
| `x86_64-unknown-linux-gnu` | 564 | `Engine/Source/ThirdParty/abseil/.../lib/Unix` | Not matched by `Linux` or `Unix`. |
| `aarch64-unknown-linux-gnueabi` | 280 | `Engine/Source/ThirdParty/abseil/.../lib/Unix` | Same. |
| `VS2015` / `VS2017` / `VS2019` | 728 / 40 / 10 | USDCore, llvm, Flite | MSVC import libs. Also `VS2012`, `VS2013`, `VS2022`, `VS2015_ClangCL`. |
| `gnuwin32` | 36 | `nvTextureTools` | |
| `arm64-v8a` | 56 | `GooglePAD/.../play-core-native-sdk/libs` | The Android ABI you want. |
| `armeabi-v7a` / `x86` / `x86_64` | 40 / 121 / 51 | GooglePAD, DirectXLegacy | The Android ABIs you probably do not. |
| `Apple` | **5** | `Engine/Source/ThirdParty` | Tiny, but see the warning below. |
| `ArtToolsOSX` | 1,026 | `Engine/Extras/Maya_AnimationRiggingTools` | macOS Maya plugin. Kept on macOS. |
| `UbaAgentHelperMac` | 23 | `Engine/Source/Programs/UnrealBuildAccelerator` | macOS UBA helper. Kept on macOS. |

Counts are per file, matching what `gitdeps_segments.py --platforms` prints.

### Bare `x86` is safe on macOS and Linux, but not on Windows

The 121 `/x86/` occurrences split into Android payloads (the ones you want gone)
and a handful of genuinely Windows-only 32-bit libraries. On macOS and Linux all
of the latter are already excluded by other patterns, so `-exclude=x86` is a
clean win. On Windows they are not:

```
Engine/Source/ThirdParty/WiX/3.8/x86/burn.exe              WiX 3.8 installer toolchain
Engine/Source/ThirdParty/WiX/3.8/sdk/x86/sfxca.dll         (32-bit, that era)
Engine/Source/ThirdParty/WiX/3.8/sdk/lib/x86/dutil.lib
Engine/Source/ThirdParty/EOSSDK/SDK/Bin/x86/...
Engine/Source/ThirdParty/Windows/XAudio2_9/Lib/x86/...
Engine/Binaries/ThirdParty/HLMediaLibrary/Windows/Release/x86/...
Engine/Source/ThirdParty/NVIDIA/nvapi/x86/...
```

`scripts/Setup_Minimal.bat` therefore excludes `armeabi-v7a` and `x86_64` (both
provably Android-only) and leaves bare `x86` in place, accepting ~40 small
Android static libs to avoid risking installer packaging. The audit tool pins
`WiX/3.8/x86/burn.exe` in the Windows `must_keep` list, so if someone adds
`-exclude=x86` later the audit fails immediately and explains why.

## Three names that mislead

### `Unix` is a Linux payload, not a platform class

Every one of the 691 `Unix` entries resolves to `x86_64-unknown-linux-gnu` or
`aarch64-unknown-linux-gnueabi`:

```
Engine/Source/ThirdParty/abseil/20240722.0/lib/Unix/x86_64-unknown-linux-gnu/Release/libabsl_base.a
Engine/Source/Runtime/SymsLib/lib/Unix/aarch64-unknown-linux-gnueabi/libsyms.a
Engine/Binaries/ThirdParty/OpenSSL/Unix/lib/x86_64-unknown-linux-gnu/libssl.so.1.1
```

Mac payloads sit under `Mac/` instead, and the flat libraries like
`SymsLib/lib/Mac/libsyms.a` or `UEJpegComp/Lib/uejpeg_mac.a` do not use a
platform segment at all. So `-exclude=Unix` is correct on Windows and macOS, and
**wrong on Linux**, where it would delete the host's own OpenSSL and SymsLib.

### `Apple` is 5 files, 3 of which are load-bearing on Windows

Every `Apple` entry in the manifest, in full:

```
Engine/Binaries/ThirdParty/Apple/MetalShaderConverter/Mac/libmetalirconverter.dylib
Engine/Binaries/ThirdParty/Apple/MetalShaderConverter/Windows/metalirconverter.dll
Engine/Source/ThirdParty/Apple/MetalShaderConverter/include/Acknowledgements.rtf
Engine/Source/ThirdParty/Apple/MetalShaderConverter/lib/metalirconverter.lib
Engine/Source/ThirdParty/Apple/ProResLib/lib/windows/ProRes64_VS2017.lib
```

The obvious move on a Windows profile is to exclude everything Apple. Doing so
breaks the Win64 editor build, which links the Windows `metalirconverter.dll` and
`ProRes64_VS2017.lib`. Exclude `Mac` and `macos` instead, and leave `Apple` alone.

Note the third Windows consumer, `lib/metalirconverter.lib`: it has **no platform
segment at all**, so no platform-segment exclude can reach it. That is the same
pattern as `UEJpegComp/Lib/uejpeg_mac.a` and `UEWavComp/Lib/uewav_w64.lib` —
small libraries that sit flat in a `lib/` directory named by a filename suffix
rather than a directory. It survives in the macOS and Windows profiles; the Linux
profile drops it only because it excludes the whole `Apple` segment (harmless —
it is an MSVC `.lib`). If you need one gone on a profile that keeps `Apple`, you
need a root-anchored prefix pattern.

This is the single best argument for writing a `must_keep` list rather than
reasoning from segment names — the audit tool's Windows profile pins both
platform-segmented Windows consumers.

### `Mac` and `mac-arm64` are unrelated

`Mac` (2,684) is the macOS host payload under `Engine/Binaries/Mac`,
`Engine/Binaries/ThirdParty/Python3/Mac`, and so on. `mac-arm64` (9,297) is
almost entirely the Apple Silicon .NET SDK under
`Engine/Binaries/ThirdParty/DotNet/<version>/mac-arm64`. Same for `osx-x64` /
`osx-arm64` (16 / 14 entries) which are the .NET host packs inside those RIDs.

That separation is what lets an Intel Mac drop the Apple Silicon runtime and keep
everything it needs. But the two directions are **not symmetric** — see below.

### Architecture segments are reused outside the runtime-pack tree

This is the trap that catches every hand-written arch split, and it is the
single best argument for having an audit tool rather than trusting a list. The
`.NET runtime pack` segment name for a given architecture also appears in
`Engine/Binaries/DotNET/`, which is a *different* tree holding host tools:

| Pattern | Occurrences outside `ThirdParty/DotNet/` | Safe as a bare segment? |
|---|---|---|
| `mac-arm64` | 0 | Yes, anywhere |
| `mac-x64` | 2 — `EpicGames.Perforce.Native/mac-x64/{Debug,Release}/EpicGames.Perforce.Native.dylib` | Only on Intel |
| `linux-arm64` | 0 | Yes, anywhere |
| `linux-x64` | 8 — `EpicGames.Perforce.Native/linux-x64/*`, `Android/UnrealAndroidFileTool/linux-x64/*`, `OidcToken/linux-x64/*` | Only on x86_64 |

`EpicGames.Perforce.Native` has no arm64 build on either platform, and the
Android deploy tool and OidcToken helper exist only as `linux-x64`. So excluding
the bare segment on the ARM branch of each profile would silently take the
Perforce integration and the Android deploy tool with it.

Both scripts therefore root-anchor the cut to the DotNet tree on the ARM branch:

```
-exclude=/Engine/Binaries/ThirdParty/DotNet/8.0.300/mac-x64
-exclude=/Engine/Binaries/ThirdParty/DotNet/8.0.412/mac-x64
-exclude=/Engine/Binaries/ThirdParty/DotNet/8.0.300/linux-x64
-exclude=/Engine/Binaries/ThirdParty/DotNet/8.0.412/linux-x64
```

which is version-pinned, so the audit reports it as stale when the DotNet version
moves. A deliberate trade: the failure mode of a stale pin is an extra ~9 GB
download, while the failure mode of the bare pattern is a broken Perforce
integration or a missing Android deploy tool, with no warning at all.

The x64 branches get to use the bare form, which is version-agnostic.

### The Linux architecture split has four spellings

There is no single pattern for "Linux, other architecture". UE writes it as:

| Spelling | Examples | Host-dependent |
|---|---|---|
| `<dir>/Unix/<triple>` | abseil, Boost, SymsLib, ICU 64_1, OpenSSL, MaterialX, TBB, openexr | both triples, either host |
| `<dir>/Linux/<triple>` | ICU 53_1, OpenAL, NVML, WebRTC, GoogleTest, Catch2 | both triples, either host |
| `LinuxArm64` | vcpkg, OodleNetwork, TextureFormatOodle, Onnxruntime | arm64 only |
| `LinuxAArch64` | Perforce `p4api-2024.1` | arm64 only |
| `linux64` / `linux32` / `linuxarm` | Steamworks, OpenVR, Oodle core | x64 / 32-bit / ARM |

`linuxarm` is the awkward one: it holds `liboo2corelinuxarm32.so.9` and
`liboo2corelinuxarm64.so.9` side by side, so it cannot be split further without a
filename-level pattern, which `-exclude` cannot express. The profile keeps it
whole on the ARM branch.

Note also that `Engine/Binaries/Linux` is **not** arch-split — there is no
`Engine/Binaries/LinuxArm64` anywhere in the manifest — so the Linux host tools
are kept on both architectures. `Engine/Source/Programs/UnrealBuildTool/Configuration/UEBuildTarget.cs:3141`
does reference `Binaries/LinuxArm64/UnrealBuildAccelerator/UbaObjTool`, but that
directory is not distributed through `Commit.gitdeps.xml`.

## The .NET runtime packs are the biggest win

`Engine/Binaries/ThirdParty/DotNet/{8.0.300,8.0.412}/<rid>` accounts for roughly
**57,000 of the manifest's 146,315 files** across six RIDs:

| RID | Files | Executed by |
|---|---|---|
| `win-x64` | 10,187 | Windows x64 hosts |
| `win-arm64` | 10,181 | Windows-on-ARM hosts |
| `linux-x64` | 9,305 | Linux x64 hosts |
| `linux-arm64` | 9,297 | Linux ARM hosts |
| `mac-x64` | 9,299 | Intel Macs |
| `mac-arm64` | 9,297 | Apple Silicon Macs |

A host only ever runs its own. `Engine/Build/BatchFiles/Mac/SetupDotnet.sh` picks
`DotNet/8.0.412/mac-$ARCH` where `ARCH` comes from `uname -m`, and the Windows and
Linux equivalents do the same for their RIDs. Excluding the other five is safe,
and it is the single largest cut available.

One wrinkle: the Windows RIDs are the only ones that ship **all three** Windows
host packs. So `win-x64/packs/` also contains
`Microsoft.NETCore.App.Host.win-arm64/` (22 files), and `win-arm64/packs/`
contains a copy of the x64 pack. These are duplicates; dropping the RID you do
not need takes both copies with it. The audit tool declares both directions
explicitly rather than letting them show up as unexplained cuts.

## CEF

Two separate places, and they are easy to confuse:

- **Source/wrapper drops** live in `Engine/Source/ThirdParty/CEF3/cef_binary_<version>_<platform>/`.
- **Runtime payloads** live in `Engine/Binaries/ThirdParty/CEF3/<Platform>/`.

`CEF3.build.cs:48` resolves the source drop by platform, and for Mac it always
resolves `macos_universal` — `bUseExperimentalVersion` is hard-coded `true` for
every platform in 5.7.4, so the legacy `macosx64` (CEF 90.6.7) and
`linux64_ozone` (CEF 93.0.0) drops are unreachable. `macosarm64` is kept anyway,
because it is what the non-experimental branch would select and it is only ~160
small files.

The runtime side follows the platform name: `CEF3/Mac`, `CEF3/Win64`,
`CEF3/WinArm64`, `CEF3/Linux`. Those are ordinary platform segments and are
covered by the usual excludes.

## vcpkg triplets

`Engine/Plugins/Runtime/GeoReferencing/Source/ThirdParty/vcpkg-installed/<triplet>`
holds one real library set per target, so the triplet names are worth knowing:

| Triplet | ~Files | Belongs to |
|---|---|---|
| `overlay-x64_arm64-osx` | 22 | macOS (universal) |
| `overlay-arm64-ios` | 22 | iOS |
| `arm64-android` | 22 | Android arm64 |
| `overlay-x64-linux` | 22 | Linux |
| `overlay-x64-windows` | 23 | Windows |
| `x64-windows` | 12 | Windows |
| `overlay-x64-uwp`, `overlay-arm64-uwp` | 23 each | UWP — dead for desktop |
| `x64-android` | 22 | Android x86_64 emulator |

## What changed between 5.7.4 and 5.8.3

Measured by running the audit tool against both manifests. None of this is
guesswork — every item below was reported as either a stale pattern or an
undeclared cut before it was written down.

| Area | 5.7.4 | 5.8.3 |
|---|---|---|
| .NET runtime packs | `DotNet/{8.0.300,8.0.412}/<rid>`, ~9,300 files per RID | `DotNet/10.0/<rid>`, ~5,040 files per RID |
| `dotnet-format` shims | none | `sdk/<ver>/DotnetTools/dotnet-format/shims/net10.0/win-{x64,x86}/` inside **every** RID's SDK, including the Mac and Linux ones |
| `Engine/Binaries/DotNET/CsvTools/runtimes/` | one RID (`win`) | 25 RIDs (`osx-x64`, `osx-arm64`, `linux-x64`, `linux-arm64`, `win-x64`, `maccatalyst-*`, `browser-wasm`, …) |
| `EpicGames.Oodle` | `Sdk/2.9.10/linuxarm/lib/…` | `<ver>/runtimes/<rid>/native/…` |
| Oodle SDKs | 2.9.5 – 2.9.14 | 2.9.14, 2.9.15 |
| Boost | `Boost/Deploy/boost-1.85.0` | `boost-1.88.0` |
| CEF runtime dir (Windows) | `CEF3/Win64/128.4.13...` | `CEF3/Win64/128.4.13...+v2` and `CEF3/Win64/147.1.5...` |
| CEF drops | 128.4.13, 90.6.7, 93.0.0 | 128.4.13 (incl. a renamed `+v2_windows64`), 147.1.5. The 90.6.7 and 93.0.0 trees are gone. |
| CEF for Mac | `128.4.13_macos_universal` | unchanged — Mac did not get the 147.1.5 upgrade |
| `UbaAgentHelperMac` | 23 files | gone |
| `Apple/MetalShaderConverter` | Mac + Windows | Mac + Windows + **iOS** |
| MSVC toolchains | VS2008…VS2022 | VS2015/2017/2019 only |
| Manifest size | 146,315 files | 134,335 files |

Two consequences worth calling out:

**The .NET packs halved, so the exclusion *rate* drops.** macOS goes from cutting
40.7% of 5.7.4 to 28.5% of 5.8.3, not because the profile got worse but because
the largest single cut got smaller. Compare absolute file counts, not percentages,
when checking a profile against a new engine version.

**Mac CEF stayed on 128.4.13 while Linux and Windows moved to 147.1.5.** That is
why the CEF block in each script lists names from several generations: a single
profile has to cover both. `STALE PATTERNS` reports the ones that do not apply to
the version you are on, which is expected noise here rather than a problem.

## What is not a platform payload

Worth knowing so you do not chase them: `Content/Editor/Slate/Launcher/<Platform>`
and `Content/Editor/PIEPreviewDeviceSpecs/<Platform>` are just editor icons and
device profiles. They are small, they are matched by the same segment names as
the real payloads, and excluding them costs you platform icons in the device
picker. Nothing in these profiles special-cases them; the segment match takes
them along, which is the intended behaviour.
