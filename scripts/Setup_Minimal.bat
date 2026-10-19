@echo off
setlocal EnableExtensions
pushd "%~dp0"

rem =====================================================================
rem  Setup_Minimal.bat - UE minimal dependency sync (Win64 host + Android arm64)
rem  Audited against the 5.7.4 and 5.8.3 Commit.gitdeps.xml manifests; file
rem  counts and the full cut list are in the repo's README.md. The manifest has
rem  no size field, so savings are counted in files, not bytes.
rem
rem  Unlike the two .sh profiles this one also carries three non-platform cuts
rem  (MetaHuman/Protobuf, editor localization, Perforce) - see TIER B and the P4
rem  block below. Comment them out for a pure platform profile.
rem
rem  Usage:
rem     Setup_Minimal.bat           normal sync
rem     Setup_Minimal.bat dry       preview only (--dry-run, lists changes, no download)
rem     Setup_Minimal.bat --force   overwrite locally modified files (single-dash -force also works, normalized below)
rem     Setup_Minimal.bat --prompt  prompt before overwriting modified files
rem
rem  Notes:
rem   1. Excluded files are NOT downloaded and NOT deleted. To stay minimal,
rem      always sync through this script; running plain Setup.bat fills
rem      everything back in.
rem   2. Setup.bat writes these args into .git\hooks\post-checkout and
rem      post-merge, so future "git pull" auto-syncs reuse the same excludes.
rem      This script rewrites both hooks after every run with only the excludes,
rem      so a "dry" or "--force" run never leaves those flags behind.
rem   3. TIER B excludes the MetaHuman plugin family. MetaHumanSDK is
rem      EnabledByDefault:true - disable MetaHumanSDK in your projects and
rem      verify UnrealEditor builds BEFORE using this. If you need MetaHuman,
rem      comment out the two TIER B lines below.
rem   4. Localization is excluded: editor UI will be English-only.
rem   5. After engine updates (git pull to a new version) CEF folder names and
rem      the manifest change: run "dry" first; if a parameter becomes invalid,
rem      re-check the CEF block below against Engine\Build\Commit.gitdeps.xml.
rem =====================================================================

if not exist "Setup.bat" (
    echo [ERROR] Put this script in the engine root, next to Setup.bat.
    popd
    exit /b 1
)
if not exist "Engine\Build\Commit.gitdeps.xml" (
    echo [ERROR] Engine\Build\Commit.gitdeps.xml not found - run this from the engine root.
    popd
    exit /b 1
)

set "EXCLUDES="
set "EXTRA="
set "REST="

rem Locate the hooks directory before Setup.bat runs. Setup.bat writes its raw
rem argument list into these hooks, so the profile replaces them afterwards with
rem the exclude list only. git may not be on PATH; fall back to .git.
set "REPO_GIT_DIR="
for /f "delims=" %%I in ('git rev-parse --git-common-dir 2^>nul') do set "REPO_GIT_DIR=%%I"
if not defined REPO_GIT_DIR set "REPO_GIT_DIR=.git"
for %%I in ("%REPO_GIT_DIR%") do set "REPO_GIT_DIR=%%~fI"
set "HOOKS_DIR=%REPO_GIT_DIR%\hooks"

