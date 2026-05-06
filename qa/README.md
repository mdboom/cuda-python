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

* **cybind updates**: `cybind_header_update.sh` and `run_cybind()` function
* **cython-gen updates**: `run_cython_gen()` function
* **enum updates**: `update_cuda_core_enum_explanations.sh`

See the individual sections below for usage details.

### Runbook

The `qa/runbook/` directory contains Linux and Windows build/test command
scripts that serve as a human-readable runbook during pre-release testing and
handoff.

These scripts are used directly for validation before handing `ctk-next` to
the QA team, and they also act as a reference for equivalent steps in the QA
team's own automation systems.

### cython-gen

The [`cuda-python-private:cython-gen`](https://github.com/NVIDIA/cuda-python-private/tree/cython-gen) branch contains
custom auto-generation scripts and configuration files for generating `driver`, `runtime`, and `nvrtc` bindings.
It includes scripts for:

* Fetching and processing CUDA headers.
* Generating documentation configurations.
* Creating Python bindings for CUDA driver, runtime, and NVRTC code.

**Branch naming convention**: For CTK 13.X, create a branch named `cython-gen-next-130X0` (e.g., `cython-gen-next-13020` for CTK 13.2).

**Reference previous versions**: When updating for a new CTK version, archived branches from previous versions are valuable references:
* Check `archive/cython-gen-next-13010` (or similar) to see how new APIs were added
* Look at `configs/driver/_driver.py` in the previous branch to understand patterns for:
  - `signature_mapping`: Maps API names to parameter handling types (`SigType`)
  - `structure_mapping`: Maps structures with pointer members to parameter handling
  - `cuda_api_introduced_version`: Records the CTK version each API was introduced
* **Important**: Don't delete old branches—archive them (e.g., `archive/cython-gen-next-13020`) for future reference

**Update process**:

Use the helper function from the cython-gen repository root:
```bash
cd /path/to/cython-gen
run_cython_gen 13.2 ../ctk-next
```
This automatically creates/updates the virtual environment if needed and runs the full regeneration workflow with proper logging.

Alternatively, you can invoke the script directly:
```bash
CUDA_HOME=/usr/local/cuda-13.2 python regenerate.py -o ../ctk-next
```

**Common issues when updating cython-gen**:
* Missing API signatures: The script will report missing entries in `signature_mapping`. Add them to `configs/driver/_driver.py` (or `runtime/_runtime.py`, `nvrtc/_nvrtc.py`).
* Missing `_ptsz` variants: Some APIs have per-thread stream zero variants (e.g., `cuMemcpyWithAttributesAsync_ptsz`). These also need entries in `cuda_api_introduced_version`.
* Structure mappings: If a structure contains pointer members, add it to `structure_mapping` with the appropriate parameter handling type.

### cybind

All other library bindings provided by `cuda-bindings` are supported by [`cybind`](https://gitlab-master.nvidia.com/leof/cybind/).

**Branch naming convention**: For CTK 13.X, create a branch named `cybind-next-130X0` (e.g., `cybind-next-13020` for CTK 13.2).

**Reference previous versions**: Archived branches from previous versions are valuable references:
* Check `archive/cybind-next-13010` (or similar) to see how headers were updated
* Look at config files (e.g., `cybind/assets/configs/config_cufile.py`) to see version update patterns
* **Important**: Don't delete old branches—archive them (e.g., `archive/cybind-next-13020`) for future reference

**Update process**:

1. **Update headers**: Use the helper script from the cybind repository root:
   ```bash
   cd /path/to/cybind
   cybind_header_update.sh 13.2
   ```
   This copies headers from `/usr/local/cuda-13.2/` and applies necessary patches (e.g., `cufile.h` docstring fixes).

2. **Update version lists**: Manually update version lists in config files (e.g., `cybind/assets/configs/config_cufile.py`).

3. **Generate bindings**: Use the helper function from the cybind repository root:
   ```bash
   cd /path/to/cybind
   run_cybind 13.2 ../ctk-next
   ```
   This automatically creates/updates the virtual environment if needed and generates bindings with proper logging.

**Common issues when updating cybind**:
* Docstring parsing errors: Some headers may need manual patches to ensure proper docstring formatting (e.g., adding missing `@param` tags)
* Missing version entries: Don't forget to update the `versions` list in each library's config file

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

#### CUDA enums

Two files under `cuda/core/_utils/` need to be updated:

* `cuda/core/_utils/driver_cu_result_explanations.py`
* `cuda/core/_utils/runtime_cuda_error_explanations.py`

**Update process**:

Use the helper script from the ctk-next (or cuda-python) repository root:
```bash
cd /path/to/ctk-next
update_cuda_core_enum_explanations.sh 13.2
```

This script:
1. Generates enum explanations using `toolshed/reformat_cuda_enums_as_py.py`
2. Updates both target files while preserving headers
3. Updates the CUDA Toolkit version number in comments
4. Formats files with ruff via pre-commit
5. Verifies files compile
6. Reports git diff with preview

The script automatically detects which enum to parse based on the header file and handles all the file manipulation automatically.

---

## How to Merge Public `main` into `ctk-next`

To keep `ctk-next` synchronized with the latest public changes, use one of the helper scripts:

```bash
git_merge_public_main.sh
```

This script fetches and merges the current `main` branch from the public `cuda-python` repository into the private `ctk-next` branch.
It performs a clean merge without having to permanently add a remote.

## How to Squash-Merge ctk-next Back into Public main

### Preparing a Preview Branch

Before the CTK release goes live, you can create a preview branch that
cleanly separates the cython-gen and cybind generated changes from all other
changes. This makes it easier to review the changes in isolation ahead of
time, which is especially useful since you cannot create a public PR until
after the new CTK has been posted publicly. The goal is to be well-prepared
for a 0-day release of `cuda-bindings`.

Use one of the helper scripts:

```bash
make_squash_merge_into_public_main_preview.sh <branch-name>
```

This script:
1. Creates a new branch based on `public_repo/main` in a separate git worktree
2. Runs `run_cython_gen` and `run_cybind` to generate fresh bindings
3. Creates commits for cython-gen and cybind changes separately
4. Squash-merges your branch, automatically resolving conflicts in generated files
5. Shows a diff (filtering out hash-only changes) to review "everything else" changes

The preview branch allows you to:
- Review generated changes separately from manual changes
- Verify that the diff between your branch and the preview is minimal (ideally only hash differences)
- Prepare the final PR structure ahead of time

**Important**: Before running the script, ensure that:
- Your branch has all cython-gen and cybind updates committed
- The `cython-gen` and `cybind` repositories are git worktrees and clean
- Your current working tree is clean

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
  cuda_bindings_13.2.0_release
```

This script:
1. Validates you're in the public cuda-python repository
2. Validates the preview worktree exists and is clean
3. Verifies the preview branch name matches expected pattern
4. Verifies the preview base matches your current `main` branch
5. Creates a new branch in the current repository from the preview commits
6. Does not modify the preview worktree or ctk-next repository

The preview branch is already based on `public_repo/main` and contains three clean commits:
- `cython-gen updates (automatic, NO MANUAL CHANGES)`
- `cybind updates (automatic, NO MANUAL CHANGES)`
- `git merge --squash <branch-name> && git rm -r -f qa/ (NO MANUAL CHANGES)`

After the branch is created, push it using your standard workflow and create
a PR. After the PR is merged, merge the corresponding cython-gen and cybind
branches into their respective repositories, e.g.:
- `cython-gen-next-13020` → merge into `cython-gen` repository
- `cybind-next-13020` → merge into `cybind` repository

---

## Tips for Future CTK Updates

### Reference Previous Version Branches

**Highly recommended**: When updating for a new CTK version, archived branches from previous versions are valuable references:

* **cython-gen**: Check `archive/cython-gen-next-13010` (or similar) to see:
  - How new APIs were added to `signature_mapping`
  - How `_ptsz` variants were handled
  - Patterns for `structure_mapping` and `cuda_api_introduced_version`

* **cybind**: Check `archive/cybind-next-13010` (or similar) to see:
  - Which headers were updated
  - Manual patches that were applied (e.g., `cufile.h` docstring fixes)
  - Config file version update patterns

**Branch archiving**: After completing a CTK release:
1. Archive the working branches instead of deleting them
2. Use naming like `archive/cython-gen-next-13020` and `archive/cybind-next-13020`
3. These archived branches serve as templates for future updates

### Common Workflow Patterns

1. **cython-gen updates**:
   - Run `regenerate.py` to identify missing configurations
   - Reference previous version branch to understand patterns
   - Add missing entries to config files
   - Re-run until generation succeeds

2. **cybind updates**:
   - Run `cybind_header_update.sh` to copy headers and apply patches
   - Update config file version lists manually
   - Run `run_cybind` to generate bindings
   - Commit results

3. **Enum updates**:
   - Run `update_cuda_core_enum_explanations.sh` to update both enum files
   - Review the git diff output
   - Commit results
