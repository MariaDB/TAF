#!/bin/bash
#############################################################################
# RenameResultsTestCaseTag.sh
#
# Created: 2026
# Last Modified: September 2026
# Version 4.0
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026
# MariaDB Foundation and Jonathan "jeb" Miller
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 or later of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Automatically rename archived TAF result directories and their
#     associated report files based on the test_case_tag value found in
#     each result’s primary text report. This ensures consistent naming
#     across raw, text, CSV, and JSON outputs for downstream processing,
#     comparison, and archival.
#
# ARCHITECTURAL ROLE:
#     - Acts as a post-processing utility for TAF result archives.
#     - Normalizes directory and file names using the authoritative
#       test_case_tag value extracted from the report.
#     - Ensures result bundles are consistently labeled for automated
#       ingestion by comparison tools and long-term storage.
#
# WHAT THIS SCRIPT DOES NOT DO:
#     - Does not modify report contents.
#     - Does not validate workload correctness or test semantics.
#     - Does not merge, analyze, or compare results.
#     - Does not infer missing tags or attempt recovery of malformed data.
#
# CONTRACT:
#     - Each target directory must contain a primary .txt report file.
#     - The report must contain a "test_case_tag:" line with a colon.
#     - The script must be executed from the scripts/ directory.
#     - A directory pattern (e.g., "hz-bench*") must be provided.
#     - All failures must be explicit; no silent renames or overwrites.
#
# GUARANTEES:
#     - Only the colon-form test_case_tag is used (never taf.test_case_tag=).
#     - Directory renames are atomic and collision-protected.
#     - Raw, text, CSV, and JSON files are renamed consistently.
#     - No existing files are overwritten.
#
# NOTES:
#     - This script is intentionally minimal; its sole responsibility is
#       to extract the tag and rename the directory and its report files.
#     - Any change to report structure or tag formatting must be reflected
#       here and in the TAF documentation.
#############################################################################

pattern="$1"

if [ -z "$pattern" ]; then
    echo "ERROR: You must pass a directory pattern, e.g.:"
    echo "  ./RenameResultsTestCaseTag.sh \"hz-bench*\""
    exit 1
fi

base="../archive"

for d in $base/$pattern; do
    [ -d "$d" ] || continue

    echo "Processing directory: $d"

    # Find the main .txt report (exclude raw.txt)
    txtfile=$(ls "$d"/*.txt 2>/dev/null | grep -v raw.txt | head -n 1)
    if [ -z "$txtfile" ]; then
        echo "  No .txt report found, skipping."
        continue
    fi

    # Extract test_case_tag value
    tag=$(grep -E "^test_case_tag:" "$txtfile" \
      | head -n 1 \
      | awk -F':' '{print $2}' \
      | xargs)

    if [ -z "$tag" ]; then
        echo "  No tag found in $txtfile, skipping."
        continue
    fi

    echo "  Found tag: $tag"

    # New directory name
    newdir="$base/$tag"

    # Avoid overwriting existing directory
    if [ -e "$newdir" ]; then
        echo "  ERROR: Directory $newdir already exists. Skipping."
        continue
    fi

    # Rename directory
    mv "$d" "$newdir"
    echo "  Renamed directory to: $newdir"

    # Rename files inside
    for f in "$newdir"/*; do
        basefile="${f##*/}"

        case "$basefile" in
            *.raw.txt) newfile="$newdir/$tag.raw.txt" ;;
            *.txt)     newfile="$newdir/$tag.txt" ;;
            *.csv)     newfile="$newdir/$tag.csv" ;;
            *.json)    newfile="$newdir/$tag.json" ;;
            *)         continue ;;
        esac

        # Avoid overwriting
        if [ -e "$newfile" ]; then
            echo "  ERROR: $newfile already exists. Skipping file rename."
            continue
        fi

        mv "$f" "$newfile"
        echo "  Renamed $basefile -> $(basename "$newfile")"
    done

    echo "  Done with $newdir"
    echo
done
