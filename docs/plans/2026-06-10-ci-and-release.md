# CI Checks and Release Workflow Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub Actions CI (formatting check + tests) and a tag-driven release workflow that publishes cross-platform `wtr` binaries installable via mise.

**Tech Stack:** GitHub Actions, mise (`jdx/mise-action@v3`), lgx (`lgx build`, `lgx test`), cljfmt, let-go (`lg`) prebuilt release binaries as bundle bases.

---

## Design

### Overview

Two workflows modeled on neighboring projects:

- `checks.yml` mirrors `tiny-cli`'s checks workflow: install tools from `.mise.toml` via `jdx/mise-action`, then run `lgx fmt-check` and `lgx test`. It declares `workflow_call:` so the release workflow reuses it as a gate.
- `release.yml` triggers on `v*` tag pushes. Job 1 calls `checks.yml`. Job 2 builds binaries for four platforms and publishes a GitHub release.

### Cross-platform builds with `lgx build`

let-go bundling is not real cross-compilation: `lg -b` appends bytecode to a prebuilt base `lg` binary, so building for another OS/arch only requires that platform's `lg` binary as the bundle base. `lgx build` supports this directly — per the lgx README, `lgx build` expands to `lg <paths> [extra-args...] -b <:out> <:main>` and extra args go before `-b`, so:

```sh
lgx build -bundle-base bases/<target>/lg
```

builds `bin/wtr` (the `:out` from `lgx.edn`) for the target platform. The host `lg` and `lgx` come from mise; the `LGX_LG` env var is not needed in CI.

Because `:out` is fixed at `bin/wtr`, the build loop moves the binary to `build/<target>/wtr` after each iteration.

### Release build job flow

1. Checkout + `jdx/mise-action@v3` (installs `lg`, `lgx`, `cljfmt` from `.mise.toml`).
2. Read `LG_VERSION` from `.mise.toml` with the awk snippet proven in lgx's `setup-lg` composite action.
3. For each target in `linux_amd64 linux_arm64 darwin_amd64 darwin_arm64`:
   - Download `let-go_${LG_VERSION}_${target}.tar.gz` and `checksums.txt` from `https://github.com/nooga/let-go/releases/download/v${LG_VERSION}/`.
   - Verify the tarball with `sha256sum -c` against the matching line of `checksums.txt`.
   - Extract to `bases/<target>/`, run `lgx build -bundle-base bases/<target>/lg`, move `bin/wtr` to `build/<target>/wtr`.
   - Archive as `dist/wtr_${version}_${target}.tar.gz` (where `version` is the tag without the `v` prefix).
4. Smoke test: run `./build/linux_amd64/wtr list` (the runner is linux/amd64; the repo checkout is a git repo, so `list` exercises a real code path). Non-zero exit fails the job.
5. `(cd dist && sha256sum *.tar.gz > checksums.txt)`.
6. `gh release create "$TAG" --repo "$GITHUB_REPOSITORY" --title "$TAG" --generate-notes dist/*` using the default `GITHUB_TOKEN` (job has `permissions: contents: write`).

### mise installability

