# QA Directory

> **This directory exists only on `ctk-next`.**

---

## Overview

The `ctk-next` branch of `cuda-python-private` is a staging branch for pre-release testing with upcoming CUDA Toolkit (CTK) releases.
It was originally **seeded from the public `cuda-python` repository’s `main` branch** and is periodically updated to stay in sync with it.

Within `ctk-next`, the `qa/` subdirectory contains scripts, helpers, and documentation that are *specific to internal or pre-release QA* activities.
This directory **does not exist in the public `main` branch**.

---

## Relationship between `ctk-next` and `main`

- The `qa/` subdirectory is the only directory unique to `ctk-next`.
  Everything else mirrors the public `main` branch.

- During **pre-CTK-release testing periods**, `ctk-next` may be *ahead of* `main`, containing changes specific to the upcoming CTK version.
  However, it will be **kept closely synchronized** with public `main` by regularly merging updates from the public repository.

- During **non-testing periods**, `ctk-next` will effectively be a clean copy of `main`.

- After each CTK release is publicly posted, we perform a **squash merge** of `ctk-next` back into the public `main` branch, **excluding** the `qa/` directory.

---

## What goes into `ctk-next`?

"Kitpicks" are CTK release candidates, sometimes referred to as, e.g., "13.2 RC 001". They are hosted here:

