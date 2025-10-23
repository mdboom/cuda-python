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

## How to Merge Public `main` into `ctk-next`

To keep `ctk-next` synchronized with the latest public changes, use the helper script:

```bash
qa/helpers/git_merge_public_main.sh
```

This script fetches and merges the current `main` branch from the public `cuda-python` repository into the private `ctk-next` branch.
It performs a clean merge without adding a remote permanently.

## How to Squash-Merge ctk-next Back into Public main

When a new CTK release goes live:

1. Wait until the CTK release has been publicly posted.

2. Shortly after, create a PR in the public `cuda-python` repo that squashe-merges all `ctk-next` changes into `main`, excluding the `qa/` directory.

To automate this step, use:

```bash
toolshed/git_squash-merge_ctk-next.sh
```

This script lives in the public `cuda-python` repository and prepares the `merge-ctk-next` branch there,
performs the squash-merge, removes `qa/`, and commits the result with a standardized message.
