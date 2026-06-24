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
* **preview/public-branch helper**: `make_squash_merge_into_public_main_preview.sh`
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
git switch -c "merge-public-main-$(date +%Y-%m-%d+%H%M)"
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

## How to Transfer ctk-next Back to Public main

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
qa/helpers/make_squash_merge_into_public_main_preview.sh <branch-name> <ctk-version>
```

The preview helper:
1. Creates a new branch based on `public_repo/main` in a separate git worktree
2. Runs `run_cybind_cython_gen` and `run_cybind_native` to generate fresh bindings
3. Creates commits for legacy and native cybind changes separately
4. Squash-merges your branch, automatically resolving conflicts in generated files
5. Splits generated version/hash metadata drift into a separate review commit
6. Writes a transfer patch for the final non-generated squash commit
7. Shows a diff, filtering expected metadata drift, to review remaining differences

The preview branch allows you to:
- Review generated changes separately from manual changes
- Verify that the diff between your branch and the preview is minimal
- Prepare the public release branch structure ahead of time

Important:

* Your branch should already contain the manual changes you want to preview.
* Keep `ctk-next` and the sibling `cybind` checkout clean before running the
  helper.
* Before running the helper, refresh the sibling `cybind` checkout using the
  same branch you used for CTK bring-up. For example: update `cybind` `main`,
  switch back to the release branch, merge `main`, and recreate the cybind venv
  with `cybind_fresh_venv` if needed.

The preview branch contains up to four clean commits:
- `run_cybind_cython_gen <ctk-version> ../ctk-next (NO MANUAL CHANGES)`
- `run_cybind_native <ctk-version> ../ctk-next (NO MANUAL CHANGES)`
- `cybind-generated version hash drift (NO MANUAL CHANGES)`
- `git merge --squash <branch-name> && git rm -r -f qa/ (NO MANUAL CHANGES)`

If either cybind regeneration step is a no-op, the corresponding generated
commit is omitted. If there are no generated version/hash metadata files to
split out, the hash-drift commit is omitted. The helper validates the
hash-drift commit after creating the full preview stack; if that commit
contains anything other than expected generated
`# This code was automatically generated across versions from ...`
metadata changes or SPDX copyright header drift, the preview branch is left
in place for review and the helper exits non-zero.

The helper also writes a transfer patch for the final non-generated squash
commit next to the preview worktree:

```bash
../squash_merge_into_public_main_preview_<timestamp>_non_gen_transfer.patch
```

If you need to recreate that patch manually, generate it from the final squash
commit in the preview worktree:

```bash
git -C ../squash_merge_into_public_main_preview_<timestamp> \
  show --format= --binary <final-squash-commit> \
  > ../squash_merge_into_public_main_preview_<timestamp>_non_gen_transfer.patch
```

### Release-Day Public Branch

After the CTK release is public, recreate the release branch directly in the
public `cuda-python` checkout instead of copying the preview branch. This keeps
the public PR history clean while reusing the previewed non-generated changes:

```bash
cd .../cuda-python
git switch main
git pull --ff-only
git switch -c ctk13030

cd ../cybind
run_cybind_cython_gen 13.3.0 ../cuda-python
cd ../cuda-python
pre-commit run --all-files
git add -A
git commit -m "run_cybind_cython_gen 13.3.0 ../cuda-python (NO MANUAL CHANGES)"

cd ../cybind
run_cybind_native 13.3.0 ../cuda-python
cd ../cuda-python
pre-commit run --all-files
git add -A
git commit -m "run_cybind_native 13.3.0 ../cuda-python (NO MANUAL CHANGES)"

git apply --index ../squash_merge_into_public_main_preview_<timestamp>_non_gen_transfer.patch
git commit -m "Apply ctk-next non-generated release changes"
```

Review and finish the public-only release work after this point, including
release notes, `.github/`, and `ci/` changes for the final CTK source locations,
then run the public CI.

