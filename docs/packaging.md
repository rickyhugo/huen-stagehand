# Zig packaging

## Build and checks

`mise.toml` pins Zig 0.17.1, Python 3.14.7 (test harnesses only), hk 2.12.0, jj 0.38.0,
tmux 3.8, and gh 2.103.3. `mise.lock` records upstream download checksums.
Use mise 2026.10.17 or newer.

```sh
mise install --locked
mise run ci
```

CI and local hooks use the same hk checks: formatting, Zig tests, harness
isolation, packaging policy, command adapters, CLI/repository regressions,
21 terminal/popup scenarios, and 16 focused picker regressions.
Command and terminal checks use the release executable. Migration comparison
tools and fixtures were retired after verification and four-platform Nix success.

hk 2.12.0 has no upstream Intel macOS binary. Full developer checks therefore
run on Apple Silicon and Linux x86-64. Source installs and archive builds
on Intel Macs do not require hk.

## Release archives

Releases are not versioned. An archive is named after its target only.

| Archive target | Zig target | Native CI runner |
| --- | --- | --- |
| `aarch64-apple-darwin` | `aarch64-macos` | `macos-15` |
| `x86_64-apple-darwin` | `x86_64-macos` | `macos-15-intel` |
| `x86_64-unknown-linux-gnu` | `x86_64-linux-gnu.2.28` | `ubuntu-22.04` |
| `x86_64-unknown-linux-musl` | `x86_64-linux-musl` | `ubuntu-24.04` |

There is no Linux ARM64 release archive; build from source on that system.
GNU builds select the glibc 2.28 ABI baseline. This does not prove execution
on a glibc 2.28 host.

```sh
mise run package -- --target aarch64-apple-darwin --smoke
mise run package:verify -- \
  target/distrib/stagehand-aarch64-apple-darwin.tar.gz \
  --target aarch64-apple-darwin --smoke
```

Builds use ReleaseFast, baseline CPU features, vendored dependencies, and
`--system` to disable Zig package downloads. An archive contains `stagehand`,
application and vendored licenses, source notices, and Zig/libc notices.
It contains no runtime helpers.
The companion `.sha256` file identifies the archive.

Verification checks checksums, the exact member set, permissions, executable
format and CPU, and notice bytes. `--smoke` also runs `--help` on a matching
native host. This smoke check does not replace behavioral tests.

`scripts/package.zig` declares the required source notices explicitly in
`required_source_notices`. Missing files and symlinks fail packaging. Additional
conventionally named notices are discovered too. This manifest includes
`src/config/UNICODE-LICENSE`; filename-prefix discovery alone cannot find it.
Archives and source installation use the same notice installer/list.

The packaging policy tests in `scripts/package.zig` run with `zig build test`:

```sh
MISE_AUTO_INSTALL=false mise run test
```

Their expected notice paths and bytes come from a separate list in the tests,
not from `notices()`. They build a fixture tree, then check archive contents and
notice installation under a spaced prefix, including the config Unicode notice.
They also reject an archive with that notice removed after recomputing the
checksum. Other negative cases cover altered or empty notice bytes, member
sets/types/modes, checksums, CPU, archive names, symlinked notices, and foreign
smoke requests. These tests do not compile the application. Use the native
`package --smoke` task above for a real release build and execution check.

## Source installation

```sh
mise install --locked zig
MISE_AUTO_INSTALL=false mise run install -- "$HOME/.local"
```

The installer writes `bin/stagehand` and `share/licenses/stagehand` under the prefix.
tmux and Git are runtime dependencies; jj is optional. No fzf, `ls`, or `mv`
runtime helper is required.

## Workflows

- `ci.yml`: full pinned tools and shared hk checks on Linux and Apple Silicon.
- `release.yml`: shared CI checks must pass before archive jobs run.

Archive jobs install only Zig; publication installs only gh.
These jobs set `MISE_AUTO_INSTALL=false`
so nested tasks cannot install unrelated tools.

Pull requests and manual dispatches upload artifacts only. Any pushed tag
in `rickyhugo/huen-stagehand` creates a draft release after all gates pass.
Publishing the draft remains a separate action. Cargo publishing and
Cargo-dist configuration have been removed.

## Verification on 2026-11-13

The integrated application at `3ad4fda` passed archive creation and inspection
for all four targets. Apple Silicon also passed native extraction and version
execution. The source installer passed with a prefix containing spaces and
byte-for-byte notice comparison against the then-discovered notice list.
Review later found that list omitted `src/config/UNICODE-LICENSE`. The explicit
manifest and independent packaging regression above correct that omission;
the earlier verification did not prove complete notice coverage.

The review-fix rerun rebuilt all four archives and independently compared all
14 notice files with their source bytes. Apple Silicon passed native archive
execution and a real source installation with a spaced prefix. All ten
packaging policy tests passed, including the missing-Unicode-notice regression.

After integrating the repository templates, `6a16a34` rebuilt all four
archives and passed native Apple Silicon smoke. An independent policy check
compared all 15 notice files byte-for-byte in every archive, including
`src/repos/template/LICENSE`. Source installation with a spaced prefix also
passed exact executable and notice comparisons. Evidence:
`.audit/review-final-archives.log` and `.audit/review-final-install.log`.
This rerun did not execute the other native targets or rebuild Nix packages.

The packaging implementation's earlier negative checks rejected altered
checksums, extra or missing members, duplicates, wrong permissions, symlinks,
changed notices, wrong CPU/file types, foreign smoke checks, and duplicate
version declarations.

Native aarch64 Linux passed full application verification, including xattrs
and ACLs. See [Linux verification](linux-verification.md).

Hosted workflows and native Intel macOS/x86-64 Linux archive execution remain
unexecuted locally. Cross-build success is not native runtime evidence.
These verification commands do not tag or publish a release.
