# How `-exclude` actually works

Everything here is read off the UE 5.7.4 source in
`Engine/Source/Programs/GitDependencies/Program.cs` and confirmed by running the
real `GitDependencies` binary. Line numbers are 5.7.4 and will drift between
versions, but the semantics have been stable for years.

## The call chain

```
Setup.sh / Setup.bat                     <- writes git hooks, then:
  Engine/Build/BatchFiles/<host>/GitDependencies.sh
    Engine/Binaries/DotNET/GitDependencies/<host-rid>/GitDependencies   <- does the work
```

`GitDependencies` is a plain command-line tool. You can call it directly, which
is useful for testing:

```
Engine/Binaries/DotNET/GitDependencies/osx-x64/GitDependencies \
    -root=/path/to/engine -dry-run -no-cache -exclude=TVOS
```

`Setup.sh` adds `--prompt` when neither `--prompt` nor `--force` is present
(`Setup.sh:43-50`). Everything else is forwarded verbatim.

## Argument parsing

Two details matter before the matcher even runs.

**Double dashes are normalized away.** `NormalizeArguments` (`Program.cs:245`)
strips one leading `-` from any argument that starts with `--`. So `--force` and
`-force` both become `-force` *by the time they are parsed*. The help text
advertises the double-dash spellings; both work.

**Excludes are collected into a case-insensitive set** (`Program.cs:187-192`):

```csharp
HashSet<string> ExcludeFolders = new HashSet<string>(StringComparer.CurrentCultureIgnoreCase);
foreach(string ExcludeFolder in ParseParameters(ArgsList, "-exclude="))
{
    ExcludeFolders.Add(ExcludeFolder.Replace('\\', '/').TrimEnd('/'));
}
```

Consequences: backslashes are normalized to forward slashes, a trailing slash is
trimmed (`-exclude=TVOS/` is identical to `-exclude=TVOS`), and duplicates
collapse. An empty `-exclude=` is accepted and matches nothing.

## The matcher

This is the whole mechanism, `Program.cs:972`:

```csharp
static bool IsExcludedFolder(string Name, IEnumerable<string> ExcludeFolders)
{
    string RootedName = "/" + Name;
    foreach(string ExcludeFolder in ExcludeFolders)
    {
        if(ExcludeFolder.StartsWith("/"))
        {
            // Do a prefix check
            if(RootedName.StartsWith(ExcludeFolder + "/", StringComparison.CurrentCultureIgnoreCase))
            {
                return true;
            }
        }
        else
        {
            // Do a substring check
            if(RootedName.IndexOf("/" + ExcludeFolder + "/", StringComparison.CurrentCultureIgnoreCase) != -1)
            {
                return true;
            }
        }
    }
    return false;
}
```

Read it carefully, because the "substring check" comment is misleading. The
pattern is wrapped in slashes before searching, so it can only ever match a
**whole path segment**:

| Pattern | Matches | Does *not* match |
|---|---|---|
| `Mac` | `Engine/Binaries/Mac/UnrealEditor` | `.../DotNet/8.0.412/mac-arm64/dotnet` |
| `mac-arm64` | `.../DotNet/8.0.412/mac-arm64/dotnet` | `Engine/Binaries/Mac/UnrealEditor` |
| `Unix` | `.../SymsLib/lib/Unix/x86_64-unknown-linux-gnu/libsyms.a` | `.../SymsLib/lib/Mac/libsyms.a` |
| `x86` | `.../ICU/icu4c-53_1/Android/x86/libicuuc.a` | `.../Android/x86_64/libicuuc.a` |
| `IOS` | `Engine/Build/IOS/AppleRootCA.pem` | `.../OnlineSubsystemIOS/...` (different segment) |
| `/Engine/Content/Localization` | `Engine/Content/Localization/Engine/zh-Hans/x.locres` | `Engine/Content/LocalizationExtra/x` |

Two things follow, and both are load-bearing:

1. **You can target one architecture without touching its sibling.** `Mac` and
   `mac-arm64` are different segments, so `-exclude=mac-arm64` on an Intel host
   removes the Apple Silicon .NET pack and leaves the Mac editor binaries alone.
   This is the trick the whole approach rests on.

