@echo off
setlocal EnableExtensions
pushd "%~dp0"

rem =====================================================================
rem  Setup_Minimal.bat - UE minimal dependency sync (Win64 host + Android arm64)
rem  Audited against the 5.7.4, 5.8.3 and ue6-main (UE6) Commit.gitdeps.xml
rem  manifests; file counts and the full cut list are in the repo's README.md.
rem  Sizes come from the manifest <Blobs> table (present from 5.8 on) and are
rem  what tools/gitdeps_audit.py prints: ue6-main ships 136,346 dependency files
rem  totalling 88.87 GiB; this profile keeps ~28.1 GiB of them, and the optional
rem  TIER C block below takes another ~6.4 GiB off on UE6.
rem
rem  Unlike the two .sh profiles this one also carries three non-platform cuts
rem  (MetaHuman/Protobuf, editor localization, Perforce) - see TIER B and the P4
rem  block below. Comment them out for a pure platform profile.
rem
rem  Usage:
rem     Setup_Minimal.bat           normal sync (MetaHuman family + Protobuf cut)
rem     Setup_Minimal.bat dry       preview only (--dry-run, lists changes, no download)
rem     Setup_Minimal.bat --force   overwrite locally modified files (single-dash -force also works, normalized below)
rem     Setup_Minimal.bat --prompt  prompt before overwriting modified files
rem     Setup_Minimal.bat --keep-metahuman
rem                                 keep the MetaHuman payload (and its Protobuf
rem                                 libs) and leave the plugin enabled
rem     Setup_Minimal.bat --no-cache
rem                                 do not keep GitDependencies' compressed blob
rem                                 cache in .git\ue-gitdeps (~11 GiB after a full
rem                                 UE6 sync); a later engine bump re-downloads
rem
rem  Notes:
rem   1. Excluded files are NOT downloaded and NOT deleted. To stay minimal,
rem      always sync through this script. The managed .gitdepsignore written
rem      below is read by plain Setup.bat too, so it no longer re-downloads the
rem      platform payload; delete that file to restore a full sync.
rem   2. Setup.bat writes these args into .git\hooks\post-checkout and
rem      post-merge, so future "git pull" auto-syncs reuse the same excludes.
rem      This script rewrites both hooks after every run with only the excludes,
rem      so a "dry" or "--force" run never leaves those flags behind.
rem   3. TIER B excludes the MetaHuman plugin family (7.58 GiB on UE6, of which
rem      MetaHumanCharacter content alone is 6.49 GiB) and Protobuf (3.93 GiB).
rem      MetaHumanSDKEditor links the Protobuf static libs, and 5.8.3 ships
rem      MetaHumanSDK with EnabledByDefault:false - but UE6 flips it to true, so
rem      the editor would try to build a plugin whose payload is cut. On UE6 this
rem      script therefore disables MetaHumanSDK in its .uplugin (keeping a .bak
rem      next to it) before syncing. Pass --keep-metahuman to skip that and keep
rem      the payload instead; on 5.8.3 that also clears the plugin edit when the
rem      .bak still exists. Bridge stays enabled by default, as on 5.8.3 (where
rem      that combination builds), and tolerates the disabled dependency. The
rem      ue6-main editor build has not been compiled yet - see the README.
rem   4. Localization is excluded: editor UI will be English-only.
rem   5. After engine updates (git pull to a new version) CEF folder names and
rem      the manifest change: run "dry" first; if a parameter becomes invalid,
rem      re-check the CEF block below against Engine\Build\Commit.gitdeps.xml.
rem   6. Three bare segment cuts (IOS, mac-x64, linux-x64) live in the managed
rem      .gitdepsignore instead of EXCLUDES, because each also matches inputs
rem      that UBT/UAT need on this host. GitDependencies cannot re-include a
rem      path already cut by -exclude, so the ignore file carries the cut and
rem      the "!" exceptions (AutomationTool/IOS/Resources and the three
rem      EpicGames.Perforce.Native builds copied by EpicGames.Perforce.csproj).
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

