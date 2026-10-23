#!/usr/bin/env python3
"""Audit a GitDependencies -exclude profile against a real engine manifest.

GitDependencies accepts a wrong exclude list silently. A pattern that matches
nothing does nothing; a pattern that matches too much quietly removes a platform
you needed from the download set, and you only find out when a build fails with
a missing file. This tool is the safety net. It replays the exact matcher
GitDependencies uses over every entry in Engine/Build/Commit.gitdeps.xml and
reports three things:

  MUST-KEEP       explicit paths that have to survive, because they are
                  load-bearing in non-obvious ways. Cutting one FAILS the run.
  DECLARED CUTS   files belonging to a supported platform that the profile cuts
                  on purpose, each with the reason it is safe. Nothing here is
                  a surprise; the profile author wrote it down.
  UNEXPECTED CUTS files belonging to a supported platform that were cut and
                  were NOT declared. This is the dangerous direction and FAILS
                  the run. It is how you catch "-exclude=Unix" reaching inside
                  the Mac .NET SDK, or a typo like "-exclude=Mac" when you meant
                  "-exclude=mac-arm64".

It also reports MISSES - payload for platforms the profile claims to drop that
is still being downloaded. Harmless, but that is where the savings leak out.

STALE and SHADOWED are reported separately: a stale pattern matches nothing at
all, which is the shape a renamed directory takes; a shadowed one only matches
paths an earlier pattern already cuts, so it is redundant rather than broken.

Matcher semantics (Engine/Source/Programs/GitDependencies/Program.cs:972):

    RootedName = "/" + FileName
    for each pattern P (backslashes -> "/", trailing "/" trimmed):
        if P starts with "/":  match when RootedName starts with P + "/"
        else:                  match when "/" + P + "/" occurs in RootedName
    all comparisons are case-insensitive

A bare name is therefore a whole-path-SEGMENT match, not a substring match.
"-exclude=Mac" does not touch "mac-arm64", and "-exclude=Unix" does not mean
"Unix-like platforms" - it means the literal segment "Unix", which in UE holds
only x86_64-unknown-linux-gnu and aarch64-unknown-linux-gnueabi payloads.

The profiles also write a managed <engine>/.gitdepsignore. GitDependencies reads
it automatically, and its "!" rules are applied in file order with the last match
winning. That is the only way to express "cut this whole platform segment, but
keep a few files inside it": a path removed by -exclude is already gone before
the ignore file is consulted. The audit models both layers and reports which one
cut a path. MUST-KEEP paths are load-bearing for UBT/UAT on the host: the
AutomationTool iOS resources and all three EpicGames.Perforce.Native builds that
EpicGames.Perforce.csproj copies when UAT compiles its script modules.

Usage (the tools live in this repo, but they read an engine tree):
    cd /path/to/UnrealEngine
    /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile macos
    /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile macos --host-arch arm64
    /path/to/ue-minimal-deps/tools/gitdeps_audit.py --manifest /path/to/Engine/Build/Commit.gitdeps.xml --profile linux
    /path/to/ue-minimal-deps/tools/gitdeps_audit.py --from-script /path/to/my/Setup_Custom.sh
    /path/to/ue-minimal-deps/tools/gitdeps_audit.py --selftest

Exit status is 0 only when no must-keep path was cut and no unexpected cut was
found, so this can gate a pull request.
"""

from __future__ import annotations

import argparse
import collections
import html
import pathlib
import platform
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent


def current_arch() -> str:
    """The host architecture, spelled the way the profiles branch on it."""
    machine = platform.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "arm64"
    return "x86_64"


# ---------------------------------------------------------------------------
# matcher - faithful port of GitDependencies' IsExcludedFolder
# ---------------------------------------------------------------------------


class Matcher:
    def __init__(self, patterns):
        self.patterns = [p.replace("\\", "/").rstrip("/") for p in patterns if p.strip()]

    def _hit(self, rooted: str, p: str) -> bool:
        if p.startswith("/"):
            return rooted.startswith((p + "/").lower())
        return ("/" + p + "/").lower() in rooted

    def __call__(self, name: str) -> bool:
        return self.which(name) is not None

    def which(self, name: str):
        """Return the pattern that matches, or None - so a cut can be explained."""
        rooted = ("/" + name).lower()
        for p in self.patterns:
            if self._hit(rooted, p):
                return p
        return None

    def direct(self, pattern: str, name: str) -> bool:
        """Would this pattern match the path on its own, ignoring pattern order?

        `which` stops at the first match, so a pattern that only ever sees paths
        an earlier pattern already excludes looks unused. That is shadowing, not
        staleness, and the two need different fixes.
        """
        return self._hit(("/" + name).lower(), pattern)


def _ignore_regex(rule: str):
    """Port of GitDependencies' IgnoreFile line parser.

    `?` matches one character, `*` one path component, `**` any number of
    components. A leading `!` is stripped by the caller and flips the rule into
    an include. Rules are matched in file order and the LAST match wins, which is
    what lets a profile cut a whole segment and re-include a few files.
    """
    line = rule.strip().replace("\\", "/")
    pattern = "^" + re.escape(line)
    pattern = pattern.replace(r"\?", ".")
    pattern = pattern.replace(r"\*\*", ".*")
    pattern = pattern.replace(r"\*", "[^/]*")
    if not pattern.startswith("^/"):
        pattern = pattern[1:]
    if pattern.endswith("/$"):
        pattern = pattern[:-1]
    return re.compile(pattern, re.IGNORECASE)


class IgnoreRules:
    """The `!`-aware rules GitDependencies reads from <engine>/.gitdepsignore."""

    def __init__(self, rules):
        self.rules = []
        for raw in rules:
            raw = raw.strip()
            if not raw:
                continue
            included = raw.startswith("!")
            body = raw[1:].lstrip() if included else raw
            self.rules.append((raw, _ignore_regex(body), not included))

    def which(self, name: str):
        """Return the exclude rule that wins for this path, or None."""
        path = "/" + name.replace("\\", "/")
        winner = None
        for raw, rx, excludes in self.rules:
            if rx.search(path):
                winner = (raw, excludes)
        if winner is not None and winner[1]:
            return winner[0]
        return None

    def direct(self, name: str) -> bool:
        return bool(self.rules) and any(rx.search("/" + name.replace("\\", "/"))
                                        for _, rx, excludes in self.rules if excludes)