After the public release branch is ready, push it using your standard workflow
and create a PR. After the PR is merged, merge the corresponding `cybind`
branch into your `cybind` repository as needed.

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
7. After the CTK is public and the corresponding CUDA Python packages are
   released, notify SWQA in the release tracking bug. This is their signal to
   start post-release validation. Keep the release tracking bug open until SWQA
   reports that post-release validation is complete.

---

## DVS-SC Nightly Testing

This section summarizes what we currently know about the DVS-SC nightly testing
workflow for CUDA Python and `ctk-next`. It is intended to give CUDA Python
developers enough context to understand DVS-SC bug reports and to ask better
follow-up questions when test behavior is unclear.

According to a June 16, 2026 Slack DM summary from Mingyan, it is reasonable to
call this "nightly testing in DVS-SC", although each active line is launched
about three times per week. DVS-SC pulls the latest `ctk-next` for each
launch. At that time, their active coverage included unreleased CTK 13.3.1,
unreleased CTK 13.4.0, and the next integration/release line using CUDA
`gpgpu` with driver `bugfix_main`, then corresponding roughly to CTK 13.5.

At a high level, DVS-SC packages a CUDA Toolkit build, a display driver, and a
fresh `ctk-next` checkout into a DVS test package. The main source-based CUDA
Python functional suite initializes a conda environment and then runs
`python_low_level_binding_tests.py` phases such as `unit_test`, `cuda_core`,
and `Numba`. The performance suite uses the same general package context, but
switches to a benchmark conda environment and runs the cuda-bindings pyperf
benchmarks under `benchmarks/cuda_bindings`.

`python_low_level_binding_tests.py` is the CUDA Python-specific test driver in
the DVS-SC test bundle. It is the part most similar to a script a CUDA Python
developer might write locally: create or refresh a conda environment, install
the current `ctk-next` checkout and dependencies, then run selected validation
phases. The functional suite uses it for phases such as `unit_test`,
`cuda_core`, and `Numba`; the performance suite uses it to run cuda-bindings
pyperf benchmarks.

DVS-SC calls that Python driver from a `.trs` file. The `.trs` file is the DVS
runner recipe, not CUDA Python test code: it declares environment variables,
timeouts, setup and cleanup steps, and the commands to run. For example,
`python_low_level_binding_tests.trs` sets `CONDA_HOME` and `CUDA_HOME`, invokes
`python_low_level_binding_tests.py --init`, then invokes
`python_low_level_binding_tests.py --test ...` for the selected phase. In
short, the Python file owns the CUDA Python setup and test logic, while the
`.trs` file owns the DVS orchestration around it.

For day-to-day `ctk-next` work, the most important takeaway is that DVS-SC
nightly testing is external validation of our current `ctk-next` branch against
pre-release CTK and driver lines. The DVS-SC harness itself lives in Perforce,
not in this repository. We should treat it as downstream automation that can
expose gaps in `ctk-next`, especially around generated bindings, CUDA library
availability, Windows/WSL behavior, cuda-core integration, numba-cuda
interaction, and benchmark coverage.

The notes below are agent-facing reference material. A recommended way to
learn more is to point an agent at this file, then ask follow-up questions. For
deeper investigation, configure the agent with access to internal search and
source connectors such as Glean and Perforce MCP.

### Agent-facing DVS-SC Notes

Known source context:

* DVS-SC CUDA 13.4 build configuration example:
  `//sw/automation/dvs/config/rel/sc/cuda_13.4/Release_Linux_AMD64_py.lowlevel.binding.txt`
* DVS-SC CUDA 13.4 full test package configuration example:
  `//sw/automation/dvs/config/rel/sc/cuda_13.4/packages/Release_Linux_AMD64_py.lowlevel.binding.tests.fulltestpkg_Linux.txt`
* DVS-SC CUDA 13.4 functional suite:
  `//sw/automation/dvs/tests/r13.4/python_low_level_binding_tests/python_low_level_binding_tests.trs`
* DVS-SC CUDA 13.4 performance suite:
  `//sw/automation/dvs/tests/r13.4/python_low_level_binding_tests/python_low_level_binding_perf_tests.trs`

The same test directory pattern exists across recent release lines:

* `//sw/automation/dvs/tests/r13.0/python_low_level_binding_tests/`
* `//sw/automation/dvs/tests/r13.1/python_low_level_binding_tests/`
* `//sw/automation/dvs/tests/r13.2/python_low_level_binding_tests/`
* `//sw/automation/dvs/tests/r13.3/python_low_level_binding_tests/`
* `//sw/automation/dvs/tests/r13.4/python_low_level_binding_tests/`

Useful Swarm entry points:

* https://p4sw-swarm.nvidia.com/files/sw/automation/dvs/tests/r13.0/python_low_level_binding_tests
* https://p4sw-swarm.nvidia.com/files/sw/automation/dvs/tests/r13.1/python_low_level_binding_tests
* https://p4sw-swarm.nvidia.com/files/sw/automation/dvs/tests/r13.2/python_low_level_binding_tests
* https://p4sw-swarm.nvidia.com/files/sw/automation/dvs/tests/r13.3/python_low_level_binding_tests
* https://p4sw-swarm.nvidia.com/files/sw/automation/dvs/tests/r13.4/python_low_level_binding_tests

The r13.4 DVS-SC test directory is a flat test bundle. The most relevant files
for `ctk-next` are:

* `python_low_level_binding_tests.trs`: main functional DVS-SC launcher. It
  sets `CONDA_HOME`, `CUDA_HOME`, and `PYTHON_BIN`, marks the
  `generator/cuda-python-private` checkout safe for Git, runs
  `python_low_level_binding_tests.py --init`, then runs `unit_test`,
  `cuda_core`, re-runs `--init`, runs `Numba`, and finally removes the conda
  environment.
* `python_low_level_binding_perf_tests.trs`: performance launcher. It sets GPU
  clocks to P0, swaps in `python_low_level_binding_benchmark_tests.yml` as the
  active conda environment file, runs `--init`, runs `--test benchmark`, then
  parses pyperf output into DVS multi-result performance lines.
* `python_low_level_binding_tests.py`: source-branch validation logic. It
  initializes the conda environment and runs cuda-pathfinder, cuda-bindings,
  cuda-core, numba-cuda, RMM, and benchmark phases depending on the `.trs`
  entry point.
* `python_low_level_binding_tests.yml`: functional conda environment seed,
  currently Python `>=3.10,<=3.14` plus `cffi`.
* `python_low_level_binding_benchmark_tests.yml`: benchmark conda environment
  seed, currently fixed to Python `3.12` plus `cffi`.
* `parse_benchmark.py`: converts pyperf benchmark output into DVS-SC
  multi-result performance format.
* `cufile.h`: vendored cuFile header copied into `CUDA_HOME/include` by the
  DVS-SC test driver so cuda-bindings can compile and test cuFile coverage.
  Treat this as a DVS-side dependency/workaround, not as a `ctk-next` source
  file.

Other `.trs` variants in the r13.4 directory are useful context but are less
central to normal `ctk-next` nightly interpretation:

* `python_low_level_binding_wsl_tests.trs`: WSL-focused suite. It runs
  `--init`, `unit_test`, and `cuda_core`, but not Numba or benchmark.
* `python_low_level_binding_tests_bc.trs`: backward-compatibility style suite.
  It runs `--init --bc`, `unit_test`, and `samples`; Numba is commented out.
* `python_low_level_binding_tests_enhance_fwd.trs`: enhanced-forward variant.
  It runs `--init`, `unit_test`, and `samples`; Numba is commented out.

The Windows installer validation files appear to be package-install validation
rather than the main source-branch `ctk-next` nightly path:

* `python_low_level_binding_win_install_tests.trs`: Windows installer matrix
  for conda and wheel install/uninstall/version/example checks across Python
  3.9 through 3.13.
* `python_low_level_binding_win_install_tests.py`: implementation of that
  installer validation.
* `python_low_level_binding_pkg.py` and `py_lowlevel_config.json`: helper flow
  for generating CUDA Python package install commands. In the r13.4 copy
  inspected, `py_lowlevel_config.json` still referenced CUDA `12.8.0`, so do
  not assume these files describe current `ctk-next` source-branch nightly
  behavior without rechecking DVS-SC.