Asset naming `wtr_{version}_{os}_{arch}.tar.gz` matches lgx's own releases, which mise's `github:` backend already installs per-platform (`lgx` is consumed this way in this very project's `.mise.toml`). After the first release, users install with:

```sh
mise use github:abogoyavlensky/wtr@latest
```

or pin in `.mise.toml`:

```toml
[tools]
wtr = "0.1.0"

[tool_alias]
wtr = "github:abogoyavlensky/wtr"
```

### Error handling

- All release shell steps run with `set -euo pipefail`.
- Checksum verification failure, build failure, or smoke-test failure aborts before any release is created.
- The release job runs only after the checks job passes (`needs`).
- `concurrency: group: release-${{ github.ref }}` prevents duplicate release runs for the same tag.

### Testing strategy

- `checks.yml` validates itself: it runs on the PR/push that introduces it.
- The release build loop is dry-run locally before tagging: download the `darwin_arm64` base, run `lgx build -bundle-base`, and execute the produced binary on the dev machine.
- First real end-to-end validation happens by pushing a pre-release tag (e.g. `v0.1.0-rc1`); the release can be deleted and re-tagged if something is off.

## File Structure

- Modify: `lgx.edn` — add `:tasks` map (`:fmt`, `:fmt-check`, `:check`).
- Create: `.github/workflows/checks.yml` — fmt + test CI, reusable via `workflow_call`.
- Create: `.github/workflows/release.yml` — tag-triggered build + publish.
- Modify: `README.md` — add an Installation section (mise + manual download).

## Task 1: Add lgx tasks for formatting and checks

**Files:**
- Modify: `lgx.edn`

- [ ] **Step 1: Add `:tasks` map to `lgx.edn`**
  Follow the shape used in `../tiny-cli/lgx.edn`:
  - `:fmt` — doc "Format source files", runs `cljfmt fix`.
  - `:fmt-check` — doc "Check source file formatting", runs `cljfmt check`.
  - `:check` — doc "Run all checks", runs `lgx fmt` then `lgx test`.
  No multi-runtime test task is needed: wtr is an app, not a library, so plain `lgx test` is the test command.

- [ ] **Step 2: Verify tasks work locally**
  Run: `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx fmt-check`
  Expected: exit 0 (or formatting diffs; if diffs, run the `fmt` task and re-check).
  Run: `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx test`
  Expected: all tests PASS.

- [ ] **Step 3: Commit**
  `git commit -m "Add fmt and check tasks to lgx.edn"`

## Task 2: Add checks workflow

**Files:**
- Create: `.github/workflows/checks.yml`

- [ ] **Step 1: Write the workflow**
  Copy the structure of `../tiny-cli/.github/workflows/checks.yml`:
  - `on:` push to `master`, pull_request to `master`, and `workflow_call:`.
  - Single `checks` job on `ubuntu-latest`: `actions/checkout@v6`, `jdx/mise-action@v3`, then `lgx fmt-check` and `lgx test` steps.
  Note the test step runs `lgx test` (not `test-all` — that task doesn't exist in wtr).

- [ ] **Step 2: Validate workflow syntax**
  Run: `actionlint .github/workflows/checks.yml` if available, otherwise a YAML parse check: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/checks.yml'))"`
  Expected: no errors.

- [ ] **Step 3: Commit**
  `git commit -m "Add CI checks workflow"`

## Task 3: Add release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Write the workflow**
  Structure:
  - `on: push: tags: ["v*"]`.
  - `concurrency: group: release-${{ github.ref }}, cancel-in-progress: false`.
  - Job `checks`: `uses: ./.github/workflows/checks.yml`.
  - Job `release`: `needs: [checks]`, `runs-on: ubuntu-latest`, `permissions: contents: write`.
    Steps: `actions/checkout@v6`, `jdx/mise-action@v3`, then:
    1. "Read lg version" step — awk snippet from `../lgx/.github/actions/setup-lg/action.yml` that extracts the `lg` version from `.mise.toml` `[tools]` and exports `LG_VERSION` to `$GITHUB_ENV`; fail if empty.
    2. "Build bundles for all targets" step (env `TAG: ${{ github.ref_name }}`), `set -euo pipefail`, `version="${TAG#v}"`:
       - `mkdir -p dist bases build`; download the let-go release `checksums.txt` once, saved as `lg-checksums.txt` (distinct name so it can't be confused with the `dist/checksums.txt` produced later).
       - Loop `for target in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64`: `mkdir -p "bases/$target" "build/$target"` (per-target dirs, as in lgx's release workflow), download `let-go_${LG_VERSION}_${target}.tar.gz`, verify with `grep " $tarball\$" lg-checksums.txt | sha256sum -c -`, extract to `bases/$target`, run `lgx build -bundle-base "bases/$target/lg"`, `mv bin/wtr "build/$target/wtr"`, `tar -czf "dist/wtr_${version}_${target}.tar.gz" -C "build/$target" wtr`. Wrap each iteration in `::group::`/`::endgroup::` log groups like lgx's release does.
       - Smoke test after the loop: `./build/linux_amd64/wtr list` (must exit 0).
       - `(cd dist && sha256sum *.tar.gz > checksums.txt)` and `ls -la dist/`.
    3. "Publish GitHub Release" step (env `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`, `TAG: ${{ github.ref_name }}`): `gh release create "$TAG" --repo="$GITHUB_REPOSITORY" --title="$TAG" --generate-notes dist/*`.

- [ ] **Step 2: Validate workflow syntax**
  Run: `actionlint .github/workflows/release.yml` if available, otherwise the YAML parse check as in Task 2.
  Expected: no errors.

- [ ] **Step 3: Dry-run the build loop locally for one target**
  From the repo root, reproduce one loop iteration for `darwin_arm64` (the dev machine's platform) in a temp dir: read the lg version from `.mise.toml`, download and verify the base tarball, then
  `LGX_LG=/Users/andrew/Projects/let-go/lg /Users/andrew/Projects/lgx/bin/lgx build -bundle-base <extracted>/lg`
  and run `./bin/wtr list`.
  Expected: binary builds and `wtr list` prints the worktree table.
  Clean up: restore `bin/wtr` if it was previously committed, remove temp files.

- [ ] **Step 4: Commit**
  `git commit -m "Add release workflow publishing cross-platform binaries"`

## Task 4: Document installation in README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add an Installation section**
  Near the top (before Commands). Content, following the style of lgx's README install docs:
  - mise one-liner: `mise use github:abogoyavlensky/wtr@latest`.
  - Pinned `.mise.toml` example with `[tools]` + `[tool_alias]` (as in the Design section above).
  - Manual fallback: download the platform tarball from GitHub releases, extract, put `wtr` on `PATH`.
  - Note that releases are created by pushing a `v*` tag.
  Use /writing-clearly principles: short sentences, active voice.

- [ ] **Step 2: Commit**
  `git commit -m "Document installation via mise"`

## Task 5: Validate on GitHub

- [ ] **Step 1: Push branch and confirm checks pass**
  Push the branch, open a PR (or push to master per project habit), and confirm the `checks` workflow is green.
  Run: `gh run watch` or `gh run list --workflow=checks.yml --limit=1`
  Expected: conclusion `success`.

- [ ] **Step 2: Cut a pre-release tag to validate the release pipeline**
  Run: `git tag v0.1.0-rc1 && git push --tags`
  Expected: release workflow runs checks, builds 4 tarballs + `checksums.txt`, and publishes a GitHub release with 5 assets.

- [ ] **Step 3: Verify mise installation**
  Run: `mise install github:abogoyavlensky/wtr@0.1.0-rc1 && mise exec github:abogoyavlensky/wtr@0.1.0-rc1 -- wtr list`
  Expected: installs the darwin_arm64 asset and prints the worktree table.
  If mise refuses the prerelease version, fall back to downloading the darwin_arm64 asset from the release page manually and running the extracted binary.