SELFTEST_CASES = [
    # (pattern, path, expected) - pinned to the C# implementation
    ("Mac", "Engine/Binaries/Mac/UnrealEditor", True),
    ("Mac", "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/mac-arm64/dotnet", False),
    ("Mac", "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/mac-x64/dotnet", False),
    ("Mac", "Engine/Binaries/ThirdParty/Apple/MetalShaderConverter/Mac/libmetalirconverter.dylib", True),
    ("mac-arm64", "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/mac-arm64/dotnet", True),
    ("macos", "Engine/Binaries/ThirdParty/CEF3/Mac/Chromium", False),
    ("Unix", "Engine/Source/Runtime/SymsLib/lib/Unix/x86_64-unknown-linux-gnu/libsyms.a", True),
    ("Unix", "Engine/Source/Runtime/SymsLib/lib/Mac/libsyms.a", False),
    ("IOS", "Engine/Build/IOS/AppleRootCA.pem", True),
    ("IOS", "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/mac-x64/dotnet", False),
    ("linux-x64", "Engine/Binaries/ThirdParty/DotNet/8.0.300/linux-x64/dotnet", True),
    ("linux-x64", "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/mac-x64/dotnet", False),
    ("x86", "Engine/Source/ThirdParty/ICU/icu4c-53_1/Android/x86/libicuuc.a", True),
    ("x86", "Engine/Source/ThirdParty/ICU/icu4c-53_1/Android/x86_64/libicuuc.a", False),
    ("x86_64", "Engine/Source/ThirdParty/ICU/icu4c-53_1/Android/x86_64/libicuuc.a", True),
    ("x86_64", "Engine/Source/ThirdParty/ICU/icu4c-53_1/Linux/x86_64-unknown-linux-gnu/libicuuc.a", False),
    ("/Engine/Content/Localization", "Engine/Content/Localization/Engine/zh-Hans/x.locres", True),
    ("/Engine/Content/Localization", "Engine/Content/LocalizationExtra/x", False),
    ("/Engine/Source/ThirdParty/Protobuf", "Engine/Source/ThirdParty/Protobuf/30.0/lib/Mac/libprotobuf.a", True),
    ("VS2015", "Engine/Source/ThirdParty/Boost/Deploy/boost-1.85.0/VS2015/lib/x64/libboost.a", True),
    ("vs2015", "Engine/Source/ThirdParty/Boost/Deploy/boost-1.85.0/VS2015/lib/x64/libboost.a", True),
    ("windows64", "Engine/Binaries/ThirdParty/CEF3/Win64/libcef.dll", False),
    ("windows64", "Engine/Binaries/ThirdParty/CEF3/Win64/128.4.13+ge76af7e/x.dll", False),
    ("cef_binary_90.6.7+g19ba721+chromium-90.0.4430.212_windows64",
     "Engine/Source/ThirdParty/CEF3/cef_binary_90.6.7+g19ba721+chromium-90.0.4430.212_windows64/Release/libcef.lib", True),
    ("/Engine/Plugins/MetaHuman", "Engine/Plugins/MetaHuman/MetaHumanSDK/MetaHumanSDK.uplugin", True),
    ("/Engine/Plugins/MetaHuman", "Engine/Plugins/MetaHumanExtra/x", False),
    ("Win64", "Engine/Binaries/ThirdParty/CEF3/Win64/libcef.dll", True),
    ("WinArm64", "Engine/Binaries/ThirdParty/CEF3/WinArm64/libcef.dll", True),
    ("WinArm64", "Engine/Binaries/ThirdParty/CEF3/Win64/libcef.dll", False),
]


def run_selftest() -> int:
    failures = 0
    for pattern, path, expected in SELFTEST_CASES:
        got = Matcher([pattern])(path)
        if got != expected:
            failures += 1
            print(f"  FAIL  -exclude={pattern!r}\n        path     {path}\n        expected {expected}, got {got}")
    print(f"selftest: {len(SELFTEST_CASES) - failures}/{len(SELFTEST_CASES)} matcher cases pass")
    return 1 if failures else 0


# ---------------------------------------------------------------------------
# profile loading - the setup scripts are the single source of truth
# ---------------------------------------------------------------------------

DEFAULT_SCRIPTS = {
    "macos": "Setup_Minimal.sh",
    "windows": "Setup_Minimal.bat",
    "linux": "Setup_Minimal_linux.sh",
}


def parse_sh_excludes(text: str, host_arch: str, dotnet_versions: list[str] | None = None) -> list[str]:
    """Pull active -exclude= arguments out of a bash profile script.

    A profile may branch on the host architecture with

        if [ "$HOST_ARCH" = "arm64" ]; then
            EXCLUDES+=( -exclude=... )
        else
            EXCLUDES+=( -exclude=... )
        fi

    because which runtime pack is dead weight depends on the host. Only the
    branch matching host_arch is collected; anything outside such a block is
    always collected.

    The ARM branches loop over `$DOTNET_VERSION`, so a pattern containing it
    expands to one pattern per runtime-pack version the manifest ships - the same
    expansion the script performs, which is why the two cannot disagree.
    """
    out = []
    branch = None  # None = unconditional; otherwise the arch this branch is for
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        m = re.match(r'^if \[ "\$HOST_ARCH" = "(arm64|x86_64)" \];? then$', stripped)
        if m:
            branch = m.group(1)
            continue
        if branch is not None and stripped == "else":
            branch = "arm64" if branch == "x86_64" else "x86_64"
            continue
        if branch is not None and stripped == "fi":
            branch = None
            continue
        if branch is not None and branch != host_arch:
            continue

        # collect every -exclude= token on the line, so both the one-per-line
        # array form and an inline "EXCLUDES+=(-exclude=X)" are understood
        for value in re.findall(r"-exclude=([^\s)]+)", stripped):
            value = value.strip('"')
            if "$DOTNET_VERSION" in value:
                for v in (dotnet_versions or []):
                    out.append(value.replace("$DOTNET_VERSION", v))
            else:
                out.append(value)
    return out


def parse_bat_excludes(text: str) -> list[str]:
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.lower().startswith(("rem", "::")):
            continue
        m = re.search(r'set "EXCLUDES=%EXCLUDES%(.*)"', stripped)
        if m:
            out.extend(re.findall(r"-exclude=(\S+)", m.group(1)))
    return out


def load_profile_excludes(name: str, scripts_dir: pathlib.Path, host_arch: str,
                          dotnet_versions: list[str] | None = None) -> list[str]:
    script = scripts_dir / DEFAULT_SCRIPTS[name]
    if not script.exists():
        sys.exit(f"error: profile script not found: {script}")
    text = script.read_text()
    if script.suffix == ".bat":
        return parse_bat_excludes(text)
    return parse_sh_excludes(text, host_arch, dotnet_versions)


def parse_bat_ignore_rules(text: str) -> list[str]:
    """Rules from `set "IGNORE_RULES=a;b;c"` in the Windows profile."""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.lower().startswith(("rem", "::")):
            continue
        m = re.search(r'set "IGNORE_RULES=(.*)"', stripped)
        if m:
            return [r for r in m.group(1).split(";") if r]
    return []


def parse_sh_ignore_rules(text: str, host_arch: str) -> list[str]:
    """Rules from `IGNORE_RULES+=( 'a' 'b' )` blocks, honouring the arch branch."""
    out = []
    branch = None
    inside = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = re.match(r'^if \[ "\$HOST_ARCH" = "(arm64|x86_64)" \];? then$', stripped)
        if m:
            branch = m.group(1)
            continue
        if branch is not None and stripped == "else":
            branch = "arm64" if branch == "x86_64" else "x86_64"
            continue
        if branch is not None and stripped == "fi":
            branch = None
            inside = False
            continue
        if branch is not None and branch != host_arch:
            continue
        if "IGNORE_RULES=(" in stripped or "IGNORE_RULES+=(" in stripped:
            inside = True
            stripped = re.split(r"IGNORE_RULES(?:\+)?=\(", stripped, maxsplit=1)[1]
        if inside:
            if ")" in stripped:
                stripped = stripped.split(")", 1)[0]
                inside = False
            out.extend(re.findall(r"'([^']+)'", stripped))
    return out


def load_profile_ignore_rules(name: str, scripts_dir: pathlib.Path, host_arch: str) -> list[str]:
    script = scripts_dir / DEFAULT_SCRIPTS[name]
    if not script.exists():
        sys.exit(f"error: profile script not found: {script}")
    text = script.read_text()
    if script.suffix == ".bat":
        return parse_bat_ignore_rules(text)
    return parse_sh_ignore_rules(text, host_arch)


