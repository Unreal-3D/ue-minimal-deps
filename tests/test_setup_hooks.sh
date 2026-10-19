#!/bin/bash
# Regression tests for the setup profiles' post-sync git hooks and argument
# handling.
#
# No Unreal Engine checkout is required. Each case builds a temporary engine
# root whose Setup.sh stand-in records the arguments it receives and installs
# hooks the way the real Setup.sh does. The profile must then replace those
# hooks with an exclude-only version; per-run flags must never survive into a
# future "git pull".
#
# Usage: bash tests/test_setup_hooks.sh

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/ue-minimal-tests.XXXXXX")
trap 'rm -rf "$TMP_BASE"' EXIT

FAILURES=0
CHECKS=0
CASE_NUMBER=0
ENGINE=""
STATUS=0

pass() { CHECKS=$((CHECKS + 1)); }
fail() {
	CHECKS=$((CHECKS + 1))
	FAILURES=$((FAILURES + 1))
	echo "FAIL: $*" >&2
}

contains() {
	local file=$1 needle=$2 label=$3
	if grep -Fq -- "$needle" "$file" 2>/dev/null; then
		pass
	else
		fail "$label: expected '$needle' in $file"
	fi
}

not_contains() {
	local file=$1 needle=$2 label=$3
	if grep -Fq -- "$needle" "$file" 2>/dev/null; then
		fail "$label: '$needle' unexpectedly in $file"
	else
		pass
	fi
}

status_is() {
	local expected=$1 actual=$2 label=$3
	if [ "$expected" -eq "$actual" ]; then
		pass
	else
		fail "$label: expected exit $expected, got $actual"
	fi
}

file_absent() {
	local file=$1 label=$2
	if [ -e "$file" ]; then
		fail "$label: $file should not exist"
	else
		pass
	fi
}

new_engine() {
	CASE_NUMBER=$((CASE_NUMBER + 1))
	ENGINE="$TMP_BASE/case$CASE_NUMBER"
	mkdir -p "$ENGINE/Engine/Build" "$ENGINE/.git/hooks" \
		"$ENGINE/Engine/Build/BatchFiles/Mac" \
		"$ENGINE/Engine/Build/BatchFiles/Linux" \
		"$ENGINE/Engine/Build/BatchFiles/Windows"
	git init -q "$ENGINE" >/dev/null 2>&1 || true
	cat > "$ENGINE/Engine/Build/Commit.gitdeps.xml" <<'XML'
<?xml version="1.0"?>
<Files>
<File Name="Engine/Binaries/ThirdParty/DotNet/8.0.300/mac-x64/dotnet" />
<File Name="Engine/Binaries/ThirdParty/DotNet/8.0.300/mac-arm64/dotnet" />
<File Name="Engine/Binaries/ThirdParty/DotNet/8.0.300/linux-x64/dotnet" />
<File Name="Engine/Binaries/ThirdParty/DotNet/8.0.300/linux-arm64/dotnet" />
<File Name="Engine/Binaries/Mac/UnrealEditor" />
</Files>
XML
	cp "$REPO_ROOT/scripts/Setup_Minimal.sh" "$ENGINE/"
	cp "$REPO_ROOT/scripts/Setup_Minimal_linux.sh" "$ENGINE/"
}

setup_sh_mac() {
	cat > "$ENGINE/Setup.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$PWD/setup_args.txt"
rm -f .git/hooks/post-checkout .git/hooks/post-merge
ln -s ../../Engine/Build/BatchFiles/Mac/GitDependenciesHook.sh .git/hooks/post-checkout
ln -s ../../Engine/Build/BatchFiles/Mac/GitDependenciesHook.sh .git/hooks/post-merge
exit 0
EOF
	chmod +x "$ENGINE/Setup.sh"
}

setup_sh_linux() {
	cat > "$ENGINE/Setup.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$PWD/setup_args.txt"
for hook in post-checkout post-merge; do
	{
		echo '#!/bin/bash'
		echo "Engine/Build/BatchFiles/Linux/GitDependencies.sh $*"
	} > ".git/hooks/$hook"
	chmod +x ".git/hooks/$hook"
done
exit 0
EOF
	chmod +x "$ENGINE/Setup.sh"
}