* `wget.exe`: Windows utility bundled for DVS package/install workflows.

When investigating DVS-SC nightly failures, start by identifying which `.trs`
suite ran, then inspect the commands it invokes. For ctk-next source-branch
bugs, the usual path is from the `.trs` file into
`python_low_level_binding_tests.py`, then into the failing phase:

* `unit_test`: cuda-pathfinder and cuda-bindings unit tests, including
  per-thread default stream and Cython tests.
* `cuda_core`: cuda-core tests and example tests, with extra handling for
  Python version, CUDA library paths, `CUDA_VISIBLE_DEVICES`, and numba-cuda
  interference.
* `Numba`: numba-cuda clone/install/test flow, with additional dependency,
  test-binary, and cuda-bindings restoration logic.
* `benchmark`: cuda-bindings pyperf benchmarks under
  `benchmarks/cuda_bindings`, parsed by `parse_benchmark.py`.

The script evolved significantly between r13.0 and r13.4. The largest change
was from r13.1 to r13.2, where the file grew from about 500 lines to about
1,000 lines. That change added much stronger Windows, WSL, cuda-core,
numba-cuda, optional-library, and pytest-result handling. The r13.3 and r13.4
copies of `python_low_level_binding_tests.py` are byte-for-byte identical in
the inspected Perforce sync.

For a deeper agent-assisted investigation:

1. Read this section and the `qa/runbook/` scripts to understand the CUDA
   Python team's side of the handoff.
2. Use Perforce MCP or `p4` to inspect the relevant
   `//sw/automation/dvs/tests/<line>/python_low_level_binding_tests/` suite.
3. Use Perforce MCP or `p4` to inspect the corresponding
   `//sw/automation/dvs/config/rel/sc/cuda_<version>/` build/package
   configuration if the question is about packaging, scheduling, platform
   matrix, or CTK/driver selection.
4. Use Glean or Confluence search for DVS-SC documentation when the question
   is about DVS runner semantics, `.trs` fields, scheduled launches, ownership,
   or dashboards.
5. Use Slack only for conversational context and current-human interpretation;
   prefer Perforce/config files for exact commands and source of truth.

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

---

## Agent Instructions for Manipulating the Release Tracking NVBug

This section captures details learned while updating the CUDA Python 13.3
release tracking bug and its linked SWQA bugs. Expand it as future NVBugs
workflows become clearer.

### Marking Linked Bugs as QV2C

When a linked SWQA bug is fixed in `ctk-next` and should move from
`Dev - Open - To fix` to `QA - Open - Verify to close`:

1. Fetch the current linked bug details before updating anything.
2. Confirm the bug is actually fixed and should be marked `QV2C`. Do not mark
   bugs that are intentionally deferred, still open, or tracked with a keyword
   such as `cuda.bindings_next`.
3. Identify the SWQA person to notify from the bug details. Usually this is the
   requester or QA engineer, but follow the human's instruction if they name a
   different person.
4. Use an HTML mention in the comment so the user is clickable in NVBugs:

   ```html
   <span>[<a alt="USER_KEY" class="mention">@Display Name (NTACCOUNT)</a>]&nbsp;Comment text here.<br class="ckLineBrkCmt"><br class="ckLineBrkCmt">Marking this bug as V2C.</span>
   ```

   Get `USER_KEY`, `Display Name`, and `NTACCOUNT` from the fetched bug details
   (`Requester`, `QAEngineer`, `ARB`, and corresponding `*NTAccount` fields).
   Plain text such as `[@Display Name (NTACCOUNT)]` may not become clickable.
5. Update the bug with:
   * `bug_action`: `QA - Open - Verify to close`
   * `disposition`: `Bug - Fixed`
   * `comment`: the prepared comment
   * `comment_notification`: `true`
   * `is_send_notification`: `true`
   * `confirm_update`: `true`