# ---------------------------------------------------------------------------
# per-profile audit metadata
# ---------------------------------------------------------------------------
# supported_markers: paths that look like they belong to a platform this profile
#                    claims to support. A cut matching one of these must be
#                    covered by a declared_cuts entry, or the run fails.
# declared_cuts:     (regex, reason) - deliberate cuts of supported-platform
#                    looking files.
# must_keep:         literal manifest paths that have to survive.
# dropped_markers:   paths that look like a platform this profile drops; if any
#                    survive, report them as missed savings.

PROFILES = {
    # -----------------------------------------------------------------------
    "macos": {
        "label": "macOS host (x64 or arm64) + iOS arm64 + Android arm64",
        "supported_markers": [
            r"^Engine/Binaries/Mac/",
            r"^Engine/Binaries/ThirdParty/CEF3/Mac/",
            r"^Engine/Binaries/ThirdParty/Apple/MetalShaderConverter/Mac/",
            r"^Engine/Source/ThirdParty/CEF3/cef_binary_\S*_macos_universal/",
            r"^Engine/Build/IOS/",
            r"^Engine/Source/ThirdParty/IOS/",
            r"ICU/icu4c-53_1/IOS/",
            r"^Engine/Build/Android/",
            r"^Engine/Source/ThirdParty/Android/",
            r"arm64-v8a/",
            r"/(mac-x64|mac-arm64)/",
            r"/(osx-x64|osx-arm64)/",
            r"UnrealAndroidFileTool/osx-x64/",
            r"OidcToken/osx-x64/",
            r"ArtToolsOSX/",
            r"UbaAgentHelperMac/",
            # The bare x86_64 Android-ABI exclude also reaches this 5.8.3 tree.
            # Pin it as a supported path so the cut is reported with a reason
            # instead of disappearing as an unclassified third-party path.
            r"^Engine/Source/ThirdParty/Catch2/.*/lib/Mac/x86_64/",
            r"vcpkg-installed/(overlay-arm64-ios|overlay-x64_arm64-osx|arm64-android)/",
        ],
        "declared_cuts": [
            (r"EpicGames\.Perforce\.Native/[a-z0-9-]+/Release/EpicGames\.Perforce\.Native\.(debug|sym)$",
             "debug symbols that ship next to the Perforce native; UAT copies only the library"),
            (r"EpicGames\.Perforce\.Native/[a-z0-9-]+/Debug/",
             "the Debug Perforce native build; EpicGames.Perforce.csproj copies only Release, "
             "and Release is re-included by .gitdepsignore where the RID is cut"),
            (r"DotNet/[0-9.]+/(linux-x64|linux-arm64|win-x64|win-arm64)/",
             "non-host .NET runtime packs"),
            # must stay ahead of the broad Mac-RID rule below: it is the more
            # specific reason for the same files
            (r"DotNet/[0-9.]+/[a-z0-9-]+/sdk/.*/(runtimes/unix|TestHostNetFramework/x86)/",
             "inert Unix/Windows assets inside a KEPT Mac .NET SDK, reached by the bare Unix and "
             "x86 patterns. A handful of files per RID: dotnet-format and the .NET Framework "
             "test host, neither of which runs on macOS."),
            (r"DotNet/[0-9.]+/[a-z0-9-]+/sdk/.*/shims/[^/]*/win-(x64|x86)/",
             "dotnet-format's Windows launcher shims - new in the .NET 10 layout, and they sit "
             "inside the KEPT Mac SDK, so the bare win-x64/win-x86 patterns reach them. Nothing "
             "on macOS executes them."),
            (r"DotNet/[0-9.]+/(mac-x64|mac-arm64)/",
             "the Mac .NET runtime pack this host never executes (see --host-arch). Everything "
             "else Mac - platform binaries, Mac/arm64 libs - is kept, so a universal editor "
             "still builds on either host."),
            (r"cef_binary_90\.6\.7\+g19ba721\+chromium-90\.0\.4430\.212_macosx64",
             "legacy CEF 90.6.7 drop - CEF3.build.cs resolves macos_universal for Mac and "
             "never macosx64, so this is unreachable"),
            (r"Binaries/DotNET/Android/UnrealAndroidFileTool/(linux-x64|win-x64)/",
             "Android deploy tool built for other hosts; osx-x64 is kept"),
            (r"^Engine/Source/ThirdParty/Catch2/.*/lib/Mac/x86_64/",
             "test-only x86_64 Catch2 libraries, reached by the bare x86_64 Android-ABI "
             "pattern. Non-host on Apple Silicon; on an Intel host the editor still builds, "
             "because Catch2 is linked by tests, not by UnrealEditor."),
            (r"/(armeabi-v7a|x86|x86_64)/",
             "non-arm64 Android ABIs (32-bit ARM, x86 emulator)"),
            (r"vcpkg-installed/(overlay-arm64-uwp|overlay-x64-uwp|overlay-x64-windows|overlay-x64-linux|x64-android|x64-windows)/",
             "vcpkg triplets for platforms outside this profile"),
            (r"Apple/(MetalShaderConverter/Windows|ProResLib/lib/windows)/",
             "the Windows-only payload under Apple/. The Windows profile MUST keep these; "
             "this profile must not."),
        ],
        "must_keep": [
            # --- macOS host -------------------------------------------------
            "Engine/Binaries/Mac/BootstrapPackagedGame.app/Contents/MacOS/BootstrapPackagedGame",
            "Engine/Binaries/Mac/UnrealEditorServices.app/Contents/MacOS/UnrealEditorServices",
            "Engine/Binaries/Mac/UnrealSync.app/Contents/MacOS/UnrealSync",
            "Engine/Binaries/Mac/DsymExporter",
            "Engine/Binaries/Mac/EpicWebHelper",
            "Engine/Binaries/Mac/UnrealAtoS",
            "Engine/Binaries/Mac/UnrealTraceServer",
            "Engine/Binaries/Mac/crashpad_handler",
            "Engine/Binaries/Mac/zen",
            "Engine/Binaries/Mac/zenserver",
            "Engine/Binaries/ThirdParty/CEF3/Mac/128.4.13+ge76af7e+chromium-128.0.6613.138/Chromium Embedded Framework.framework/Chromium Embedded Framework",
            "Engine/Binaries/ThirdParty/Apple/MetalShaderConverter/Mac/libmetalirconverter.dylib",
            "Engine/Binaries/ThirdParty/Python3/Mac/bin/python3",
            "Engine/Binaries/ThirdParty/svn/Mac/bin/svn",
            "Engine/Binaries/ThirdParty/ICU/icu4c-53_1/Mac/libicudata.53.1.dylib",
            "Engine/Source/ThirdParty/CEF3/cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_macos_universal/Release/libcef_dll_wrapper.a",
            "Engine/Source/Runtime/SymsLib/lib/Mac/libsyms.a",
            "Engine/Source/ThirdParty/ICU/icu4c-53_1/Mac/lib/libicuuc.a",
            # --- host .NET tooling that UBT/UAT actually execute ------------
            "Engine/Binaries/DotNET/OidcToken/osx-x64/OidcToken",
            # the only Perforce native library that exists for Mac - no arm64
            # build, so it has to survive on an Apple Silicon host too. UAT also
            # copies the win-x64 and linux-x64 builds unconditionally, so the
            # profile re-includes all three via .gitdepsignore.
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/mac-x64/Release/EpicGames.Perforce.Native.dylib",
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/win-x64/Release/EpicGames.Perforce.Native.dll",
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/linux-x64/Release/EpicGames.Perforce.Native.so",
            # UAT compiles IOS.Automation on every host
            "Engine/Source/Programs/AutomationTool/IOS/Resources/GreenCheck.png",
            "Engine/Source/Programs/AutomationTool/IOS/Resources/GreyCheck.png",
            # --- iOS --------------------------------------------------------
            "Engine/Build/IOS/AppleRootCA.pem",
            "Engine/Build/IOS/ConfigRulesTool/ConfigRulesTool.app/Contents/MacOS/ConfigRulesTool",
            "Engine/Build/IOS/UnrealRemoteTool",
            "Engine/Build/IOS/UECmdLineRun/UECmdLineRun-Info.plist",
            "Engine/Source/ThirdParty/IOS/Bolts/Bolts/Lib/Release/libBolts.a",
            "Engine/Source/ThirdParty/IOS/Interpose/Interpose.framework/Interpose",
            "Engine/Source/ThirdParty/ICU/icu4c-53_1/IOS/lib/libicuuc.a",
            "Engine/Extras/ThirdPartyNotUE/libimobiledevice/Mac/idevice_id",
            # --- Android arm64 ----------------------------------------------
            "Engine/Binaries/DotNET/Android/UnrealAndroidFileTool/osx-x64/UnrealAndroidFileTool",
            "Engine/Binaries/ThirdParty/OpenXR/Android/arm64-v8a/libopenxr_loader.so",
            "Engine/Binaries/ThirdParty/Vulkan/Android/arm64-v8a/libVkLayer_khronos_validation.so",
            "Engine/Source/ThirdParty/Android/cxa_demangle/arm64-v8a/libcxa_demangle.a",
            # prefix form: the Oodle Android ABI directory and archive name both
            # changed between 5.7.4 and 5.8.3
            "Engine/Plugins/Compression/OodleNetwork/Sdks/2.9.14/lib/Android/",
            "Engine/Plugins/Runtime/GeoReferencing/Source/ThirdParty/vcpkg-installed/arm64-android/lib/libproj.a",
            "Engine/Plugins/Runtime/GeoReferencing/Source/ThirdParty/vcpkg-installed/overlay-arm64-ios/lib/libproj.a",
            "Engine/Plugins/Runtime/GeoReferencing/Source/ThirdParty/vcpkg-installed/overlay-x64_arm64-osx/lib/libproj.a",
        ],
        "must_keep_by_arch": {
            # the Mac .NET runtime pack the host actually executes. SetupDotnet.sh
            # picks mac-$ARCH straight from uname -m.
            "x86_64": [
                "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/mac-x64/dotnet",
            ],
            "arm64": [
                "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/mac-arm64/dotnet",
            ],
        },
        "dropped_markers": [
            r"^Engine/Binaries/(Linux|Win64|WinArm64)/",
            r"^Engine/Binaries/ThirdParty/CEF3/(Linux|Win64|WinArm64)/",
            r"^Engine/Source/ThirdParty/CEF3/cef_binary_\S*_(linux64|windows64|windowsarm64)",
            r"^Engine/Build/TVOS/",
            r"^Engine/Platforms/(TVOS|VisionOS|Linux)/",
            r"ICU/icu4c-53_1/(TVOS|Linux)/",
            r"^Engine/Source/ThirdParty/OpenSSL/Unix/",
            r"^Engine/Source/Runtime/SymsLib/lib/Unix/",
            r"/(VS2008|VS2012|VS2013|VS2015|VS2017|VS2019|VS2022|gnuwin32)/",
        ],
    },
    # -----------------------------------------------------------------------
    "windows": {
        "label": "Windows host (x64) + Android",
        "supported_markers": [
            r"^Engine/Binaries/Win64/",
            r"^Engine/Binaries/ThirdParty/CEF3/Win64/",
            r"^Engine/Binaries/ThirdParty/Windows/",
            r"^Engine/Source/ThirdParty/Windows/",
            r"^Engine/Binaries/ThirdParty/Apple/",
            r"^Engine/Source/ThirdParty/Apple/ProResLib/",
            r"^Engine/Build/Android/",
            r"^Engine/Source/ThirdParty/Android/",
            r"arm64-v8a/",
            r"/win-x64/",
            r"UnrealAndroidFileTool/win-x64/",
            r"vcpkg-installed/(arm64-android|x64-windows)/",
        ],
        "declared_cuts": [
            (r"EpicGames\.Perforce\.Native/[a-z0-9-]+/Release/EpicGames\.Perforce\.Native\.(debug|sym)$",
             "debug symbols that ship next to the Perforce native; UAT copies only the library"),
            (r"EpicGames\.Perforce\.Native/[a-z0-9-]+/Debug/",
             "the Debug Perforce native build; EpicGames.Perforce.csproj copies only Release, "
             "and Release is re-included by .gitdepsignore where the RID is cut"),
            (r"DotNet/[0-9.]+/win-arm64/",
             "Windows-on-ARM .NET runtime pack - the host is x64. The Windows RIDs are the only "
             "ones that ship all three Windows host packs, so this RID also carries a copy of the "
             "win-x64 pack; the real one lives under win-x64/ and is kept."),
            (r"DotNet/[0-9.]+/win-x64/packs/Microsoft\.NETCore\.App\.Host\.win-arm64/",
             "the Windows-on-ARM host pack that ships inside the win-x64 RID. The whole win-arm64 "
             "RID is dropped anyway, so this copy is dead weight. The win-x64 and win-x86 host "
             "packs alongside it are kept."),
            (r"DotNet/[0-9.]+/win-x64/sdk/.*/(runtimes/unix|TestHostNetFramework/x86)/",
             "inert Unix/Windows-32 assets inside the KEPT win-x64 .NET SDK, reached by the bare "
             "Unix and x86 patterns. dotnet-format and the .NET Framework test host."),
            (r"Binaries/DotNET/Android/UnrealAndroidFileTool/(linux-x64|osx-x64)/",
             "Android deploy tool built for other hosts; win-x64 is kept"),
            (r"/(armeabi-v7a|x86_64)/",
             "non-arm64 Android ABIs: 32-bit ARM and the x86_64 emulator. Note the Windows profile "
             "leaves bare 'x86' alone on purpose - the same segment holds WiX 3.8's 32-bit "
             "installer toolchain and the Win32 DirectX/XAudio2/HLMedia libraries."),
            (r"vcpkg-installed/(overlay-arm64-uwp|overlay-x64-uwp|overlay-x64-windows|overlay-x64-linux|x64-android)/",
             "vcpkg triplets for platforms outside this profile"),
            (r"cef_binary_90\.6\.7\+g19ba721\+chromium-90\.0\.4430\.212_macosx64",
             "legacy CEF drop for macOS"),
            (r"^Engine/Binaries/ThirdParty/Apple/MetalShaderConverter/(Mac|IOS)/",
             "Mac- and iOS-only payload under Apple/; the Windows and include/ parts are kept"),
            (r"Binaries/DotNET/CsvTools/runtimes/(?!win(-x64)?/)",
             "CsvTools native helpers for other .NET RIDs - new in 5.8.3, which grew the set "
             "from one 'win' RID to 25. The win and win-x64 copies are kept."),
            (r"DotNet/[0-9.]+/(linux-x64|linux-arm64|mac-x64|mac-arm64|win-arm64)/.*/shims/",
             "dotnet-format shims that live inside a non-host RID - new in the .NET 10 layout"),
        ],
        "must_keep": [
            "Engine/Binaries/Win64/EpicWebHelper.exe",
            "Engine/Binaries/Win64/MinidumpDiagnostics.exe",
            "Engine/Binaries/Win64/UnrealBuildAccelerator/x64/UbaAgent.exe",
            # prefix form: the runtime drop directory is versioned, and 5.8.3 added
            # a "+v2" rebuild of 128.4.13 next to a new 147.1.5 drop, so a literal
            # path is stale on one of the two engine versions
            "Engine/Binaries/ThirdParty/CEF3/Win64/",
            # the reason "Apple" must never be excluded as a whole on Windows
            "Engine/Binaries/ThirdParty/Apple/MetalShaderConverter/Windows/metalirconverter.dll",
            "Engine/Source/ThirdParty/Apple/ProResLib/lib/windows/ProRes64_VS2017.lib",
            "Engine/Source/ThirdParty/Windows/DirectX/Lib/x64/d3d12.lib",
            # WinRT is not UWP-only: Win64 FreeType libraries live under this
            # segment, so a blanket -exclude=WinRT would break the host build.
            "Engine/Source/ThirdParty/FreeType2/FreeType2-2.4.12/Lib/WinRT/Win64/freetype2412MT.lib",
            # the reason bare "-exclude=x86" is deliberately absent from this
            # profile: WiX 3.8's 32-bit installer toolchain shares that segment
            "Engine/Source/ThirdParty/WiX/3.8/x86/burn.exe",
            "Engine/Source/ThirdParty/WiX/3.8/sdk/lib/x86/dutil.lib",
            "Engine/Source/ThirdParty/WiX/3.8/sdk/x86/sfxca.dll",
            "Engine/Source/Runtime/SymsLib/lib/x64/Release/SymsLib.lib",
            "Engine/Source/ThirdParty/ICU/icu4c-53_1/Win64/VS2015/lib/icuuc.lib",
            "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/win-x64/dotnet.exe",
            "Engine/Binaries/DotNET/Android/UnrealAndroidFileTool/win-x64/UnrealAndroidFileTool.exe",
            "Engine/Binaries/DotNET/OidcToken/win-x64/OidcToken.exe",
            "Engine/Binaries/DotNET/CsvTools/runtimes/win-x64/native/e_sqlite3.dll",
            "Engine/Source/ThirdParty/Android/cxa_demangle/arm64-v8a/libcxa_demangle.a",
            # UAT compiles every automation script module on every host, and
            # EpicGames.Perforce.csproj copies all three Perforce natives
            # unconditionally. -exclude runs before .gitdepsignore, so the
            # profile expresses these cuts in .gitdepsignore with "!" exceptions.
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/win-x64/Release/EpicGames.Perforce.Native.dll",
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/mac-x64/Release/EpicGames.Perforce.Native.dylib",
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/linux-x64/Release/EpicGames.Perforce.Native.so",
            "Engine/Source/Programs/AutomationTool/IOS/Resources/GreenCheck.png",
            "Engine/Source/Programs/AutomationTool/IOS/Resources/GreyCheck.png",
        ],
        "dropped_markers": [
            # These are deliberately broad: a payload can move between trees
            # (CEF3/<platform>, Python3/<platform>, ThirdParty/<platform>) and a
            # narrow marker is how the Windows profile passed while still
            # downloading ~4k files from platforms it claimed to drop.
            r"/(Linux|Mac|Unix|IOS)/",
            r"/(TVOS|VisionOS)/",
            r"/(LinuxArm64|LinuxAArch64)/",
            r"/(linux32|linuxarm)/",
            r"Win32/",
            r"WinArm64/",
            r"ArtToolsOSX/",
            r"UbaAgentHelperMac/",
            r"overlay-arm64-ios/",
            r"winuwp/",
            # Android x86 is deliberately kept: bare x86 also holds WiX 3.8 and
            # Win32 payload. x86_64 and armeabi-v7a are cut, so they need no
            # marker. The alternative CEF branch is a version choice, not a
            # platform marker, so it is not listed either.
        ],
    },
    # -----------------------------------------------------------------------
    "linux": {
        "label": "Linux host (x86_64 or aarch64) + Android arm64",
        "supported_markers": [
            r"^Engine/Binaries/Linux/",
            r"^Engine/Binaries/ThirdParty/CEF3/Linux/",
            r"^Engine/Binaries/ThirdParty/OpenSSL/Unix/",
            r"^Engine/Binaries/ThirdParty/Python3/Linux/",
            r"^Engine/Source/Runtime/SymsLib/lib/Unix/",
            r"^Engine/Source/ThirdParty/OpenSSL/1\.1\.1t/lib/Unix/",
            r"ICU/icu4c-53_1/Linux/",
            r"^Engine/Source/ThirdParty/CEF3/cef_binary_\S*_linux64/",
            r"^Engine/Build/Android/",
            r"^Engine/Source/ThirdParty/Android/",
            r"arm64-v8a/",
            r"/(linux-x64|linux-arm64)/",
            r"UnrealAndroidFileTool/linux-x64/",
            r"OidcToken/linux-x64/",
            r"vcpkg-installed/(overlay-x64-linux|arm64-android)/",
            # the architecture split, in all four of its spellings
            r"x86_64-unknown-linux-gnu/",
            r"aarch64-unknown-linux-gnueabi/",
            r"/LinuxArm64/",
            r"/LinuxAArch64/",
            r"/linux64/",
            r"/linuxarm/",
        ],
        "declared_cuts": [
            (r"EpicGames\.Perforce\.Native/[a-z0-9-]+/Release/EpicGames\.Perforce\.Native\.(debug|sym)$",
             "debug symbols that ship next to the Perforce native; UAT copies only the library"),
            (r"EpicGames\.Perforce\.Native/[a-z0-9-]+/Debug/",
             "the Debug Perforce native build; EpicGames.Perforce.csproj copies only Release, "
             "and Release is re-included by .gitdepsignore where the RID is cut"),
            (r"DotNet/[0-9.]+/(mac-x64|mac-arm64|win-x64|win-arm64)/",
             "non-host .NET runtime packs"),
            (r"DotNet/[0-9.]+/[a-z0-9-]+/sdk/.*/(runtimes/unix|TestHostNetFramework/x86)/",
             "inert assets inside a KEPT Linux .NET SDK, reached by the bare Unix and x86 patterns"),
            (r"DotNet/[0-9.]+/[a-z0-9-]+/sdk/.*/shims/[^/]*/win-(x64|x86)/",
             "dotnet-format's Windows launcher shims - new in the .NET 10 layout, and they sit "
             "inside the KEPT Linux SDK, so the bare win-x64/win-x86 patterns reach them"),
            (r"Binaries/DotNET/Android/UnrealAndroidFileTool/(osx-x64|win-x64)/",
             "Android deploy tool built for other hosts; linux-x64 is kept"),
            (r"/(armeabi-v7a|x86|x86_64)/",
             "non-arm64 Android ABIs (32-bit ARM, x86 emulator)"),
            (r"vcpkg-installed/(overlay-arm64-uwp|overlay-x64-uwp|overlay-x64-windows|overlay-arm64-ios|overlay-x64_arm64-osx|x64-android|x64-windows)/",
             "vcpkg triplets for platforms outside this profile"),
        ],
        # Which architecture counts as "the other one" flips with the host, so
        # the arch rules are declared per host rather than shared.
        "declared_cuts_by_arch": {
            "x86_64": [
                (r"Binaries/DotNET/CsvTools/runtimes/(?!linux-x64/)",
                 "CsvTools native helpers for other .NET RIDs - new in 5.8.3. The linux-x64 copy "
                 "is kept and pinned in must_keep."),
                (r"Programs/Shared/EpicGames\.Oodle/[0-9.]+/runtimes/(?!linux-x64/)",
                 "EpicGames.Oodle native helpers for other .NET RIDs - the SDK moved to a "
                 "runtimes/<rid>/native layout in 5.8.3. The linux-x64 copy is kept."),
                (r"aarch64-unknown-linux-gnueabi",
                 "the other Linux architecture (arm64). The x64 triple is kept and pinned in "
                 "must_keep, and Engine/Binaries/Linux is not arch-split so the host tools stay."),
                (r"/LinuxArm64/",
                 "arm64-Linux third-party payload: vcpkg toolchain, Oodle, Onnxruntime"),
                (r"/LinuxAArch64/",
                 "arm64-Linux Perforce p4api"),
                (r"/linuxarm/",
                 "Oodle core for Linux ARM (this directory holds arm32 and arm64 together)"),
                (r"DotNet/[0-9.]+/linux-arm64/",
                 "the arm64-Linux .NET runtime pack; this host is x86_64"),
            ],
            "arm64": [
                (r"Binaries/DotNET/CsvTools/runtimes/(?!linux-arm64/)",
                 "CsvTools native helpers for other .NET RIDs - new in 5.8.3. The linux-arm64 copy "
                 "is kept and pinned in must_keep."),
                (r"Programs/Shared/EpicGames\.Oodle/[0-9.]+/runtimes/(?!linux-arm64/)",
                 "EpicGames.Oodle native helpers for other .NET RIDs - the SDK moved to a "
                 "runtimes/<rid>/native layout in 5.8.3. The linux-arm64 copy is kept."),
                (r"x86_64-unknown-linux-gnu",
                 "the other Linux architecture (x64). The arm64 triple is kept and pinned in "
                 "must_keep, and Engine/Binaries/Linux is not arch-split so the host tools stay."),
                (r"/linux64/",
                 "x64-Linux Steamworks and OpenVR libraries. Neither ships a Linux arm64 build, "
                 "so there is nothing to keep."),
                (r"/linux32/",
                 "32-bit x86-Linux Steamworks and OpenVR libraries"),
                (r"DotNet/[0-9.]+/linux-x64/",
                 "the x64-Linux .NET runtime pack; this host is aarch64"),
            ],
        },
        "must_keep": [
            # Engine/Binaries/Linux is not arch-split, so these are the host
            # tools on both architectures
            "Engine/Binaries/Linux/EpicWebHelper",
            "Engine/Binaries/Linux/UnrealTraceServer",
            "Engine/Binaries/Linux/UnrealVersionSelector-Linux-Shipping",
            "Engine/Binaries/Linux/dump_syms",
            "Engine/Binaries/Linux/UnrealBuildAccelerator/UbaAgent",
            "Engine/Binaries/ThirdParty/CEF3/Linux/128.4.13+ge76af7e+chromium-128.0.6613.138/Resources/locales/af.pak",
            "Engine/Binaries/ThirdParty/Python3/Linux/bin/python3",
            "Engine/Binaries/ThirdParty/Python3/Linux/bin/pip3.11",
            "Engine/Source/ThirdParty/CEF3/cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_linux64/Release/libcef_dll_wrapper.a",
            "Engine/Binaries/DotNET/Android/UnrealAndroidFileTool/linux-x64/UnrealAndroidFileTool",
            "Engine/Binaries/DotNET/OidcToken/linux-x64/OidcToken",
            # the only Perforce native library that exists for Linux, and it sits
            # under the same linux-x64 segment as the .NET runtime pack. UAT also
            # copies the win-x64 and mac-x64 builds unconditionally.
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/linux-x64/Release/EpicGames.Perforce.Native.so",
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/win-x64/Release/EpicGames.Perforce.Native.dll",
            "Engine/Binaries/DotNET/EpicGames.Perforce.Native/mac-x64/Release/EpicGames.Perforce.Native.dylib",
            # UAT compiles IOS.Automation on every host
            "Engine/Source/Programs/AutomationTool/IOS/Resources/GreenCheck.png",
            "Engine/Source/Programs/AutomationTool/IOS/Resources/GreyCheck.png",
            "Engine/Binaries/ThirdParty/OpenXR/Android/arm64-v8a/libopenxr_loader.so",
            "Engine/Source/ThirdParty/Android/cxa_demangle/arm64-v8a/libcxa_demangle.a",
            # prefix form: the Oodle Android ABI directory and archive name both
            # changed between 5.7.4 and 5.8.3
            "Engine/Plugins/Compression/OodleNetwork/Sdks/2.9.14/lib/Android/",
            "Engine/Plugins/Runtime/GeoReferencing/Source/ThirdParty/vcpkg-installed/arm64-android/lib/libproj.a",
        ],
        "must_keep_by_arch": {
            "x86_64": [
                # the reason "Unix" must be KEPT in this profile: it holds the
                # host's own libraries, unlike on Windows and macOS where the
                # whole segment is dead weight
                "Engine/Binaries/ThirdParty/OpenSSL/Unix/lib/x86_64-unknown-linux-gnu/libssl.so.1.1",
                "Engine/Source/Runtime/SymsLib/lib/Unix/x86_64-unknown-linux-gnu/libsymsd_fPIC.a",
                "Engine/Source/ThirdParty/OpenSSL/1.1.1t/lib/Unix/x86_64-unknown-linux-gnu/libssl.a",
                "Engine/Source/ThirdParty/abseil/20240722.0/lib/Unix/x86_64-unknown-linux-gnu/Release/libabsl_base.a",
                "Engine/Source/ThirdParty/ICU/icu4c-53_1/Linux/x86_64-unknown-linux-gnu/bin/derb",
                "Engine/Binaries/ThirdParty/OpenAL/Linux/x86_64-unknown-linux-gnu/libopenal.so",
                "Engine/Source/ThirdParty/vcpkg/Linux/x86_64-unknown-linux-gnu/libressl_x86_64-unknown-linux-gnu/lib/libcrypto.a",
                "Engine/Source/ThirdParty/Steamworks/Steamv151/sdk/public/steam/lib/linux64/libsdkencryptedappticket.so",
                "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/linux-x64/dotnet",
                "Engine/Binaries/DotNET/CsvTools/runtimes/linux-x64/native/liboo2core.so",
                "Engine/Plugins/Runtime/GeoReferencing/Source/ThirdParty/vcpkg-installed/overlay-x64-linux/lib/libproj.a",
            ],
            "arm64": [
                "Engine/Source/Runtime/SymsLib/lib/Unix/aarch64-unknown-linux-gnueabi/libsyms_fPIC.a",
                "Engine/Source/Runtime/UEJpegComp/Lib/Unix/aarch64-unknown-linux-gnueabi/uejpeg_linux.a",
                "Engine/Source/ThirdParty/abseil/20240722.0/lib/Unix/aarch64-unknown-linux-gnueabi/Release/libabsl_base.a",
                "Engine/Source/ThirdParty/Blosc/Deploy/c-blosc-1.21.0/Unix/aarch64-unknown-linux-gnueabi/lib/libblosc.a",
                # Boost is deliberately not pinned here: its release number is in the
                # path (1.85.0 in 5.7.4, 1.88.0 in 5.8.3) so any literal drifts, and
                # the aarch64 triple is already covered by abseil, Blosc and SymsLib.
                "Engine/Binaries/ThirdParty/OpenAL/Linux/aarch64-unknown-linux-gnueabi/libopenal.so.1",
                "Engine/Source/ThirdParty/vcpkg/LinuxArm64/aarch64-unknown-linux-gnueabi/libressl_aarch64-unknown-linux-gnueabi/lib/libcrypto.a",
                "Engine/Source/ThirdParty/Perforce/p4api-2024.1/LinuxAArch64/lib/libp4api.a",
                "Engine/Plugins/Compression/OodleNetwork/Sdks/2.9.14/lib/LinuxArm64/",
                "Engine/Source/Programs/Shared/EpicGames.Oodle/2.9.10/runtimes/linux-arm64/native/liboo2core.so",
                "Engine/Binaries/ThirdParty/DotNet/{DOTNET_VERSION}/linux-arm64/dotnet",
                "Engine/Binaries/DotNET/CsvTools/runtimes/linux-arm64/native/liboo2core.so",
            ],
        },
        "dropped_markers": [
            r"^Engine/Binaries/(Mac|Win64|WinArm64)/",
            r"^Engine/Binaries/ThirdParty/CEF3/(Mac|Win64|WinArm64)/",
            r"^Engine/Build/(IOS|TVOS)/",
            r"^Engine/Platforms/(IOS|TVOS|VisionOS)/",
            r"^Engine/Binaries/ThirdParty/Apple/",
            r"/(VS2008|VS2012|VS2013|VS2015|VS2017|VS2019|VS2022|gnuwin32)/",
        ],
    },
}


