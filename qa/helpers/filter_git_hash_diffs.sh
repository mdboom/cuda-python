#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE
#
# Filter git diff output to remove hunks that only contain generated metadata
# version/hash drift.
#
# This script filters out diffs where the only difference is in generated
# "across versions" metadata lines, including generator version hashes, or
# SPDX copyright header drift.
#
# Usage:
#   git diff | qa/helpers/filter_git_hash_diffs.sh
#   git diff branch1 branch2 | qa/helpers/filter_git_hash_diffs.sh
#
# Exit code: Always 0 (empty output is handled by caller)

awk '
BEGIN {
    in_hunk = 0
    in_file = 0
    hunk_lines = ""
    minus_lines = ""
    plus_lines = ""
    file_header = ""
    has_output = 0
}
/^diff --git/ {
    # New file diff - process previous file/hunk first
    if (in_hunk) {
        if (!is_generated_metadata_only_hunk(minus_lines, plus_lines)) {
            if (in_file) {
                printf "%s", file_header
                in_file = 0
            }
            printf "%s", hunk_lines
            has_output = 1
        }
    } else if (in_file) {
        # File had no hunks (or all were filtered) - skip file header
        in_file = 0
    }
    # Start new file
    in_hunk = 0
    hunk_lines = ""
    minus_lines = ""
    plus_lines = ""
    file_header = $0 "\n"
    in_file = 1
    next
}
/^index / || /^--- / || /^\+\+\+ / {
    # Header lines - collect for file header
    if (in_file) {
        file_header = file_header $0 "\n"
    }
    next
}
/^@@ / {
    # Start of a new hunk - process previous hunk first
    if (in_hunk) {
        if (!is_generated_metadata_only_hunk(minus_lines, plus_lines)) {
            if (in_file) {
                printf "%s", file_header
                in_file = 0
            }
            printf "%s", hunk_lines
            has_output = 1
        }
    }
    # Start new hunk
    in_hunk = 1
    hunk_lines = $0 "\n"
    minus_lines = ""
    plus_lines = ""
    next
}
in_hunk {
    # Collect hunk content
    hunk_lines = hunk_lines $0 "\n"
    if (/^-[^-]/) {
        # Line starting with single minus (removed line)
        minus_lines = minus_lines $0 "\n"
    } else if (/^\+[^+]/) {
        # Line starting with single plus (added line)
        plus_lines = plus_lines $0 "\n"
    }
    next
}
{
    # Other lines (outside hunks) - should not happen in normal git diff
    if (in_file) {
        file_header = file_header $0 "\n"
    } else {
        print
        has_output = 1
    }
}
END {
    # Process final hunk/file
    if (in_hunk) {
        if (!is_generated_metadata_only_hunk(minus_lines, plus_lines)) {
            if (in_file) {
                printf "%s", file_header
            }
            printf "%s", hunk_lines
            has_output = 1
        }
    }
    # Note: We do not exit with error code here - let the caller decide
    # what to do when all output is filtered
}
function is_generated_metadata_only_hunk(minus_lines, plus_lines) {
    # If no changes, not a metadata-only hunk
    if (minus_lines == "" && plus_lines == "") {
        return 0
    }
    # Split into arrays
    n_minus = split(minus_lines, minus_arr, /\n/)
    n_plus = split(plus_lines, plus_arr, /\n/)
    # Must have equal number of minus and plus lines (paired changes)
    if (n_minus != n_plus) {
        return 0
    }
    # Check each pair
    for (i = 1; i < n_minus; i++) {
        minus_line = minus_arr[i]
        plus_line = plus_arr[i]
        if (minus_line == "" && plus_line == "") continue
        # Remove the leading - or +
        gsub(/^-/, "", minus_line)
        gsub(/^\+/, "", plus_line)
        # Check if this is expected generated metadata drift.
        if (!is_expected_metadata_pair(minus_line, plus_line)) {
            return 0
        }
    }
    return 1
}
function is_expected_metadata_pair(minus_line, plus_line) {
    return is_generated_metadata_pair(minus_line, plus_line) || is_spdx_copyright_pair(minus_line, plus_line)
}
function is_generated_metadata_pair(minus_line, plus_line) {
    # Check if both lines are generated "across versions" metadata lines.
    if (minus_line !~ /^# This code was automatically generated across versions from .*generator version /) {
        return 0
    }
    if (plus_line !~ /^# This code was automatically generated across versions from .*generator version /) {
        return 0
    }
    return 1
}
function is_spdx_copyright_pair(minus_line, plus_line) {
    if (minus_line !~ /^# SPDX-FileCopyrightText: /) {
        return 0
    }
    if (plus_line !~ /^# SPDX-FileCopyrightText: /) {
        return 0
    }
    return 1
}
'