6. Preserve fields that the NVBugs save path may otherwise rewrite. In
   particular, pass the current `qa_engineer` and `geographic_origin` when
   they are present. Without this, the save may change QA engineer or blank the
   geographic origin.
7. Be cautious with `version_fixed_after`. It behaves inconsistently across
   bugs. Leave the current value alone unless the save is rejected or a human
   specifically asks for a value; `n/a` works for some bugs, but others may
   force a version-list choice.
8. Refetch the bug afterward and verify:
   * the comment was added once and is authored by the authenticated user,
   * the mention is clickable HTML,
   * bug action and disposition are correct,
   * notification was requested on the save,
   * unexpected field changes did not occur.

Comments added through the MaaS NVBugs MCP server are posted as the
authenticated user, and the server appends its standard watermark.

### Updating the Release Tracking Bug Description

The umbrella `Release of CUDA Python X.Y.Z` bug is a coordination artifact, so
description-only housekeeping should normally be saved without notification.

When updating the `Open bugs` list after linked bugs move to V2C:

1. Fetch the current release tracking bug description immediately before
   editing.
2. Change only the intended status markers, for example `DO2F` -> `QV2C`.
3. Save with notifications disabled (`is_send_notification=false` and
   `comment_notification=false`).
4. Refetch the bug and verify the status markers and comment count.

When a linked bug is verified and closed:

1. Fetch the linked bug first and confirm `BugAction.Value` is
   `QA - Closed - Verified`. Check the close comment if a human referenced one.
2. In the release tracking bug, move the complete line from `Open bugs` to
   `Closed bugs`.
3. Change the status marker from `QV2C` to green `QCV`, preserving the compact
   `nvbugs/ID` link, owner, and synopsis text.
4. Save the release tracking bug without notification, then refetch and verify
   the bug appears exactly once, under `Closed bugs`.

### Verifying Release Tracking Bug State

Use this workflow to verify that the release tracking bug accurately reflects
the linked SWQA bugs:

1. Fetch the release tracking bug and parse every entry under both `Open bugs`
   and `Closed bugs`.
2. For each linked bug, fetch current NVBugs details and compare the release
   tracking status marker with the bug's `BugAction.Value`:
   * `DO2F` must match `Dev - Open - To fix`.
   * `QV2C` must match `QA - Open - Verify to close`.
   * `QCV` must match `QA - Closed - Verified`.
3. For entries under `Open bugs`, also compare `CustomKeywords` with the
   keyword instructions embedded in the release tracking bug description. Each
   open bug should carry the appropriate release keyword, for example
   `cuda.bindings_M.N_committed` for bugs blocking the current cuda-bindings
   release, or `cuda.bindings_next` for confirmed non-blocking follow-up bugs.
4. Treat closed bugs primarily as a closure check. They should still be
   `QA - Closed - Verified`; they do not necessarily need to keep the open-bug
   release keywords.
5. Report a compact table with bug ID, release marker, actual bug action, and
   relevant keyword status. Call out mismatches explicitly before making any
   updates.

Use these readability conventions when maintaining the bug lists:

* Prefer compact visible NVBugs links such as `nvbugs/6180109`, backed by
  hyperlinks to `https://nvbugspro.nvidia.com/bug/6180109`.
* Keep status labels color-coded:
  * red `DO2F` = `Dev - Open - To fix`
  * orange `QV2C` = `QA - Open - Verify to close`
  * green `QCV` = `QA - Closed - Verified`
* Keep a small legend near the end of the description so humans can decode the
  abbreviated labels without leaving the release tracking bug.

NVBugs description formatting is fragile through the MCP update path:

* If a description containing HTML is saved with raw newline characters, the web
  UI may collapse all line breaks.
* If both raw newlines and `<br />` tags are submitted, the web UI may display
  too many blank lines.
* If line breaks need repair, submit compact HTML using `<br />` tags without
  embedded newline characters. Refetch afterward to confirm the visual structure
  is back to the intended one.
* Description updates through MaaS may append the standard MCP watermark to the
  description. Avoid repeated description saves when a manual web edit would be
  cleaner.