rem Pre-scan for --keep-metahuman. The TIER B block below is evaluated while the
rem exclude list is built, which happens before the main argument parser runs.
set "KEEP_METAHUMAN="
for %%A in (%*) do if /I "%%A"=="--keep-metahuman" set "KEEP_METAHUMAN=1"

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
rem NOTE: bare "IOS" is handled by the managed .gitdepsignore below; it would
rem also cut Engine/Source/Programs/AutomationTool/IOS, which UAT compiles.
set "EXCLUDES=%EXCLUDES% -exclude=Mac -exclude=TVOS -exclude=Linux -exclude=VisionOS -exclude=Win32"
rem ---- DotNet runtime packs for other RIDs ----
rem NOTE: bare "mac-x64" and "linux-x64" are handled by .gitdepsignore; each also
rem matches EpicGames.Perforce.Native/{mac-x64,linux-x64}, which
rem EpicGames.Perforce.csproj copies unconditionally when UAT compiles its script
rem modules. win-x64 is the host here and stays.
set "EXCLUDES=%EXCLUDES% -exclude=mac-arm64 -exclude=osx-x64 -exclude=osx-arm64 -exclude=linux-arm64 -exclude=win-arm64"
rem ---- Leftover platform segments (abseil/Boost/Steamworks etc.). NOTE: do NOT exclude
rem      "Apple" as a segment - Engine/{Binaries,Source}/ThirdParty/Apple also holds
rem      Windows consumers (MetalShaderConverter/metalirconverter.dll+.lib, ProResLib
rem      windows lib) that the Win64 editor build requires. Mac/iOS payloads are still
rem      cut by the Mac/IOS platform excludes above. ----
set "EXCLUDES=%EXCLUDES% -exclude=Unix -exclude=macos -exclude=osx -exclude=linux64"
rem ---- Platform payload outside the Win64 + Android arm64 scope ----
rem WinArm64 is a separate segment from Win64: the .NET win-arm64 pack is cut
rem above, but the platform payload needs its own pattern. The rest are macOS
rem (ArtToolsOSX, UbaAgentHelperMac), Linux (LinuxArm64/LinuxAArch64/linux32,
rem linuxarm - UE5 only, Oodle's Linux ARM dirs) and UWP. Do NOT exclude WinRT:
rem it also contains Win64 FreeType libraries (Lib/WinRT/Win64/freetype*.lib).
rem UbaAgentHelperMac, linuxarm and winuwp no longer exist on ue6-main; the
rem patterns stay because they still do work on 5.8.3, and tools/gitdeps_audit.py
rem reports a pattern that the current manifest does not know as STALE, not as an
rem error. UE6 spells its UWP vcpkg triplets overlay-*-uwp, so those are listed too.
set "EXCLUDES=%EXCLUDES% -exclude=WinArm64 -exclude=ArtToolsOSX -exclude=UbaAgentHelperMac -exclude=LinuxArm64 -exclude=LinuxAArch64 -exclude=linux32 -exclude=linuxarm -exclude=overlay-arm64-ios -exclude=overlay-arm64-uwp -exclude=overlay-x64-uwp -exclude=winuwp"
rem ---- PhysX3 leftovers (only consumer ApexDestruction plugin is disabled by default) ----
set "EXCLUDES=%EXCLUDES% -exclude=PhysX3"
rem ---- CEF non-win64 dirs (keep both win64 versions: editor WebBrowser/Insights need them) ----
rem UE6 (ue6-main) renamed the 147 drop from 147.1.5+g68529a5 to 147.0.14+g76d2442
rem and added a "+v2" rebuild of 128 x64. Both x64 drops are kept; the other
rem platforms are cut. Keeping the 5.8 147.1.5 spellings too makes one profile fit
rem both engines - a name the current manifest does not know is reported as STALE
rem by tools/gitdeps_audit.py, not treated as an error.
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_linux64"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_macos_universal"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_128.4.13+ge76af7e+chromium-128.0.6613.138_windowsarm64"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_linux64"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_147.0.14+g76d2442+chromium-147.0.7727.138_linux64"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_147.1.5+g68529a5+chromium-147.0.7727.49_windowsarm64"
set "EXCLUDES=%EXCLUDES% -exclude=cef_binary_147.0.14+g76d2442+chromium-147.0.7727.138_windowsarm64"
rem ---- Android ABIs: arm64-v8a (+ a deliberate x86 residue) ----
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
rem ---- TIER B: MetaHuman family + its Protobuf static libs ------------------
rem UE6 flips MetaHumanSDK to EnabledByDefault:true and MetaHumanSDKEditor links
rem the Protobuf libs, so cutting the payload without disabling the plugin is a
rem link failure. --keep-metahuman skips both cuts and leaves the plugin alone.
rem One guarded line per pattern: inside an "if ... (" block cmd expands
rem %EXCLUDES% once, at parse time, so a multi-line set block would keep only the
rem last assignment.
if not defined KEEP_METAHUMAN set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Plugins/MetaHuman"
if not defined KEEP_METAHUMAN set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Plugins/Experimental/MetaHuman"
if not defined KEEP_METAHUMAN set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Plugins/Experimental/Toolsets/MetaHumanGenerator"
if not defined KEEP_METAHUMAN set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Plugins/Experimental/Toolsets/AllMetaHumanToolsets"
if not defined KEEP_METAHUMAN set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Source/ThirdParty/Protobuf"
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
rem      p4api-2021.2. The prebuilt Binaries/DotNET/EpicGames.Perforce.Native
rem      builds are NOT excluded - UAT needs all three RIDs, and the managed
rem      .gitdepsignore below carries the mac-x64/linux-x64 exceptions. To
rem      restore P4 support: restore the .bak files and remove this line, then
rem      re-sync. ----
set "EXCLUDES=%EXCLUDES% -exclude=/Engine/Source/ThirdParty/Perforce -exclude=/Engine/Extras/P4VUtils"

rem ---- Arguments ----------------------------------------------------------
rem "dry" is recognized anywhere before the flags. `shift` does not change %*,
rem so the remainder has to be rebuilt token by token (a plain
rem `set "REST=%*"` after shift would leave "dry" in the list and reject it).
set "WAS_DRY="
set "REST="
:parse_args
if "%~1"=="" goto parse_args_done
if /I "%~1"=="dry" (
    set "WAS_DRY=1"
    shift
    goto parse_args
)
rem --keep-metahuman is this profile's own flag: consume it here. It must never
rem reach REST, because REST is forwarded to Setup.bat and on to GitDependencies,
rem which rejects an unknown parameter by printing help and exiting 0 - a run
rem that downloads nothing and looks successful.
if /I "%~1"=="--keep-metahuman" (
    set "KEEP_METAHUMAN=1"
    shift
    goto parse_args
)
set "REST=%REST% %~1"
shift
goto parse_args
:parse_args_done
if defined REST set "REST=%REST:~1%"
if defined WAS_DRY set "EXTRA=--dry-run"

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
        if /I not "%%A"=="--force" if /I not "%%A"=="--prompt" if /I not "%%A"=="--no-cache" goto :bad_arg
    )
)
if defined HAS_FORCE if defined HAS_PROMPT goto :bad_combo