[**https://kitmaker-web.nvidia.com/kitpicks/cuda-r13-2/13.2.0/**](
    https://kitmaker-web.nvidia.com/kitpicks/cuda-r13-2/13.2.0/)

A helper script is available for downloading `linux-64`, `linux-aarch64`, and `win-64` release candidates (available on PATH after activating helpers):

`download_from_kitpicks.py --help`

<img src="ctk-next.drawio.svg" width="400">

### Helper Scripts

The `qa/helpers/` directory contains automation scripts for common CTK update tasks. To use them, first activate the helpers:

```bash
. qa/helpers/activate_helpers.sh
```

This adds the helper directory to your `PATH` and provides bash functions for common workflows:

* **initial checkout setup**: `git_clone_source_trees.sh`
* **public-main sync and merge**: `public_repo.py`, `git_merge_public_main.sh`
* **native cybind updates**: `cybind_header_update.sh` and `run_cybind_native()`
* **driver/runtime/nvrtc updates**: `run_cybind_cython_gen()`
* **preview/public-branch helpers**: `make_squash_merge_into_public_main_preview.sh`, `copy_preview_to_public_branch.sh`
* **NVBugs release tracking**: `ctk-next_nvbug_rc.sh`

See the individual sections below for usage details.

### Initial Checkout Setup

If you are starting from a scratch directory on a new workstation and do not
have `ctk-next` checked out yet, the shortest bootstrap is a one-liner via an
authenticated `gh` session:

```bash
gh api -H "Accept: application/vnd.github.raw" "/repos/NVIDIA/cuda-python-private/contents/qa/helpers/git_clone_source_trees.sh?ref=ctk-next" > ./git_clone_source_trees.sh
```

Alternatively, navigate to

* https://github.com/NVIDIA/cuda-python-private/blob/ctk-next/qa/helpers/git_clone_source_trees.sh

and download the same file from the GitHub UI.

Make the script executable with:

```bash
chmod +x ./git_clone_source_trees.sh
```

After you use the helper to create the standard sibling checkouts, the
canonical copy will also be available under
`ctk-next/qa/helpers/git_clone_source_trees.sh`.

To create the standard sibling checkouts in one step, use:

```bash
git_clone_source_trees.sh [--gitlab-username <name>] [--tolerate-missing-forks] \
  <github-username> [cuda-python|ctk-next|cybind ...]
```

With no repo names, the helper clones all three repositories and configures
`upstream` and `origin` remotes for each checkout. Existing directories are
reported and skipped so you can re-run it safely.

Before cloning anything, the helper checks that required fork remotes exist for
repositories that do not already exist locally. If any are missing, it stops
and enumerates them. To continue anyway, pass `--tolerate-missing-forks`.
When a selected repo already exists locally, the helper says that the fork
check is being skipped because the clone phase will skip that repo too. A
fully skipped run therefore does not validate the supplied usernames.

For `cybind`, the GitLab fork namespace defaults to `$USER`. If your GitLab
namespace differs from your workstation username, pass
`--gitlab-username <name>`.

### Runbook

The `qa/runbook/` directory contains Linux and Windows build/test command
scripts that serve as a human-readable runbook during pre-release testing and
handoff.

These scripts are used directly for validation before handing `ctk-next` to
the QA team, and they also act as a reference for equivalent steps in the QA
team's own automation systems.

## Updating Bindings via `cybind`

The current source of truth for both legacy (`driver`, `runtime`, `nvrtc`) and
native (`cufile`, `nvjitlink`, `nvml`, `nvvm`, `nvfatbin`) generation is
[`cybind`](https://gitlab-master.nvidia.com/leof/cybind/).

The old standalone `cython-gen` repository, older docs that refer to it, and
GitLab MR 345 are now historical references only. Start from a current
`cybind` checkout first.

### Legacy libraries: `driver`, `runtime`, `nvrtc`

`run_cybind_cython_gen()` drives the legacy generator that now lives under
`cybind/legacy_cython_gen/`.

Use the helper from the `cybind` repository root:

```bash
cd /path/to/cybind
run_cybind_cython_gen 13.3.0 ../ctk-next
```

This helper requires the CTK target version in `<major>.<minor>.<patch>` form
and writes into `../ctk-next/cuda_bindings`.

You can also invoke `cybind` directly:

```bash
python -m cybind -vvv --ctk-target-version 13.3.0 --generate driver runtime nvrtc --output-dir ../ctk-next/cuda_bindings
```

If you need to refresh the local legacy headers from an installed toolkit, do it
from the `cybind` repository root:

```bash
python -m cybind -vvv --fetch driver runtime nvrtc \
  --local-path /usr/local/cuda-13.3/include \
  --local-version 13.3.0
```

Common issues when updating `driver`/`runtime`/`nvrtc`:

* Local fetches for a new CTK version need the requested version to be accepted
  by the legacy generator first (for example in
  `cybind/legacy_cython_gen/main.py`)
* Missing `signature_mapping` or `cuda_api_introduced_version` entries in
  `cybind/legacy_cython_gen/configs/`
* Missing `_ptsz` variants for new driver APIs
* New structures or typedef-backed anonymous structs that need additional
  pointer-handling or parser fixes

### Native libraries: `cufile`, `nvjitlink`, `nvml`, `nvvm`, `nvfatbin`

The native generator path covers `cufile`, `nvjitlink`, `nvml`, `nvvm`, and
`nvfatbin`.

For a new CTK version, the most reliable flow is:

1. Add the new version to the relevant `versions` lists in
   `cybind/assets/configs/` before attempting any local fetch commands.
2. Fetch headers from the installed toolkit with `cybind --fetch`.
3. Apply or refresh any header patches that still matter (for example the
   `cufile` patch that keeps doc quality consistent).
4. Regenerate bindings with `run_cybind_native`.
5. Run `pre-commit run --all-files` in `ctk-next` before reviewing the final
   diff.

Example local fetch commands from the `cybind` repository root:

```bash
cd /path/to/cybind

python -m cybind -vvv --fetch cufile nvjitlink nvml nvfatbin \
  --local-path /usr/local/cuda-13.3/include \
  --local-version 13.3.0

python -m cybind -vvv --fetch nvvm \
  --local-path /usr/local/cuda-13.3/nvvm/include \
  --local-version 13.3.0
```

Then regenerate:

```bash
cd /path/to/cybind
run_cybind_native 13.3.0 ../ctk-next
```

Or invoke `cybind` directly:

```bash
python -m cybind -vvv --generate cufile nvjitlink nvml nvvm nvfatbin --output-dir ../ctk-next/cuda_bindings
```

Notes:

* `run_cybind_native()` now includes `nvfatbin`.
* `cybind_header_update.sh` is still useful as a convenience wrapper for a few
  manual header copies and the `cufile` patch, but the canonical bring-up flow
  for a new CTK is `python -m cybind --fetch ... --local-path ... --local-version ...`.
* `nvvm` uses a nonstandard local header layout under `nvvm/include`, so it
  needs its own fetch command.
* New generated files may still need a follow-up `pre-commit` normalization
  pass (for example EOF or trailing-whitespace fixes in generated `nvml.pyx`).

### Manual updates

#### cuda-pathfinder `supported_*.py`

These cuda-pathfinder files may need to be updated:

* `cuda/pathfinder/_headers/supported_nvidia_headers.py`
* `cuda/pathfinder/_dynamic_libs/supported_nvidia_libs.py`

No updates are required **prior** to a CTK release if all `cuda_pathfinder/tests/` pass.
PyPI wheels for new CTK releases may become available only a few days or even weeks after the main CTK release date.
Therefore it is likely that updates to the two files above will be required after the release, in the public repo.

#### `_ptx_to_cuda`

The `_ptx_to_cuda` dictionary in

* `cuda_bindings/cuda/bindings/utils/_ptx_utils.py`

may need to be updated, based on the table shown under the
[PTX Release Notes](http://sw-mobile-docs/CUDA/GPGPU/parallel-thread-execution/index.html#release-notes).

`update_cuda_core_enum_explanations.sh` still exists, but enum explanation
refreshes are usually a follow-up cleanup in the public repository rather than
part of the normal `ctk-next` pre-release bring-up flow.

---

## How to Merge Public `main` into `ctk-next`

Recommended flow:

```bash
git checkout -b "ctk-next-merge-main-$(date +%Y-%m-%d+%H%M)"
qa/helpers/public_repo.py sync
qa/helpers/git_merge_public_main.sh
```

Notes:

* `public_repo.py sync` keeps the `public_repo` remote, the private
  `public-main` branch, and tags aligned with the public repository.
* `git_merge_public_main.sh` is still the correct entry point for merging the
  public `main` branch into `ctk-next`.
* The merge helper fetches `main`, shows incoming commits, prompts before
  merging, and auto-resolves conflicts only in auto-generated files.
* Start from a clean branch/worktree and expect `qa/` itself to remain
  untouched by this merge step.
* After the helper finishes, review any remaining conflicts or merge diff and
  regenerate generated files only if the merge actually requires it.

## How to Squash-Merge ctk-next Back into Public main

### Preparing a Preview Branch

Before the CTK release goes live, you can create a preview branch that
cleanly separates the legacy and native cybind-generated changes from all other
changes. This makes it easier to review the changes in isolation ahead of
time, which is especially useful since you cannot create a public PR until
after the new CTK has been posted publicly. The goal is to be well-prepared
for a 0-day release of `cuda-bindings`.

Start by syncing public refs, then create the preview:

```bash
qa/helpers/public_repo.py sync
qa/helpers/make_squash_merge_into_public_main_preview.sh <branch-name>
```

This script:
1. Creates a new branch based on `public_repo/main` in a separate git worktree
2. Runs `run_cybind_cython_gen` and `run_cybind_native` to generate fresh bindings
3. Creates commits for legacy and native cybind changes separately
4. Squash-merges your branch, automatically resolving conflicts in generated files
5. Shows a diff (filtering out hash-only changes) to review "everything else" changes

The preview branch allows you to:
- Review generated changes separately from manual changes
- Verify that the diff between your branch and the preview is minimal (ideally only hash differences)
- Prepare the final PR structure ahead of time

Important:

* Your branch should already contain the manual changes you want to preview.
* Keep `ctk-next` and the sibling `cybind` checkout clean before running the
  helper.
* The helper currently still contains some stale implementation details,
  including an old sibling-`cython-gen` checkout check and release-specific
  version literals. Refresh those assumptions before relying on it for a new
  CTK cycle.

### Copying the Preview Branch to Public Repo

Once the CTK release has been publicly posted, you can copy the preview
branch into the public repository:

```bash
cd .../cuda-python
copy_preview_to_public_branch.sh <preview-worktree-path> <branch-name>
```

Example:
```bash
cd /wrk/forked/cuda-python
copy_preview_to_public_branch.sh \
  ../squash_merge_into_public_main_preview_2026-02-28+1250 \
  cuda_bindings_13.3.0_release
```

This script:
1. Validates you're in the public cuda-python repository
2. Validates the preview worktree exists and is clean
3. Verifies the preview branch name matches expected pattern
4. Verifies the preview base matches your current `main` branch
5. Creates a new branch in the current repository from the preview commits
6. Does not modify the preview worktree or ctk-next repository

The preview branch is already based on `public_repo/main` and contains three clean commits:
- `driver/runtime/nvrtc updates via cybind (automatic, NO MANUAL CHANGES)`
- `cybind updates (automatic, NO MANUAL CHANGES)`
- `git merge --squash <branch-name> && git rm -r -f qa/ (NO MANUAL CHANGES)`

After the branch is created, push it using your standard workflow and create
a PR. After the PR is merged, merge the corresponding `cybind` branch into
your `cybind` repository as needed. The older separate `cython-gen`
follow-up is stale.

---

## NVBugs Workflow

At the start of each SWQA test cycle, expect two related NVBugs:

* The SWQA team opens a **test-plan review and sign-off** bug, usually with a
  subject like `[Test Plan Review and Sign Off]: CUDA Python 13.3 Test Plan
  Review and sign off`.
* The CUDA Python team opens a **release tracking** bug, usually with a subject
  like `Release of CUDA Python 13.3.0`.

Recommended flow for the CUDA Python team:

1. Wait until the SWQA test-plan review bug appears, then use that as the
   anchor for the new cycle.
2. Clone the `Release of CUDA Python` bug from the previous test cycle. Update
   all CTK and CUDA Python version numbers, and replace the test-plan review
   link with the new SWQA bug. Also update `See Also` links so the two current
   cycle bugs point at each other instead of stale prior-cycle bugs.
3. Reset the release bug description for the new cycle:
   * Remove all entries under `ctk-next updates (newest-to-oldest):`.
   * Create the new `cuda.bindings_M.N_committed` keyword at
     https://nvbugswb.nvidia.com/NVBugs5/Request.aspx?dvid=1 and update the
     keyword instructions to use it.
   * Retain all entries under `Open bugs`.
   * Remove all entries under `Closed bugs`.
4. Do the required `cybind` and `ctk-next` bring-up work for the new CTK
   version, following the sections in this README.
5. Each time a change is merged into `ctk-next`, add a new first item under
   `ctk-next updates (newest-to-oldest):` in the release bug. Use
   `qa/helpers/ctk-next_nvbug_rc.sh` to format the item for copy-pasting.
6. Track SWQA follow-up bugs in the release bug's `Open bugs` and
   `Closed bugs` sections. The volume is usually small enough to manage
   manually during the cycle; formalizing this would be a useful future
   improvement.

---

## Tips for Future CTK Updates

* Start with current `cybind` `main`; older docs, the old standalone
  `cython-gen` repo, and MR 345 are no longer the primary source of truth.
* Archived `cybind-next-*` branches are still useful references for config
  version bumps, header patches, and generator-side fixes.
* The patch sets under `upstream/ctk-release-automation` and
  `upstream/ctkn-go-rewrite` can still be useful when a new CTK adds APIs or
  unusual header layout changes, but compare them against current `cybind`
  first because many older fixes are already absorbed.
* After generation, validate the result with the scripts in `qa/runbook/` and
  run `pre-commit` before treating the diff as final.
