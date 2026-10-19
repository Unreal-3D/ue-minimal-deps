#!/bin/bash
# =====================================================================
#  Setup_Minimal_linux.sh - UE minimal dependency sync for Linux
#  Target platforms: Linux (this machine's architecture) + Android (arm64)
#  Everything else - macOS, iOS, tvOS, visionOS, Windows, and the other
#  Linux architecture - is excluded.
#
#  Usage:
#     ./Setup_Minimal_linux.sh            normal sync
#     ./Setup_Minimal_linux.sh dry        preview only (--dry-run)
#     ./Setup_Minimal_linux.sh --force    overwrite locally modified files
#     ./Setup_Minimal_linux.sh --prompt   prompt before overwriting modified files
#
#  Notes:
#   1. Excluded files are NOT downloaded and NOT deleted. To stay minimal,
#      always sync through this script - a plain ./Setup.sh fills everything
#      back in.
#   2. Setup.sh's Linux branch writes the arguments it was given straight into
#      .git/hooks/{post-checkout,post-merge}. That keeps the exclude list, but
#      it would also persist per-run flags: a "dry" run leaves --dry-run in the
#      hooks (future pulls download nothing), and --force makes future pulls
#      overwrite locally modified files. This script rewrites both hooks after
#      every run with the exclude list only.
#   3. The "Unix" path segment is a Linux payload in UE, not a synonym for
#      "Unix-like": Engine/Source/Runtime/SymsLib/lib/Unix/ holds only
#      x86_64-unknown-linux-gnu and aarch64-unknown-linux-gnueabi. It is kept
#      here. The Windows and macOS profiles exclude it; this one must not.
#   4. Apple/ is excluded. On Windows that directory has to stay because the
#      Win64 editor build consumes Apple/MetalShaderConverter/Windows and
#      Apple/ProResLib/lib/windows - neither exists on Linux.
#   5. Android is arm64-v8a only (no armeabi-v7a, no x86/x86_64 emulator ABIs).
#      Comment out the "Android ABIs" block to get them back.
#   6. Verified against the 5.7.4 manifest with gitdeps_audit.py, but not yet
#      field-tested on a real Linux host. The tools stay in the repo (this script
#      lives in the engine root), so run the audit from the engine root after an
#      engine update with an absolute path:
#        python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile linux
#        python3 /path/to/ue-minimal-deps/tools/gitdeps_audit.py --profile linux --host-arch arm64
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

if [ ! -f Setup.sh ] || [ ! -f Engine/Build/Commit.gitdeps.xml ]; then
	echo "[ERROR] Put this script in the engine root, next to Setup.sh." >&2
	exit 1
fi

# ---- Host architecture ------------------------------------------------------
# uname -m reports aarch64 on Linux ARM and x86_64 on Intel/AMD; normalize so the
# branch below reads the same on every host.
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
	arm64|aarch64) HOST_ARCH="arm64" ;;
	x86_64|amd64)  HOST_ARCH="x86_64" ;;
	*)
		echo "[WARN] Unrecognized host architecture '$HOST_ARCH'; assuming x86_64." >&2
		HOST_ARCH="x86_64"
		;;
esac