setup_sh_invalid() {
	cat > "$ENGINE/Setup.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$PWD/setup_args.txt"
echo "Invalid command line parameter: --all"
echo "Usage: GitDependencies ..."
exit 0
EOF
	chmod +x "$ENGINE/Setup.sh"
}

run_profile() {
	local script=$1
	shift
	( cd "$ENGINE" && bash "$script" "$@" ) > "$TMP_BASE/output.txt" 2>&1
	STATUS=$?
}

is_arm64() {
	[ "$(uname -m)" = "arm64" ] || [ "$(uname -m)" = "aarch64" ]
}

# ---------------------------------------------------------------------------
# macOS profile
# ---------------------------------------------------------------------------

new_engine
setup_sh_mac
run_profile Setup_Minimal.sh dry
status_is 0 "$STATUS" "macOS dry exits 0"
contains "$ENGINE/setup_args.txt" "--dry-run" "macOS dry forwards --dry-run to Setup.sh"
contains "$ENGINE/.git/hooks/post-checkout" "-exclude=TVOS" "macOS hook carries the excludes"
contains "$ENGINE/.git/hooks/post-checkout" "Engine/Build/BatchFiles/Mac/GitDependencies.sh" "macOS hook calls GitDependencies.sh"
not_contains "$ENGINE/.git/hooks/post-checkout" "--dry-run" "macOS hook has no --dry-run"
not_contains "$ENGINE/.git/hooks/post-checkout" "--force" "macOS hook has no --force"
not_contains "$ENGINE/.git/hooks/post-checkout" "--prompt" "macOS hook has no --prompt"
if is_arm64; then
	contains "$ENGINE/.git/hooks/post-checkout" "ThirdParty/DotNet/8.0.300/mac-x64" "macOS ARM branch root-anchors the x64 pack"
else
	contains "$ENGINE/.git/hooks/post-checkout" "-exclude=mac-arm64" "macOS x64 branch drops the arm64 pack"
fi

new_engine
setup_sh_mac
run_profile Setup_Minimal.sh --force
status_is 0 "$STATUS" "macOS --force exits 0"
contains "$ENGINE/setup_args.txt" "--force" "macOS forwards --force to Setup.sh"
not_contains "$ENGINE/.git/hooks/post-checkout" "--force" "macOS hook has no --force after a --force run"

new_engine
setup_sh_mac
run_profile Setup_Minimal.sh --prompt
status_is 0 "$STATUS" "macOS --prompt exits 0"
contains "$ENGINE/setup_args.txt" "--prompt" "macOS forwards --prompt to Setup.sh"
not_contains "$ENGINE/.git/hooks/post-checkout" "--prompt" "macOS hook has no --prompt after a --prompt run"

new_engine
setup_sh_mac
run_profile Setup_Minimal.sh dry --force
status_is 0 "$STATUS" "macOS dry --force exits 0"
contains "$ENGINE/setup_args.txt" "--dry-run" "macOS dry --force keeps --dry-run"
contains "$ENGINE/setup_args.txt" "--force" "macOS dry --force keeps --force"

new_engine
setup_sh_invalid
run_profile Setup_Minimal.sh --all
status_is 2 "$STATUS" "macOS rejects a GitDependencies-invalid argument"
contains "$TMP_BASE/output.txt" "rejected an argument" "macOS reports the rejected argument"
not_contains "$TMP_BASE/output.txt" "[OK] Dependency sync finished." "macOS does not claim success after a rejected argument"

new_engine
setup_sh_mac
run_profile Setup_Minimal.sh --force --prompt
status_is 2 "$STATUS" "macOS rejects --force with --prompt"
contains "$TMP_BASE/output.txt" "mutually exclusive" "macOS explains the --force/--prompt conflict"
file_absent "$ENGINE/setup_args.txt" "macOS does not call Setup.sh with --force and --prompt"

# ---------------------------------------------------------------------------
# Linux profile
# ---------------------------------------------------------------------------