# ---------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------


def find_engine_root(manifest: pathlib.Path) -> pathlib.Path | None:
    """Engine/Build/Commit.gitdeps.xml -> the engine root above it."""
    resolved = manifest.resolve()
    if resolved.name != "Commit.gitdeps.xml":
        return None
    if resolved.parent.name != "Build" or resolved.parent.parent.name != "Engine":
        return None
    return resolved.parent.parent.parent


def resolve_manifest(path: pathlib.Path, explicit: bool) -> pathlib.Path:
    """Locate Commit.gitdeps.xml, walking up from the current directory.

    The profiles are dropped into an engine root and run from there, but these
    tools live in a separate repo, so "the engine root" is not always the
    working directory. Look in the current directory first, then in every
    parent, and only then give up with an actionable message.
    """
    if path.is_file():
        return path
    if not explicit:
        for base in [pathlib.Path.cwd(), *pathlib.Path.cwd().parents]:
            candidate = base / "Engine" / "Build" / "Commit.gitdeps.xml"
            if candidate.is_file():
                return candidate
    sys.exit(
        f"error: manifest not found: {path}\n"
        "hint: run this from an Unreal Engine root (the directory holding Setup.sh),\n"
        "      or pass --manifest /path/to/Engine/Build/Commit.gitdeps.xml"
    )