rem ---- Managed GitDependencies ignore file -----------------------------------
rem GitDependencies reads .gitdepsignore from the engine root automatically and
rem applies "!" rules in order (last match wins). This is the only way to cut a
rem coarse platform segment while keeping a few files inside it: -exclude is
rem evaluated before the ignore file, so an exception cannot rescue a path that
rem -exclude already removed.
rem   **/IOS/**                 iOS payload (3.1 GiB)
rem   !**/AutomationTool/IOS/Resources/*.png UAT compiles IOS.Automation on every host
rem   **/mac-x64/**             other .NET runtime pack / Mac payload
rem   !**/EpicGames.Perforce.Native/mac-x64/Release/EpicGames.Perforce.Native.dylib
rem   **/linux-x64/**           other .NET runtime pack / Linux payload
rem   !**/EpicGames.Perforce.Native/linux-x64/Release/EpicGames.Perforce.Native.so
rem The three Perforce natives (win-x64, mac-x64, linux-x64) are copied by
rem Engine/Source/Programs/Shared/EpicGames.Perforce/EpicGames.Perforce.csproj
rem when UAT compiles its script modules, even on a Windows-only host.
set "IGNORE_RULES=**/IOS/**;!**/AutomationTool/IOS/Resources/*.png;**/mac-x64/**;!**/EpicGames.Perforce.Native/mac-x64/Release/EpicGames.Perforce.Native.dylib;**/linux-x64/**;!**/EpicGames.Perforce.Native/linux-x64/Release/EpicGames.Perforce.Native.so"

if exist ".gitdepsignore" (
    findstr /b /c:"# Generated by Setup_Minimal" ".gitdepsignore" >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] .gitdepsignore exists and was not generated by this profile.
        echo [ERROR] Move it aside or merge these rules into it, then re-run:
        echo          %IGNORE_RULES:;= %
        popd
        exit /b 2
    )
)
rem ---- MetaHumanSDK plugin state ---------------------------------------------
rem Runs after every argument and .gitdepsignore check has passed, so a run that
rem would be rejected never leaves the plugin flipped. The dependency payload and
rem the plugin have to agree: UE6 ships MetaHumanSDK with EnabledByDefault:true,
rem and MetaHumanSDKEditor links the Protobuf static libs that TIER B cuts.
rem A dry run is a preview: it must not edit engine files, so it skips this.
if defined WAS_DRY (
    echo [Setup_Minimal] dry run: MetaHumanSDK plugin edit skipped.
) else if defined KEEP_METAHUMAN (
    call :restore_metahuman
) else (
    call :disable_metahuman
    if errorlevel 1 goto :mh_failed
)

