#!/bin/bash
# =====================================================================
#  Setup_Minimal.sh - UE 5.7.4 minimal dependency sync for macOS
#  Target platforms: Mac (host arch) + iOS (arm64) + Android (arm64)
#  Everything else - tvOS, visionOS, Linux, Windows - is excluded.
#
#  macOS counterpart of Setup_Minimal.bat (which targets Win64 + Android).
#  Both scripts only ever cut *downloaded* dependency payloads; engine
#  source for every platform is always present in the git tree.
#
#  Usage:
#     ./Setup_Minimal.sh            normal sync
#     ./Setup_Minimal.sh dry        preview only (--dry-run: lists changes, downloads nothing)
#     ./Setup_Minimal.sh --force    overwrite locally modified files
#     ./Setup_Minimal.sh --prompt   prompt before overwriting modified files
#
#  Notes:
#   1. Excluded files are NOT downloaded and NOT deleted. To stay minimal,
#      always sync through this script. The managed .gitdepsignore written
#      below is read by plain ./Setup.sh too, so it no longer re-downloads the
#      platform payload; delete that file to restore a full sync.
#   2. Setup.sh registers .git/hooks/{post-checkout,post-merge} as symlinks to
#      GitDependenciesHook.sh, which runs GitDependencies with NO arguments, so
#      a plain "git pull" would re-download every platform. This script
#      rewrites those two hooks after every run - including "dry" - with the
#      exclude list and nothing else. Per-run flags (--dry-run, --force,
#      --prompt) are never written into them.
#   3. The host architecture decides which Mac .NET runtime pack is kept: on an
#      Intel Mac the Apple Silicon SDK (mac-arm64, ~9.3k files) is excluded, on
#      an M-series Mac the x64 pack is excluded instead. Mac platform binaries
#      and the universal/flat third-party libs are kept on both hosts, so a
#      universal editor still builds either way. The Android ABI cut (bare
#      "x86"/"x86_64") also reaches Mac/x86_64 - in 5.8.3 that is the Catch2
#      test library only - plus a few inert .NET SDK assets; see the ABI block
#      below and the audit's DECLARED CUTS.
#   4. Android is arm64-v8a only: the armeabi-v7a / x86 / x86_64 payloads are
#      excluded, so 32-bit ARM and x86 emulator builds are unavailable. Comment
#      out the "Android ABIs" block below to get them back.
#   5. CEF on Mac always resolves to cef_binary_*_macos_universal (see
#      Engine/Source/ThirdParty/CEF3/CEF3.build.cs), so the legacy macosx64 drop
#      and every other platform's CEF build are excluded.
#   6. Editor localization is NOT excluded, and neither are MetaHuman, Protobuf,
#      PhysX3, Templates or Samples - those are size tiers from the .bat, not
#      platform cuts. They are available as OPTIONAL blocks at the bottom.
#   7. After an engine update (git pull to a new version) the CEF folder names
#      and the manifest change: run "./Setup_Minimal.sh dry" first, and if a
#      parameter becomes invalid re-check the folder names against
#      Engine/Build/Commit.gitdeps.xml.
#   8. Deliberately left in place, because cutting them risks more than it
#      saves: the watchOS slices inside Tentacle.xcframework (removing a slice
#      can invalidate the framework's Info.plist), and the internals of the kept
#      Mac .NET SDK (the Windows-only Microsoft.NET.Sdk.WindowsDesktop component
#      and the tvOS workload manifest - both are inert on Mac but only ~100
#      files). Measured result on this 5.7.4 manifest: 146,315 files -> 86,734
#      kept, 59,581 excluded (40.7%).
#   9. UAT compiles every automation script module on every host, and
#      EpicGames.Perforce.csproj copies all three EpicGames.Perforce.Native
#      builds unconditionally. The non-host RIDs and their Perforce exceptions
#      therefore live in the managed .gitdepsignore (see the RID block below).
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

if [ ! -f Setup.sh ] || [ ! -f Engine/Build/Commit.gitdeps.xml ]; then
	echo "[ERROR] Put this script in the engine root, next to Setup.sh." >&2
	exit 1
fi

# ---- Host architecture ------------------------------------------------------
# uname -m reports arm64 on Apple Silicon; normalize so the branch below reads
# the same everywhere.
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
	arm64|aarch64) HOST_ARCH="arm64" ;;
	x86_64|amd64)  HOST_ARCH="x86_64" ;;
	*)
		echo "[WARN] Unrecognized host architecture '$HOST_ARCH'; assuming x86_64." >&2
		HOST_ARCH="x86_64"
		;;
esac

# ---- Resolve GIT_DIR once, before Setup.sh runs, and share it with Setup.sh --
if [ -z "${GIT_DIR:-}" ]; then
	GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
	[ -n "$GIT_DIR" ] || GIT_DIR=".git"