def discover_dotnet_versions(manifest: pathlib.Path) -> list[str]:
    """Every DotNet runtime-pack version this engine ships, ascending.

    5.7.4 ships two (8.0.300 and 8.0.412), 5.8.3 ships one (10.0).

    The root-anchored excludes in the ARM branches of the macOS and Linux
    profiles name this version, because no path-segment pattern can select
    "the .NET pack for this host" without also matching the host tools that live
    under the same segment. Reading the version back out of the engine keeps that
    pin from going stale - it moved from 8.0.412 to 10.0 between 5.7.4 and 5.8.3,
    and a stale pin silently stops excluding anything.

    Read out of the manifest, because that is the only thing the tool has: the
    manifest decides which runtime packs actually ship, and SetupDotnet.sh only
    decides which of them the host runs.
    """
    versions = set(re.findall(r"ThirdParty/DotNet/([0-9]+\.[0-9]+(?:\.[0-9]+)?)/",
                              manifest.read_text(errors="ignore")))
    return sorted(versions, key=lambda v: [int(x) for x in v.split(".")])


def audit(manifest: pathlib.Path, profile: str, patterns: list[str], verbose: bool,
          strict: bool, host_arch: str, ignore_rules: list[str] | None = None) -> int:
    meta = PROFILES[profile]
    # File names are XML-attribute-escaped; 5.7.4 has one "&amp;" (a licence file),
    # and comparing the raw text would report a present file as absent.
    names = [html.unescape(n)
             for n in re.findall(r'<File Name="([^"]+)"', manifest.read_text(encoding="utf-8"))]
    matcher = Matcher(patterns)
    ignorer = IgnoreRules(ignore_rules or [])

    def which(name: str):
        """The -exclude pattern first (it wins at runtime), then the ignore rule."""
        return matcher.which(name) or ignorer.which(name)

    kept, cut = [], []
    for n in names:
        (cut if which(n) is not None else kept).append(n)

    host_arch = "arm64" if host_arch == "arm64" else "x86_64"
    dotnets = discover_dotnet_versions(manifest)
    dotnet = dotnets[-1] if dotnets else None
    tokens = {"{DOTNET_VERSION}": dotnet or "?"}
    def expand(paths):
        out = []
        for p in paths:
            for k, v in tokens.items():
                p = p.replace(k, v)
            out.append(p)
        return out
    must_keep = []
    for entry in expand(list(meta["must_keep"]) + list(meta.get("must_keep_by_arch", {}).get(host_arch, []))):
        if entry not in must_keep:
            must_keep.append(entry)

    engine_root = find_engine_root(manifest)
    print(f"profile        : {profile} - {meta['label']}")
    print(f"manifest       : {manifest}")
    if engine_root is not None:
        print(f"engine root    : {engine_root}")
    print(f"host arch      : {host_arch}   DotNet runtime pack versions: {', '.join(dotnets) or 'none found'}")
    print(f"exclude args   : {len(patterns)}")
    print(f"ignore rules   : {len(ignorer.rules)} (.gitdepsignore, '!' includes last-match-wins)")
    print(f"files          : {len(names)}  kept {len(kept)}  cut {len(cut)} "
          f"({100 * len(cut) / max(len(names), 1):.1f}% excluded)")
    print()

    kept_set, cut_set = set(kept), set(cut)

    # ---- must-keep: the hard gate ----------------------------------------
    # An entry ending in "/" is a prefix check - "at least one file survives
    # under here". Versioned third-party trees move their internal layout between
    # engine releases (the Oodle Android ABI directory went from arm64/ to
    # arm64-v8a/ and the archive was renamed), so pinning an exact file there
    # just produces drift noise on every upgrade.
    def evaluate(entry):
        if entry.endswith("/"):
            under = [n for n in names if n.startswith(entry)]
            if not under:
                return "absent", None
            surviving = [n for n in under if n in kept_set]
            if surviving:
                return "intact", None
            return "broken", under[0]
        if entry in cut_set:
            return "broken", entry
        if entry in kept_set:
            return "intact", None
        return "absent", None

    broken, absent = [], []
    for entry in must_keep:
        verdict, offender = evaluate(entry)
        if verdict == "broken":
            broken.append((entry, offender))
        elif verdict == "absent":
            absent.append(entry)
    intact = len(must_keep) - len(broken) - len(absent)
    print(f"MUST-KEEP      : {intact}/{len(must_keep)} present and kept")
    if absent:
        print(f"  {len(absent)} not in this manifest (engine version drift, not a failure):")
        for p in absent:
            print(f"    ~ {p}")
    if broken:
        print(f"  {len(broken)} CUT - this profile breaks its own platform:")
        for p, offender in broken:
            print(f"    X {p}")
            print(f"      e.g. {offender}")
            exclude_rule = matcher.which(offender)
            if exclude_rule is not None:
                print(f"      cut by -exclude={exclude_rule}")
            else:
                print(f"      cut by ignore rule={ignorer.which(offender)}")
    print()

    # ---- declared vs unexpected cuts -------------------------------------
    supported = [re.compile(p) for p in meta["supported_markers"]]
    declared_rules = list(meta["declared_cuts"]) + list(meta.get("declared_cuts_by_arch", {}).get(host_arch, []))
    declared = [(re.compile(rx), reason) for rx, reason in declared_rules]

    by_reason = collections.Counter()
    by_reason_examples = collections.defaultdict(list)
    unexpected = collections.Counter()
    unexpected_examples = collections.defaultdict(list)
    for n in cut:
        if not any(rx.search(n) for rx in supported):
            continue
        for rx, reason in declared:
            if rx.search(n):
                by_reason[reason] += 1
                if len(by_reason_examples[reason]) < 2:
                    by_reason_examples[reason].append(n)
                break
        else:
            key = which(n) or "?"
            unexpected[key] += 1
            if len(unexpected_examples[key]) < 3:
                unexpected_examples[key].append(n)

    print("DECLARED CUTS  : supported-platform-looking files cut on purpose")
    if not by_reason:
        print("  (none)")
    for reason, count in by_reason.most_common():
        print(f"  {count:6d}  {reason}")
        if verbose:
            for e in by_reason_examples[reason]:
                print(f"            {e}")
    print()

    print("UNEXPECTED CUTS: supported-platform-looking files cut with no declared reason")
    if not unexpected:
        print("  (none)")
    for pat, count in unexpected.most_common():
        label = "-exclude" if pat in matcher.patterns else "ignore rule"
        print(f"  {count:6d}  matched by {label}={pat}")
        for e in unexpected_examples[pat]:
            print(f"            {e}")
    print()

    # ---- misses ----------------------------------------------------------
    # A must-keep path can legitimately match a "dropped platform" marker: the
    # AutomationTool IOS resources and the three Perforce natives live inside
    # platform trees this profile drops, and .gitdepsignore re-includes them for
    # the host toolchain. They are not leaked savings.
    dropped = [re.compile(p) for p in meta["dropped_markers"]]
    must_keep_exact = {e for e in must_keep if not e.endswith("/")}
    must_keep_prefixes = [e for e in must_keep if e.endswith("/")]

    def deliberately_kept(n: str) -> bool:
        return n in must_keep_exact or any(n.startswith(p) for p in must_keep_prefixes)

    missed = collections.Counter()
    missed_examples = collections.defaultdict(list)
    for n in kept:
        if deliberately_kept(n):
            continue
        for rx in dropped:
            if rx.search(n):
                key = rx.pattern
                missed[key] += 1
                if len(missed_examples[key]) < 2:
                    missed_examples[key].append(n)
                break
    print("MISSES         : dropped-platform payload still being downloaded")
    if not missed:
        print("  (none)")
    for pat, count in missed.most_common():
        print(f"  {count:6d}  {pat}")
        if verbose:
            for e in missed_examples[pat]:
                print(f"            {e}")
    print()

    # ---- stale vs shadowed patterns ---------------------------------------
    # A pattern that matches nothing is not harmful, but it is the shape every
    # silent-drift bug takes: the exclusion that was supposed to drop a platform
    # stops matching because the directory was renamed or version-bumped, and
    # nothing else reports it.
    #
    # `which` stops at the first match, so a pattern can also show zero hits
    # because an earlier pattern already covers every path it would match -
    # e.g. `aarch64-unknown-linux-gnueabi` inside a profile that also excludes
    # `Unix`. That is redundancy, not drift: it needs no maintenance, and
    # calling it stale would send you looking for a renamed directory that
    # never moved. The two are reported separately for that reason.
    hits = collections.Counter()
    for n in cut:
        p = matcher.which(n)
        if p:
            hits[p] += 1

    stale, shadowed = [], []
    for p in matcher.patterns:
        if hits[p]:
            continue
        if any(matcher.direct(p, n) for n in cut):
            shadowed.append(p)
        else:
            stale.append(p)

    print(f"STALE PATTERNS : {len(stale)}/{len(matcher.patterns)} exclude patterns match nothing in this manifest")
    if not stale:
        print("  (none)")
    for p in stale:
        print(f"  - {p}")
    if stale:
        print("  These are doing no work. Expected when one profile spans several engine versions")
        print("  (the CEF drop names are version-specific), but a renamed directory also lands here.")
    print()

    print(f"SHADOWED       : {len(shadowed)} patterns only match paths an earlier pattern already excludes")
    if not shadowed:
        print("  (none)")
    for p in shadowed:
        print(f"  - {p}")
    if shadowed:
        print("  Harmless redundancy, not drift: every path these would match is already cut by a")
        print("  pattern listed earlier, so they are maintenance-free.")
    print()

    failed = bool(broken or unexpected or (strict and (absent or stale)))
    verdict = "FAIL" if failed else "PASS"
    if not failed and stale:
        verdict = "PASS (with stale patterns)"
    print(f"RESULT         : {verdict}")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", type=pathlib.Path, default=None,
                    help="path to Commit.gitdeps.xml (default: Engine/Build/Commit.gitdeps.xml "
                         "in the current directory or the nearest parent)")
    ap.add_argument("--profile", choices=sorted(PROFILES), help="shipped profile to audit")
    ap.add_argument("--from-script", type=pathlib.Path,
                    help="read -exclude= args from this script instead of a shipped profile")
    ap.add_argument("--audit-as", choices=sorted(PROFILES),
                    help="with --from-script, which profile's markers/must-keep to check against")
    ap.add_argument("--scripts-dir", type=pathlib.Path, default=REPO_ROOT / "scripts")
    ap.add_argument("--host-arch", default=current_arch(), choices=["x86_64", "arm64"],
                    help="which architecture's .NET runtime pack the profile keeps "
                         "(default: this machine)")
    ap.add_argument("--strict", action="store_true",
                    help="also fail when a must-keep path is absent from the manifest, "
                         "or when an exclude pattern matches nothing")
    ap.add_argument("--verbose", "-v", action="store_true", help="show example paths")
    ap.add_argument("--selftest", action="store_true", help="check the matcher port against pinned cases")
    args = ap.parse_args()

    if args.selftest:
        return run_selftest()
    if not args.profile and not args.from_script:
        ap.error("pass --profile or --from-script")

    manifest = resolve_manifest(
        args.manifest or pathlib.Path("Engine/Build/Commit.gitdeps.xml"),
        explicit=args.manifest is not None,
    )

    # Kept for --from-script profiles that still expand $DOTNET_VERSION in an
    # exclude pattern; the shipped profiles now express RID cuts in .gitdepsignore.
    dotnet_versions = discover_dotnet_versions(manifest)

    if args.from_script:
        text = args.from_script.read_text()
        patterns = parse_bat_excludes(text) if args.from_script.suffix == ".bat" \
            else parse_sh_excludes(text, args.host_arch, dotnet_versions)
        ignore_rules = parse_bat_ignore_rules(text) if args.from_script.suffix == ".bat" \
            else parse_sh_ignore_rules(text, args.host_arch)
        profile = args.audit_as or next(
            (p for p, f in DEFAULT_SCRIPTS.items() if f == args.from_script.name), "macos")
        if not args.audit_as and profile == "macos" and args.from_script.name != DEFAULT_SCRIPTS["macos"]:
            print(f"note: no profile inferred from {args.from_script.name}; "
                  f"checking against 'macos' markers. Use --audit-as to override.\n")
    else:
        profile = args.profile
        patterns = load_profile_excludes(profile, args.scripts_dir, args.host_arch, dotnet_versions)
        ignore_rules = load_profile_ignore_rules(profile, args.scripts_dir, args.host_arch)

    if not patterns:
        sys.exit(
            "error: no -exclude= arguments were parsed; refusing to audit an empty profile.\n"
            "       Check that the script still builds EXCLUDES+=(-exclude=...) and that\n"
            "       --host-arch selects the branch you meant."
        )

    return audit(manifest, profile, patterns, args.verbose, args.strict, args.host_arch,
                 ignore_rules)


if __name__ == "__main__":
    sys.exit(main())