> ".gitdepsignore" echo # Generated by Setup_Minimal.bat - re-run that script to refresh.
rem Written one rule per line: a FOR over the concatenated list would treat the
rem "*.png" rule as a wildcard set and silently emit nothing when it matches no
rem file in the current directory.
>> ".gitdepsignore" echo **/IOS/**
>> ".gitdepsignore" echo !**/AutomationTool/IOS/Resources/*.png
>> ".gitdepsignore" echo **/mac-x64/**
>> ".gitdepsignore" echo !**/EpicGames.Perforce.Native/mac-x64/Release/EpicGames.Perforce.Native.dylib
>> ".gitdepsignore" echo **/linux-x64/**
>> ".gitdepsignore" echo !**/EpicGames.Perforce.Native/linux-x64/Release/EpicGames.Perforce.Native.so
echo [Setup_Minimal] Managed .gitdepsignore written.

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
echo [ERROR] This profile accepts only "dry", "--force", "--prompt", "--keep-metahuman" and "--no-cache".
popd
exit /b 2

:bad_combo
echo [ERROR] --force and --prompt are mutually exclusive; GitDependencies rejects both together.
popd
exit /b 2

:mh_failed
echo [ERROR] MetaHumanSDK is still enabled while its payload and Protobuf are excluded.
echo [ERROR] That combination fails the UnrealEditor link step, so nothing was synced.
echo [ERROR] Either fix the .uplugin or re-run with --keep-metahuman.
popd
exit /b 3

:disable_metahuman
rem Idempotent: only touches the file while EnabledByDefault is still true, and
rem keeps the pre-edit copy next to it. All PowerShell quoting is single-quoted
rem so cmd can pass the command through unchanged. $ErrorActionPreference=Stop is
rem what turns a locked/read-only .uplugin into exit code 1 instead of a
rem non-terminating error that would let the sync run with a cut payload; the
rem read-back is the belt-and-braces check that the flip actually landed.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $p='Engine\Plugins\MetaHuman\MetaHumanSDK\MetaHumanSDK.uplugin'; if(-not (Test-Path -LiteralPath $p)){ Write-Host '[Setup_Minimal] MetaHumanSDK plugin not in this engine; nothing to disable.'; exit 0 }; $t=Get-Content -Raw -LiteralPath $p; if($t -notmatch 'EnabledByDefault\x22?\s*:\s*true'){ Write-Host '[Setup_Minimal] MetaHumanSDK already disabled by default.'; exit 0 }; if(-not (Test-Path -LiteralPath ($p+'.bak'))){ Copy-Item -LiteralPath $p -Destination ($p+'.bak') }; $out=$t -replace 'EnabledByDefault(\x22?\s*:\s*)true','EnabledByDefault${1}false'; Set-Content -LiteralPath $p -Value $out -NoNewline; $check=Get-Content -Raw -LiteralPath $p; if($check -notmatch 'EnabledByDefault\x22?\s*:\s*false'){ Write-Host '[ERROR] MetaHumanSDK.uplugin did not change'; exit 1 }; Write-Host '[Setup_Minimal] MetaHumanSDK disabled by default (backup: MetaHumanSDK.uplugin.bak).'; exit 0"
rem exit 3 hands control to :mh_failed, which prints the explanation and stops
rem the whole run before Setup.bat downloads anything.
if errorlevel 1 exit /b 3
exit /b 0

:restore_metahuman
rem --keep-metahuman: put the pre-cut descriptor back so the kept payload is
rem actually reachable. Only reverts an edit this profile made (it only ever
rem creates the .bak when it also flips the flag).
if not exist "Engine\Plugins\MetaHuman\MetaHumanSDK\MetaHumanSDK.uplugin.bak" (
    echo [Setup_Minimal] --keep-metahuman: no .bak to restore, plugin left as-is.
    exit /b 0
)
copy /y "Engine\Plugins\MetaHuman\MetaHumanSDK\MetaHumanSDK.uplugin.bak" "Engine\Plugins\MetaHuman\MetaHumanSDK\MetaHumanSDK.uplugin" >nul
echo [Setup_Minimal] --keep-metahuman: MetaHumanSDK.uplugin restored from .bak.
exit /b 0

:write_hook
rem Helpers for the Setup.bat layout shared by 5.7.4, 5.8.3 and ue6-main: a
rem /bin/sh hook with the GitDependencies executable called relative to the
rem engine root.
> "%HOOKS_DIR%\%~1" echo #!/bin/sh
>> "%HOOKS_DIR%\%~1" echo # Generated by Setup_Minimal.bat - re-run that script to refresh.
>> "%HOOKS_DIR%\%~1" echo # Keeps git pull / checkout dependency syncs on the minimal platform set.
>> "%HOOKS_DIR%\%~1" echo Engine/Binaries/DotNET/GitDependencies/win-x64/GitDependencies.exe %EXCLUDES%
exit /b