new_engine
setup_sh_linux
run_profile Setup_Minimal_linux.sh dry
status_is 0 "$STATUS" "Linux dry exits 0"
contains "$ENGINE/setup_args.txt" "--dry-run" "Linux dry forwards --dry-run to Setup.sh"
contains "$ENGINE/.git/hooks/post-checkout" "Engine/Build/BatchFiles/Linux/GitDependencies.sh" "Linux hook calls GitDependencies.sh"
contains "$ENGINE/.git/hooks/post-checkout" "-exclude=Mac" "Linux hook carries the excludes"
not_contains "$ENGINE/.git/hooks/post-checkout" "--dry-run" "Linux hook has no --dry-run"
not_contains "$ENGINE/.git/hooks/post-checkout" "--force" "Linux hook has no --force"
not_contains "$ENGINE/.git/hooks/post-checkout" "--prompt" "Linux hook has no --prompt"
if is_arm64; then
	contains "$ENGINE/.git/hooks/post-checkout" "-exclude=linux-x64" "Linux ARM branch root-anchors the x64 pack"
else
	contains "$ENGINE/.git/hooks/post-checkout" "-exclude=linux-arm64" "Linux x64 branch drops the arm64 pack"
fi

new_engine
setup_sh_linux
run_profile Setup_Minimal_linux.sh --force
status_is 0 "$STATUS" "Linux --force exits 0"
contains "$ENGINE/setup_args.txt" "--force" "Linux forwards --force to Setup.sh"
not_contains "$ENGINE/.git/hooks/post-checkout" "--force" "Linux hook has no --force after a --force run"

new_engine
setup_sh_invalid
run_profile Setup_Minimal_linux.sh --all
status_is 2 "$STATUS" "Linux rejects a GitDependencies-invalid argument"
contains "$TMP_BASE/output.txt" "rejected an argument" "Linux reports the rejected argument"
not_contains "$TMP_BASE/output.txt" "[OK] Dependency sync finished." "Linux does not claim success after a rejected argument"

new_engine
setup_sh_linux
run_profile Setup_Minimal_linux.sh --force --prompt
status_is 2 "$STATUS" "Linux rejects --force with --prompt"
contains "$TMP_BASE/output.txt" "mutually exclusive" "Linux explains the --force/--prompt conflict"
file_absent "$ENGINE/setup_args.txt" "Linux does not call Setup.sh with --force and --prompt"

# ---------------------------------------------------------------------------
# Windows batch profile - static checks only (cmd.exe is not available here)
# ---------------------------------------------------------------------------

BAT="$REPO_ROOT/scripts/Setup_Minimal.bat"
contains "$BAT" 'call .\Setup.bat' "bat uses CALL for Setup.bat"
contains "$BAT" 'Engine\Build\Commit.gitdeps.xml' "bat checks the manifest"
contains "$BAT" ':write_hook' "bat has a hook writer"
contains "$BAT" 'echo #!/bin/sh' "bat hook is a sh script"
contains "$BAT" 'Engine/Binaries/DotNET/GitDependencies/win-x64/GitDependencies.exe' "bat hook calls the GitDependencies executable"
if grep -Eq '^[[:space:]]*\.\\Setup\.bat' "$BAT"; then
	fail "bat invokes Setup.bat without CALL"
else
	pass
fi
HOOK_LINES="$TMP_BASE/bat_hook_lines.txt"
grep -F 'GitDependencies.exe' "$BAT" > "$HOOK_LINES" || true
if grep -Eq '%(EXTRA|REST)%' "$HOOK_LINES"; then
	fail "bat writes a per-run flag into the hook"
else
	pass
fi
contains "$BAT" 'GitDependencies.exe %EXCLUDES%' "bat hook contains only the exclude list"

# Platform scope: the Windows profile must cut payload outside Win64 + Android.
for pat in WinArm64 ArtToolsOSX UbaAgentHelperMac LinuxArm64 LinuxAArch64 linux32 linuxarm overlay-arm64-ios winuwp; do
	contains "$BAT" "-exclude=$pat" "bat excludes $pat"
done
# WinRT also holds Win64 FreeType libs, and bare x86 holds WiX/Win32 payload.
not_contains "$BAT" '-exclude=WinRT' "bat does not exclude WinRT"
if grep -Eq -- '-exclude=x86([[:space:]]|$)' "$BAT"; then
	fail "bat must not exclude bare x86"
else
	pass
fi

# ---------------------------------------------------------------------------

echo
echo "$((CHECKS - FAILURES))/$CHECKS checks passed"
if [ "$FAILURES" -ne 0 ]; then
	echo "$FAILURES check(s) failed" >&2
	exit 1
fi
echo "all setup hook tests passed"