# ---- Locate the hooks directory -------------------------------------------
# Setup.sh writes the raw argument list into these hooks, so a dry or --force
# run would leave those flags behind. Find the directory before running it and
# replace both hooks afterwards; see the hook block at the end.
GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
[ -n "$GIT_DIR" ] || GIT_DIR=".git"
case "$GIT_DIR" in
	/*) ;;
	*)  GIT_DIR="$SCRIPT_DIR/$GIT_DIR" ;;
esac
HOOKS_DIR="$GIT_DIR/hooks"

# ---- .NET runtime-pack versions --------------------------------------------
# The ARM branch below has to name the DotNet tree explicitly, because no
# path-segment pattern can select "the .NET pack for this host" without also
# matching the host tools that share the same segment (see the comment further
# down). Enumerate the versions from the manifest instead of hard-coding one: the
# set changes between engine releases (5.7.4 ships 8.0.300 and 8.0.412, 5.8.3
# ships 10.0), and a stale pin stops excluding anything at all, silently.
DOTNET_VERSIONS=$(sed -n 's|.*ThirdParty/DotNet/\([0-9][0-9.]*\)/.*|\1|p' \
	Engine/Build/Commit.gitdeps.xml 2>/dev/null | sort -u)
if [ -z "$DOTNET_VERSIONS" ]; then
	echo "[WARN] No DotNet runtime-pack versions found in Engine/Build/Commit.gitdeps.xml." >&2
	echo "[WARN] The other-architecture runtime pack will not be excluded." >&2
fi

EXCLUDES=()

# ---- Other platform trees ---------------------------------------------------
# Bare names match a whole path segment, case-insensitively. Mac and macos are
# therefore different patterns, and neither touches mac-x64.
EXCLUDES+=(
	-exclude=Mac
	-exclude=IOS
	-exclude=TVOS
	-exclude=VisionOS
	-exclude=Win32
	-exclude=Win64
	-exclude=WinArm64
	-exclude=Windows
	-exclude=WinRT
	-exclude=winuwp
	-exclude=Apple
	-exclude=macos
	-exclude=osx
	-exclude=ArtToolsOSX
	-exclude=UbaAgentHelperMac
	-exclude=MacOS
	-exclude=MacOSX
)

# ---- Windows-only toolchain trees -------------------------------------------
EXCLUDES+=(
	-exclude=VS2008
	-exclude=VS2012
	-exclude=VS2013
	-exclude=VS2015
	-exclude=VS2015_ClangCL
	-exclude=VS2017
	-exclude=VS2019
	-exclude=VS2022
	-exclude=gnuwin32
)

# ---- .NET runtime packs for platforms we do not build on --------------------
# Engine/Binaries/ThirdParty/DotNet/{8.0.300,8.0.412}/<rid>. The Linux RID is
# host-dependent and is handled in the architecture block below.
EXCLUDES+=(
	-exclude=mac-x64
	-exclude=mac-arm64
	-exclude=osx-x64
	-exclude=osx-arm64
	-exclude=win-x64
	-exclude=win-arm64
	-exclude=win-x86
)

# ---- CEF builds for other platforms ----------------------------------------
# CEF3.build.cs resolves a "linux64" drop for Linux, so both 128.4.13_linux64
# and 147.1.5_linux64 are kept. The 93.0.0 linux64_ozone drop is unreachable
# (bUseExperimentalVersion is hard-coded true) but is kept anyway: it is the only
# CEF drop for the non-experimental branch, and this profile has not been
# field-tested, so the cost of being wrong is higher than the few hundred KB it
# saves. CEF drop names are version-specific - gitdeps_audit.py reports stale
# patterns and any missed non-Linux drop after an engine upgrade.
EXCLUDES+=(
	-exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_macos_universal
	-exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_windows64
	-exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_windowsarm64
	-exclude=cef_binary_90.6.7+g19ba721+chromium-90.0.4430.212_macosx64
	-exclude=cef_binary_90.6.7+g19ba721+chromium-90.0.4430.212_macosarm64
	-exclude=cef_binary_90.6.7+g19ba721+chromium-90.0.4430.212_windows64
	-exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138+v2_windows64
	-exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_windows64
	-exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_windowsarm64
)

# ---- Android ABIs: arm64-v8a only ------------------------------------------
EXCLUDES+=(
	-exclude=armeabi-v7a
	-exclude=x86
	-exclude=x86_64
)

# ---- vcpkg triplets for other platforms ------------------------------------
# Keeps overlay-x64-linux and arm64-android.
EXCLUDES+=(
	-exclude=overlay-arm64-uwp
	-exclude=overlay-x64-uwp
	-exclude=overlay-x64-windows
	-exclude=overlay-arm64-ios
	-exclude=overlay-x64_arm64-osx
	-exclude=x64-android
	-exclude=x64-windows
)

# ---- Linux payloads for the OTHER architecture ------------------------------
# The arch split is spelled four different ways in the manifest, and there is no
# single pattern that covers it:
#     <dir>/Unix/<triple>  and  <dir>/Linux/<triple>   most third-party libs
#     LinuxArm64                                       vcpkg, Oodle, Onnxruntime
#     LinuxAArch64                                     Perforce p4api
#     linux64 / linux32 / linuxarm                     Steamworks, OpenVR, Oodle
# Note Engine/Binaries/Linux is NOT arch-split - there is no
# Engine/Binaries/LinuxArm64 in the manifest - so the Linux host tools are kept
# on both architectures.
#
# The two branches are spelled differently on purpose:
#   * bare "linux-arm64" occurs nowhere in the manifest except the DotNet tree,
#     so it is safe as a plain segment pattern;
#   * "linux-x64" also appears under Engine/Binaries/DotNET/ for the Android
#     deploy tool, the OidcToken helper and EpicGames.Perforce.Native - the only
#     Perforce native library that exists for Linux - so on aarch64 the cut has
#     to be root-anchored to the DotNet tree to leave those alone.
# The version is read out of Engine/Build/Commit.gitdeps.xml at run time (the
# DOTNET_VERSIONS block above), so it does not need bumping on an engine upgrade.
if [ "$HOST_ARCH" = "arm64" ]; then
	EXCLUDES+=(
		-exclude=x86_64-unknown-linux-gnu
		-exclude=linux64
		-exclude=linux32
	)
	for DOTNET_VERSION in $DOTNET_VERSIONS; do
		EXCLUDES+=("-exclude=/Engine/Binaries/ThirdParty/DotNet/$DOTNET_VERSION/linux-x64")
	done
else
	EXCLUDES+=(
		-exclude=aarch64-unknown-linux-gnueabi
		-exclude=LinuxArm64
		-exclude=LinuxAArch64
		# linuxarm holds the arm32 and arm64 Oodle core side by side, so it can
		# only be dropped whole. linux32 (32-bit Steamworks/OpenVR) is left in
		# place on this branch: it is ~13 files, and cutting it would re-baseline
		# the measured file counts in the README. Drop it once you have re-run
		# the audit and are happy to update those numbers.
		-exclude=linuxarm
		-exclude=linux-arm64
	)
fi

# =====================================================================
#  OPTIONAL - size tiers that trade functionality for disk.
# =====================================================================
#
# ---- English-only editor UI ----
# EXCLUDES+=( -exclude=/Engine/Content/Localization )
#
# ---- MetaHuman plugin family ----
# Prereq: disable the MetaHumanSDK plugin in your projects and verify the editor
# still builds BEFORE relying on this.
# EXCLUDES+=(
# 	-exclude=/Engine/Plugins/MetaHuman
# 	-exclude=/Engine/Source/ThirdParty/Protobuf
# )
#
# ---- Templates / Samples / docs ----
# Cutting Templates breaks the new-project template list in the editor.
# EXCLUDES+=(
# 	-exclude=Templates
# 	-exclude=Samples
# 	-exclude=Engine/Documentation
# 	-exclude=/Engine/Extras/ThirdPartyNotUE
# )
#
# ---- PhysX3 leftovers ----
# Only consumer is the ApexDestruction plugin, disabled by default.
# EXCLUDES+=( -exclude=PhysX3 )
#
# ---- TIER C: disabled-by-default plugins and dead libs ----
# Prereq: never enable these plugins in projects. If a build errors about
# missing files, remove the matching line and re-sync.
# EXCLUDES+=(
# 	-exclude=/Engine/Plugins/Experimental/ProceduralVegetationEditor
# 	-exclude=/Engine/Plugins/Experimental/TextToSpeech
# 	-exclude=/Engine/Plugins/Experimental/MeshPartition
# 	-exclude=/Engine/Plugins/Experimental/PCGPrimitives
# 	-exclude=/Engine/Plugins/Experimental/PCGPrimitives_MeshPartitionInterop
# 	-exclude=/Engine/Plugins/Experimental/NNERuntimeIREE
# 	-exclude=/Engine/Plugins/Experimental/NNERuntimeRDG
# 	-exclude=/Engine/Plugins/Experimental/MoverTests
# 	-exclude=/Engine/Plugins/Experimental/MoverExamples
# 	-exclude=/Engine/Plugins/Experimental/ChaosModularVehicleExamples
# 	-exclude=/Engine/Plugins/Experimental/Volumetrics
# 	-exclude=/Engine/Plugins/Experimental/PCGBiomeSample
# 	-exclude=/Engine/Plugins/Experimental/Water
# 	-exclude=/Engine/Plugins/Experimental/WaterAdvanced
# 	-exclude=/Engine/Plugins/Experimental/WaterExtras
# 	-exclude=/Engine/Plugins/Experimental/Landmass
# 	-exclude=/Engine/Plugins/Experimental/SemanticSearch
# 	-exclude=/Engine/Plugins/Runtime/GeoReferencing
# 	-exclude=/Engine/Plugins/Runtime/OpenCV
# 	-exclude=/Engine/Plugins/Runtime/Harmonix
# 	-exclude=/Engine/Plugins/Runtime/HDRIBackdrop
# 	-exclude=/Engine/Plugins/Runtime/USDCore
# 	-exclude=/Engine/Plugins/Media/PixelStreaming2
# 	-exclude=/Engine/Plugins/Media/AjaMedia
# 	-exclude=/Engine/Source/ThirdParty/HarfBuzz/harfbuzz-12.2.0
# 	-exclude=/Engine/Source/ThirdParty/Perforce/p4api-2024.1
# 	-exclude=/Engine/Source/ThirdParty/Perforce/p4api-2025.1
# 	-exclude=/Engine/Source/ThirdParty/Catch2
# 	-exclude=/Engine/Source/ThirdParty/FAISS
# 	-exclude=/Engine/Source/ThirdParty/OpenBLAS
# 	-exclude=/Engine/Source/ThirdParty/vcpkg
# 	-exclude=/Engine/Source/ThirdParty/WebRTC
# 	-exclude=/Engine/Source/ThirdParty/abseil
# )

# ---- Argument handling ------------------------------------------------------
EXTRA=()
if [ "${1:-}" = "dry" ]; then
	EXTRA+=(--dry-run)
	shift
fi

# Setup.sh only recognises the double-dash forms when deciding whether to add
# --prompt. A bare "-force" makes GitDependencies receive --prompt AND -force,
# which prints help and exits 0 without syncing anything.
REST=()
for ARG in "$@"; do
	case "$ARG" in
		-force|-prompt) REST+=("-$ARG") ;;
		*)              REST+=("$ARG") ;;
	esac
done

# GitDependencies consumes -prompt before it looks at -force, so passing both
# leaves -force unconsumed: it prints help and exits 0. Catch that here instead
# of trusting the exit code.
HAS_FORCE=0
HAS_PROMPT=0
for ARG in "${REST[@]}"; do
	case "$ARG" in
		--force)  HAS_FORCE=1 ;;
		--prompt) HAS_PROMPT=1 ;;
	esac
done
if [ "$HAS_FORCE" -eq 1 ] && [ "$HAS_PROMPT" -eq 1 ]; then
	echo "[ERROR] --force and --prompt are mutually exclusive; GitDependencies rejects both together." >&2
	exit 2
fi

echo
echo "[Setup_Minimal] Platforms  : Linux $HOST_ARCH + Android arm64"
echo "[Setup_Minimal] Excludes   : ${#EXCLUDES[@]}"
echo "[Setup_Minimal] Args       : ${EXTRA[*]} ${EXCLUDES[*]} ${REST[*]}"
echo

# GitDependencies exits 0 when it rejects an argument (it just prints help), so
# keep the output and check for the message rather than trusting $?.
LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/setup_minimal.XXXXXX" 2>/dev/null)
if [ -n "$LOG_FILE" ]; then
	trap 'rm -f "$LOG_FILE"' EXIT
	./Setup.sh "${EXTRA[@]}" "${EXCLUDES[@]}" "${REST[@]}" 2>&1 | tee "$LOG_FILE"
	EC=${PIPESTATUS[0]}
else
	./Setup.sh "${EXTRA[@]}" "${EXCLUDES[@]}" "${REST[@]}"
	EC=$?
fi
if [ -n "$LOG_FILE" ] && grep -q 'Invalid command line parameter' "$LOG_FILE"; then
	echo "[ERROR] GitDependencies rejected an argument; nothing was synced." >&2
	echo "[ERROR] Check the usage text above, then use only the flags listed by this profile." >&2
	EC=2
fi

# Setup.sh has just written its raw argument list into these hooks. Replace
# them with the exclude-only form so a dry or --force run cannot poison future
# "git pull" syncs. Only the excludes are persistent.
if [ -d "$HOOKS_DIR" ]; then
	for HOOK in post-checkout post-merge; do
		rm -f "$HOOKS_DIR/$HOOK"
		{
			echo '#!/bin/sh'
			echo '# Generated by Setup_Minimal_linux.sh - re-run that script to refresh.'
			echo '# Keeps git pull / checkout dependency syncs on the minimal platform set.'
			echo 'set -e'
			echo 'REPO_ROOT=$(git rev-parse --show-toplevel)'
			printf 'exec "$REPO_ROOT/Engine/Build/BatchFiles/Linux/GitDependencies.sh"'
			for EX in "${EXCLUDES[@]}"; do printf " '%s'" "$EX"; done
			printf '\n'
		} > "$HOOKS_DIR/$HOOK"
		chmod +x "$HOOKS_DIR/$HOOK"
	done
	echo "[Setup_Minimal] Git hooks updated with the minimal exclude list."
fi

if [ $EC -ne 0 ]; then
	echo "[ERROR] Setup failed with code $EC. Check the GitDependencies output above." >&2
else
	echo "[OK] Dependency sync finished."
fi

exit $EC