rem ---- Other platform dirs ----
set "EXCLUDES=%EXCLUDES% -exclude=Mac -exclude=IOS -exclude=TVOS -exclude=Linux -exclude=VisionOS -exclude=Win32"
rem ---- DotNet runtime packs for other RIDs ----
set "EXCLUDES=%EXCLUDES% -exclude=mac-x64 -exclude=mac-arm64 -exclude=osx-x64 -exclude=osx-arm64 -exclude=linux-x64 -exclude=linux-arm64 -exclude=win-arm64"
rem ---- Leftover platform segments (abseil/Boost/Steamworks etc.). NOTE: do NOT exclude
rem      "Apple" as a segment - Engine/{Binaries,Source}/ThirdParty/Apple also holds
rem      Windows consumers (MetalShaderConverter/metalirconverter.dll+.lib, ProResLib
rem      windows lib) that the Win64 editor build requires. Mac/iOS payloads are still
rem      cut by the Mac/IOS platform excludes above. ----
set "EXCLUDES=%EXCLUDES% -exclude=Unix -exclude=macos -exclude=osx -exclude=linux64"
rem ---- PhysX3 leftovers (only consumer ApexDestruction plugin is disabled by default) ----
set "EXCLUDES=%EXCLUDES% -exclude=PhysX3"
rem ---- CEF non-win64 dirs (keep both win64 versions: editor WebBrowser/Insights need them) ----
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_linux64"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_macos_universal"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_windowsarm64"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_linux64"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_windowsarm64"
rem ---- Android ABIs: arm64-v8a only ----
rem Drops 32-bit ARM (armeabi-v7a) and the x86_64 emulator ABI. Comment out these
rem two lines if you need emulator or armeabi-v7a packaging.
rem Deliberately NOT excluded: bare "-exclude=x86". The Android x86 payloads are
rem only ~40 small static libs, but the same path segment also holds WiX 3.8's
rem 32-bit installer toolchain (WiX/3.8/x86/burn.exe, sdk/x86/sfxca.dll,
rem sdk/lib/x86/*.lib) plus EOSSDK/SDK/Bin/x86 and the DirectX/XAudio2/HLMedia
rem Win32 libraries. On macOS and Linux those are already dead weight, so those
rem profiles do use bare x86; on Windows they are not worth risking for 40 files.
set "EXCLUDES=%EXCLUDES% -exclude=armeabi-v7a"
set "EXCLUDES=%EXCLUDES% -exclude=x86_64"
rem ---- TIER B: disable MetaHumanSDK plugin first, or UnrealEditor build breaks ----
set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Plugins/MetaHuman"
set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Source/ThirdParty/Protobuf"
rem ---- English-only: editor localization content ----
set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Content/Localization"

rem ---- Optional extras (uncomment; cutting Templates/Samples breaks new-project templates) ----
rem set "EXCLUDES=%EXCLUDES% -exclude=Templates -exclude=Samples -exclude=Engine/Documentation -exclude=/Engine/Extras/ThirdPartyNotUE"

rem ---- TIER C (optional, saves another ~3.03 GiB, total ~9.91 GiB): disabled-by-default
rem      plugins and dead libs. Prereq: never enable these plugins in projects; if a
rem      build errors about missing files, remove the matching line and re-sync. ----
rem set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Plugins/Experimental/ProceduralVegetationEditor -exclude=/Engine/Plugins/Experimental/TextToSpeech -exclude=/Engine/Plugins/Experimental/MeshPartition -exclude=/Engine/Plugins/Experimental/PCGPrimitives -exclude=/Engine/Plugins/Experimental/PCGPrimitives_MeshPartitionInterop -exclude=/Engine/Plugins/Experimental/NNERuntimeIREE -exclude=/Engine/Plugins/Experimental/NNERuntimeRDG -exclude=/Engine/Plugins/Experimental/MoverTests -exclude=/Engine/Plugins/Experimental/MoverExamples -exclude=/Engine/Plugins/Experimental/ChaosModularVehicleExamples -exclude=/Engine/Plugins/Experimental/Volumetrics -exclude=/Engine/Plugins/Experimental/PCGBiomeSample -exclude=/Engine/Plugins/Experimental/Water -exclude=/Engine/Plugins/Experimental/WaterAdvanced -exclude=/Engine/Plugins/Experimental/WaterExtras -exclude=/Engine/Plugins/Experimental/Landmass -exclude=/Engine/Plugins/Experimental/SemanticSearch"
rem set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Plugins/Runtime/GeoReferencing -exclude=/Engine/Plugins/Runtime/OpenCV -exclude=/Engine/Plugins/Runtime/Harmonix -exclude=/Engine/Plugins/Runtime/HDRIBackdrop -exclude=/Engine/Plugins/Runtime/USDCore"
rem set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Plugins/Media/PixelStreaming2 -exclude=/Engine/Plugins/Media/AjaMedia"
rem set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Source/ThirdParty/HarfBuzz/harfbuzz-12.2.0 -exclude=/Engine/Source/ThirdParty/Perforce/p4api-2024.1 -exclude=/Engine/Source/ThirdParty/Perforce/p4api-2025.1 -exclude=/Engine/Source/ThirdParty/Catch2 -exclude=/Engine/Source/ThirdParty/FAISS -exclude=/Engine/Source/ThirdParty/OpenBLAS -exclude=/Engine/Source/ThirdParty/vcpkg -exclude=/Engine/Source/ThirdParty/WebRTC -exclude=/Engine/Source/ThirdParty/abseil"

rem ---- P4 full removal: ACTIVE. Requires PerforceSourceControl/ChangelistReview
rem      plugins disabled (their .uplugin EnabledByDefault was flipped to false,
rem      .bak backups alongside), otherwise the editor build still needs
rem      p4api-2021.2. The prebuilt Binaries/DotNET/EpicGames.Perforce.Native.dll
rem      is NOT excluded - UAT needs it. To restore P4 support: restore the .bak
rem      files and remove this line, then re-sync. ----
set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Source/ThirdParty/Perforce -exclude=/Engine/Extras/P4VUtils"

rem ---- Arguments ----------------------------------------------------------
rem "dry" is only recognised as the first argument. Capture the remaining
rem arguments too, so "Setup_Minimal.bat dry --force" previews a forced
rem overwrite instead of silently dropping --force.
set "WAS_DRY="
set "REST=%*"
if /I "%~1"=="dry" set "WAS_DRY=1"
if defined WAS_DRY set "EXTRA=--dry-run"
if defined WAS_DRY shift
if defined WAS_DRY set "REST=%*"

rem Setup.bat only recognizes --force/--prompt (double dash) when deciding whether to add
rem --prompt; passing a bare "-force" or "-prompt" makes GitDependencies receive --prompt
rem AND that token, an invalid combo that just prints help and exits 0 without syncing.
rem Normalize the single-token case here; when combining with other arguments use the
rem double-dash spellings. (Do NOT use substring replacement - it would mangle --force.)
if /I "%REST%"=="-force" set "REST=--force"
if /I "%REST%"=="-prompt" set "REST=--prompt"

rem Reject anything this profile does not understand before it reaches
rem GitDependencies, and reject --force + --prompt together: the parser consumes
rem -prompt first, leaves -force unconsumed, and exits 0 after printing help.
set "HAS_FORCE="
set "HAS_PROMPT="
if defined REST (
    for %%A in (%REST%) do (
        if /I "%%A"=="--force" set "HAS_FORCE=1"
        if /I "%%A"=="--prompt" set "HAS_PROMPT=1"
        if /I not "%%A"=="--force" if /I not "%%A"=="--prompt" goto :bad_arg
    )
)
if defined HAS_FORCE if defined HAS_PROMPT goto :bad_combo

echo.
echo [Setup_Minimal] Args:
echo %EXCLUDES% %EXTRA% %REST%
echo.

rem CALL is required: running Setup.bat without it terminates this script, so
rem the error handling, hook refresh and popd below would never run.
call .\Setup.bat %EXTRA% %EXCLUDES% %REST%
set "EC=%ERRORLEVEL%"

rem Setup.bat has just written its raw argument list into both hooks. Replace
rem them with the exclude-only form so a dry or --force run cannot poison future
rem "git pull" syncs. Only the excludes are persistent.
if exist "%HOOKS_DIR%" (
    call :write_hook post-checkout
    call :write_hook post-merge
    echo [Setup_Minimal] Git hooks updated with the minimal exclude list.
)

if %EC% NEQ 0 (
    echo [ERROR] Setup failed with code %EC%. Check the GitDependencies output above.
) else (
    echo [OK] Dependency sync finished.
)
popd
exit /b %EC%

:bad_arg
echo [ERROR] Unsupported argument: %REST%
echo [ERROR] This profile accepts only "dry", "--force" and "--prompt".
popd
exit /b 2

:bad_combo
echo [ERROR] --force and --prompt are mutually exclusive; GitDependencies rejects both together.
popd
exit /b 2

:write_hook
rem Helpers for the 5.7.4/5.8.3 Setup.bat layout: a /bin/sh hook with the
rem GitDependencies executable called relative to the engine root.
> "%HOOKS_DIR%\%~1" echo #!/bin/sh
>> "%HOOKS_DIR%\%~1" echo # Generated by Setup_Minimal.bat - re-run that script to refresh.
>> "%HOOKS_DIR%\%~1" echo # Keeps git pull / checkout dependency syncs on the minimal platform set.
>> "%HOOKS_DIR%\%~1" echo Engine/Binaries/DotNET/GitDependencies/win-x64/GitDependencies.exe %EXCLUDES%
exit /b