fi
case "$GIT_DIR" in
	/*) ;;
	*)  GIT_DIR="$SCRIPT_DIR/$GIT_DIR" ;;
esac
export GIT_DIR

EXCLUDES=()

# ---- Other platform trees ---------------------------------------------------
# Bare names match a whole path segment, case-insensitively; keep them that way
# so Mac/ does not collide with mac-arm64/ (see Engine/Source/Programs/
# GitDependencies/Program.cs, IsExcludedFolder).
EXCLUDES+=(
	-exclude=TVOS
	-exclude=VisionOS
	-exclude=Linux
	-exclude=LinuxArm64
	-exclude=LinuxAArch64
	-exclude=linux64
	-exclude=linux32
	-exclude=linuxarm
	-exclude=Win32
	-exclude=Win64
	-exclude=WinArm64
	-exclude=Windows
	-exclude=WinRT
	-exclude=winuwp
	-exclude=Unix
	-exclude=x86_64-unknown-linux-gnu
	-exclude=x86_64-unknown-linux-gpu
	-exclude=aarch64-unknown-linux-gnueabi
)

# ---- Windows-only toolchain trees -------------------------------------------
# Safe to cut on Mac: every one of these holds MSVC-built import libs and DLLs.
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
# Engine/Binaries/ThirdParty/DotNet/{8.0.300,8.0.412}/<rid> - by far the biggest
# single win, ~57k of the manifest's 146k files across all six RIDs. A host only
# ever executes its own; SetupDotnet.sh picks mac-$ARCH straight from uname -m.
# The non-host x64 RIDs are in the managed .gitdepsignore below: each also
# matches EpicGames.Perforce.Native, which UAT needs.
EXCLUDES+=(
	-exclude=linux-arm64
	-exclude=win-arm64
	-exclude=win-x86
)

# Which Mac pack to drop depends on the host:
#   * bare "mac-arm64" occurs nowhere in the manifest except the DotNet tree, so
#     it is safe as a plain segment pattern;
#   * "mac-x64" also appears under EpicGames.Perforce.Native - the only Perforce
#     native library that exists for Mac - so on Apple Silicon the cut (and its
#     exception) lives in .gitdepsignore.
# Mac platform binaries and the Mac/arm64 third-party lib dirs are kept on both
# hosts, so a universal editor still builds either way.
if [ "$HOST_ARCH" = "arm64" ]; then
	KEEP_RID="mac-arm64"
else
	KEEP_RID="mac-x64"
	EXCLUDES+=(-exclude=mac-arm64)
fi

# ---- Managed GitDependencies ignore rules -----------------------------------
# GitDependencies reads .gitdepsignore from the engine root automatically and
# applies "!" rules in order (last match wins). This is the only way to cut a
# coarse platform segment while keeping a few files inside it: a path already
# removed by -exclude cannot be rescued by the ignore file.
# UAT compiles every automation script module on every host, and
# EpicGames.Perforce.csproj copies win-x64, mac-x64 and linux-x64
# EpicGames.Perforce.Native builds unconditionally, so all three must survive.
IGNORE_RULES=(
	'**/win-x64/**'
	'!**/EpicGames.Perforce.Native/win-x64/Release/EpicGames.Perforce.Native.dll'
	'**/linux-x64/**'
	'!**/EpicGames.Perforce.Native/linux-x64/Release/EpicGames.Perforce.Native.so'
)
if [ "$HOST_ARCH" = "arm64" ]; then
	IGNORE_RULES+=(
		'**/mac-x64/**'
		'!**/EpicGames.Perforce.Native/mac-x64/Release/EpicGames.Perforce.Native.dylib'
	)
fi

# ---- CEF builds for other platforms ----------------------------------------
# Mac keeps cef_binary_*_macos_universal (the drop CEF3.build.cs resolves for
# Mac) and the macosarm64 wrapper. The 90.6.7 macosx64 drop is unreachable
# because bUseExperimentalVersion is hard-coded true for Mac.
# The CEF drop names are version-specific and change every engine release - 5.8.3
# adds the 147.1.5 drops and renames the non-experimental windows64 drop to
# +v2_windows64, and drops the 90.6.7 / 93.0.0 trees entirely. So some lines here
# match nothing on any given version; gitdeps_audit.py lists them under STALE
# PATTERNS, and its MISSES section reports any cef_binary_*_<other platform> that
# is still being downloaded after an engine upgrade. That is the signal to update
# this block.
EXCLUDES+=(
	-exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_linux64
	-exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_windows64
	-exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_windowsarm64
	-exclude=cef_binary_90.6.7+g19ba721+chromium-90.0.4430.212_macosx64
	-exclude=cef_binary_90.6.7+g19ba721+chromium-90.0.4430.212_windows64
	-exclude=cef_binary_93.0.0+gf38ce34+chromium-93.0.4577.82_linux64_ozone
	-exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138+v2_windows64
	-exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_linux64
	-exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_windows64
	-exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_windowsarm64
)