2. **A segment name is not a category.** `-exclude=Unix` does not mean "all
   Unix-like platforms" — it means the literal directory named `Unix`, which in
   UE holds *only* `x86_64-unknown-linux-gnu` and `aarch64-unknown-linux-gnueabi`
   payloads. That makes it correct to exclude on Windows and macOS and **wrong**
   on Linux, where `Unix` is where the host's own OpenSSL and SymsLib live.

The leading-slash form is a root-anchored prefix. It is the right tool when a
directory name is too generic to use as a segment — `-exclude=/Engine/Plugins/MetaHuman`
removes the plugin family without any risk of matching an unrelated `MetaHuman`
directory elsewhere.

## `.gitdepsignore`: cuts with exceptions

`-exclude` has no include counterpart: once a path matches, it is gone. That is a
problem for segments that also hold build-tool inputs. `IOS` is the clearest
example — it covers 3.1 GiB of iOS payload, but also
`Engine/Source/Programs/AutomationTool/IOS/Resources/*.png`, which UAT needs to
compile `IOS.Automation` on every host, including Windows and Linux.

GitDependencies reads `<engine>/.gitdepsignore` automatically (`Program.cs:388`).
Its parser is small and is reproduced in `tools/gitdeps_audit.py`:

- `?` matches one character, `*` one path component, `**` any number of them.
- A leading `!` flips the rule into an include.
- Rules are applied in file order; the **last match wins**.
- The ignore file is consulted *after* `-exclude`, so it can only subtract more;
  it cannot bring back a path `-exclude` already removed.

The profiles therefore move the coarse segment cut into `.gitdepsignore` and
follow it with an exception:

```
**/IOS/**
!**/AutomationTool/IOS/Resources/*.png
```

This is why the scripts no longer carry `-exclude=IOS`, `-exclude=mac-x64`,
`-exclude=linux-x64` or, on macOS/Linux, `-exclude=win-x64`: each of those
segments also matches a file UAT copies. The ignore file is written on every run
(dry-runs included), refuses to overwrite a file it did not generate, and is
read by plain `Setup.sh` / `Setup.bat` as well.

## Excluded means "not downloaded and not deleted"

The matcher and the `.gitdepsignore` rules are applied together in exactly two
places:

- `Program.cs:507` — when building the list of files to download
- `Program.cs:565` — when building the list of files to remove

So an excluded file is neither fetched nor deleted. On a fresh clone that is
exactly what you want. On an existing full tree it means the files you already
have simply stay there. The stock script passes no excludes, but the managed
`.gitdepsignore` is still read, so a plain `Setup.sh` / `Setup.bat` keeps the
platform payload out; delete that file (and sync without a profile) to fill the
tree back in.

## Exit codes are not trustworthy

`GitDependencies` returns **0** even when it rejects your arguments. An
unrecognized parameter lands in this loop (`Program.cs:195`):

```csharp
foreach(string RemainingArg in ArgsList)
{
    Log.WriteLine("Invalid command line parameter: {0}", RemainingArg);
    Log.WriteLine();
    bHelp = true;
}
```

which sets `bHelp`, prints the usage text, and returns 0. A typo'd exclude
argument therefore looks like a clean, successful run that did nothing. Always
check the first line of the output for `Checking dependencies (excluding ...)`
rather than trusting the exit status.

### Flags the help text advertises but does not implement

Verified against the 5.7.4 binary:

```
$ GitDependencies -root=... -dry-run -no-cache --all -exclude=TVOS
Invalid command line parameter: -all

$ GitDependencies -root=... -dry-run -no-cache --include=Engine -exclude=TVOS
Invalid command line parameter: -include=Engine
```

The usage text lists `--all` and `--include=<X>` (`Program.cs:209-210`), but
neither is parsed anywhere in the file. Passing either one triggers the
invalid-parameter path above, which means **zero files sync and the exit code is
0**. There is no include list; you compose one by excluding everything else.

## Trap 1: a bare `-force` silently disables the sync

`Setup.sh` decides whether to add `--prompt` by scanning your arguments for the
double-dash spellings (`Setup.sh:25-50`):

```sh
PromptOrForce=$(FindPromptOrForceArg "$@")
if [ -z "${PromptOrForce}" ]; then
    GitDepsArgs=(--prompt)
fi
GitDepsArgs+=("$@")
```

`FindPromptOrForceArg` only recognises `--prompt` and `--force`. Pass a bare
`-force` and it adds `--prompt` as well. `GitDependencies` then parses in this
order (`Program.cs:150`):