# ---- Android ABIs: arm64-v8a only ------------------------------------------
# Drops 32-bit ARM (armeabi-v7a) and the x86/x86_64 emulator ABIs. Comment out
# these three lines if you need emulator or armeabi-v7a packaging.
#
# These are bare segment patterns, so "x86_64" also matches Mac/x86_64. In 5.7.4
# no Mac payload lived there; 5.8.3 added Catch2/v3.11.0/lib/Mac/x86_64/ (two
# test-only static libs). That collateral is accepted: the editor does not link
# Catch2, and the audit declares it separately from the Android payload so it is
# visible rather than silently counted as an Android ABI.
EXCLUDES+=(
	-exclude=armeabi-v7a
	-exclude=x86
	-exclude=x86_64
)

# ---- vcpkg triplets for other platforms ------------------------------------
# Engine/Plugins/Runtime/GeoReferencing/.../vcpkg-installed/<triplet>. Keeps
# overlay-x64_arm64-osx (Mac), overlay-arm64-ios (iOS) and arm64-android.
EXCLUDES+=(
	-exclude=overlay-arm64-uwp
	-exclude=overlay-x64-uwp
	-exclude=overlay-x64-windows
	-exclude=overlay-x64-linux
	-exclude=x64-android
	-exclude=x64-windows
)

# =====================================================================
#  OPTIONAL - size tiers carried over from Setup_Minimal.bat.
#  Uncomment what you want; each one trades functionality for disk.
# =====================================================================
#
# ---- MetaHuman plugin family (~2.9 GiB) ----
# Prereq: disable the MetaHuman AND Bridge plugins in your projects and verify
# UnrealEditor still builds BEFORE relying on this (Bridge is enabled by default
# and depends on MetaHumanSDK, which links the cut Protobuf libraries).
# EXCLUDES+=(
# 	-exclude=/Engine/Plugins/MetaHuman
# 	-exclude=/Engine/Source/ThirdParty/Protobuf
# )
#
# ---- English-only editor UI ----
# EXCLUDES+=( -exclude=/Engine/Content/Localization )
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
# ---- TIER C: disabled-by-default plugins and dead libs (~3 GiB) ----
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
#
# ---- Perforce removal ----
# Requires the PerforceSourceControl / ChangelistReview plugins to be disabled.
# The prebuilt Binaries/DotNET/EpicGames.Perforce.Native is NOT excluded - UAT
# needs it.
# EXCLUDES+=(
# 	-exclude=/Engine/Source/ThirdParty/Perforce
# 	-exclude=/Engine/Extras/P4VUtils
# )

# ---- Argument handling ------------------------------------------------------
# "dry" is only recognised as the first argument, like Setup_Minimal.bat.
EXTRA=()
if [ "${1:-}" = "dry" ]; then
	EXTRA+=(--dry-run)
	shift
fi

# Setup.sh only looks for the double-dash forms when deciding whether to add
# --prompt. A bare "-force" therefore makes GitDependencies receive both
# --prompt and -force, which prints help and exits 0 without syncing. Rewrite
# those two exact tokens; a substring replace would mangle "--force".
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

if [ -e .gitdepsignore ] && ! head -n 1 .gitdepsignore | grep -q '^# Generated by Setup_Minimal'; then
	echo "[ERROR] .gitdepsignore exists and was not generated by this profile." >&2
	echo "[ERROR] Move it aside or merge these rules into it, then re-run:" >&2
	for RULE in "${IGNORE_RULES[@]}"; do echo "         $RULE" >&2; done
	exit 2
fi
{
	echo '# Generated by Setup_Minimal.sh - re-run that script to refresh.'
	for RULE in "${IGNORE_RULES[@]}"; do echo "$RULE"; done
} > .gitdepsignore
echo "[Setup_Minimal] Managed .gitdepsignore written."

echo
echo "[Setup_Minimal] Host arch  : $HOST_ARCH (keeping the $KEEP_RID .NET runtime pack)"
echo "[Setup_Minimal] Platforms  : Mac + iOS arm64 + Android arm64"
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

# Rewrite the hooks on every run, including "dry": Setup.sh replaces them with
# argument-less symlinks, and a preview must not leave a broken hook behind.
# Only the exclude list is persistent; --dry-run/--force/--prompt are per-run.
HOOKS_DIR="$GIT_DIR/hooks"
if [ -d "$HOOKS_DIR" ]; then
	for HOOK in post-checkout post-merge; do
		rm -f "$HOOKS_DIR/$HOOK"
		{
			echo '#!/bin/sh'
			echo '# Generated by Setup_Minimal.sh - re-run that script to refresh.'
			echo '# Keeps git pull / checkout dependency syncs on the minimal platform set.'
			echo 'set -e'
			echo 'REPO_ROOT=$(git rev-parse --show-toplevel)'
			printf 'exec "$REPO_ROOT/Engine/Build/BatchFiles/Mac/GitDependencies.sh"'
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