```csharp
if(ParseSwitch(ArgsList, "-prompt")) { Overwrite = OverwriteMode.Prompt; }
else if(ParseSwitch(ArgsList, "-force")) { Overwrite = OverwriteMode.Force; }
```

`--prompt` is consumed by the first branch, so `-force` is never consumed, falls
through to the invalid-parameter loop, and you get the help text and exit 0.

Measured, against the real binary:

```
-dry-run --prompt -force   exit=0  adds=0       first="Invalid command line parameter: -force"
-dry-run --force           exit=0  adds=86734   first="Checking dependencies (excluding ...)"
-dry-run --prompt          exit=0  adds=86734   first="Checking dependencies (excluding ...)"
```

Note `ParseSwitch` is an **exact** match (`Program.cs:288`, `String.Compare(...) == 0`),
unlike `ParseParameter` which is a prefix match. That asymmetry is why
`--force` is normalized to `-force` and works, while the literal `-force` passed
*alongside* `--prompt` does not.

Both shell scripts in `scripts/` rewrite a bare `-force`/`-prompt` wherever it
appears in the argument list; `Setup_Minimal.bat` normalizes the single-token
case, so pass the double-dash spellings if you combine it with other arguments.
All three profiles also reject `--force` together with `--prompt`, which trips
the same unconsumed-argument path.

## Trap 2: macOS git hooks discard the exclude list

`Setup.sh` branches on the host (`Setup.sh:52-90`).

On **Linux** it writes the arguments it was given straight into the hook files
(`Setup.sh:69`):

```sh
echo Engine/Build/BatchFiles/Linux/GitDependencies.sh "$@" >> "$GIT_DIR/hooks/post-checkout"
```

So the excludes survive. On **macOS** it instead symlinks the hooks to a wrapper
(`Setup.sh:58`):

```sh
ln -s ../../Engine/Build/BatchFiles/Mac/GitDependenciesHook.sh "$GIT_DIR/hooks/post-checkout"
```

and `GitDependenciesHook.sh` ends with:

```sh
./GitDependencies.sh
```

— no arguments. The next `git pull` re-downloads every platform. `Setup.bat` on
Windows has the same shape as the Linux path: it writes its arguments into the
hooks.

`scripts/Setup_Minimal.sh` therefore replaces both macOS hooks with real scripts
that carry the exclude list. The Linux and Windows profiles also rewrite the
hooks that `Setup.sh`/`Setup.bat` just wrote, because those contain the raw
argument list: a `dry` run would otherwise leave `--dry-run` behind, and a
`--force` run would make every future `git pull` overwrite local changes. All
three profiles write only the exclude list into the hooks.

## Verifying any of this yourself

`tools/gitdeps_audit.py` is a faithful port of `IsExcludedFolder`, and its
`--selftest` pins 29 cases against the behaviour above — including the
`Mac`/`mac-arm64` and `Unix`/`Mac` distinctions, the prefix form, and
case-insensitivity. It also implements the `.gitdepsignore` parser and applies
the ignore rules after `-exclude`, so a reported cut names the layer that
actually removed the path. If a future engine version changes either matcher,
the selftest and the audit both go red.

The audit adds three checks on top of the matcher:

- **UNEXPECTED CUTS** — a file belonging to a supported platform was cut and no
  declared reason covers it. This is the one that matters, and it is what caught
  `-exclude=mac-x64` taking `EpicGames.Perforce.Native` with it, and the same
  thing happening again with `-exclude=linux-x64`.
- **STALE PATTERNS** — an exclude argument that matches nothing in the manifest.
  Harmless on its own, but it is exactly what a renamed directory looks like from
  the outside, and it is how the hard-coded .NET version pin was caught going
  stale between 5.7.4 and 5.8.3.
- **SHADOWED** — a pattern that only matches paths an earlier pattern already
  cuts, so it never gets to be the one reported. Redundancy rather than drift:
  `aarch64-unknown-linux-gnueabi` is shadowed by `Unix` on macOS, and
  `VS2008`/`VS2012`/`VS2013` by the `Win64`/`Win32` patterns. Nothing to do.
- **MISSES** — payload for a platform the profile claims to drop is still being
  downloaded, so the savings are leaking out.

Given how silent `GitDependencies` is about all three, running this after an
engine update is the whole point of the repo.
