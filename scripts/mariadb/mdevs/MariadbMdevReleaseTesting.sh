#===============================================================================
# MariadbMdevReleaseTesting.sh
# TAF-MariaDB-Tools Version: 1.1
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2026
# MariaDB Foundation and Jonathan "jeb" Miller
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 or later of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
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
#     Execute MDEV Performance Change Cases for a single MariaDB release
#     using the active TAF installation. This script is intended for
#     release validation, not multi-version matrix testing.
#
# SCOPE OF THIS SCRIPT:
#     - Run one or more MDEV performance change cases against the release
#       version specified in the user configuration section.
#     - Automatically locate the TAF root and the MDEV properties directory.
#     - Construct deterministic test-case-tags of the form:
#           RELEASE_<version>_<MDEVxxxx>
#     - Rely on the active MariaDB installation; no installation or
#       version switching is performed.
#
# USER ACTION REQUIRED BEFORE RUNNING:
#     - Ensure the release version under test is already installed and
#       marked "active" in TAF.
#     - Edit RELEASE_VERSION in the user configuration section.
#     - Edit TEST_CASES to include the desired MDEV properties files.
#     - (Optional) Uncomment and adjust CPU pinning commands if deterministic
#       CPU frequency is required for reproducibility. Hosts vary widely;
#       adjust min/max frequencies to match your hardware.
#     - Ensure the host has sufficient memory for the selected test cases.
#       Some MDEV cases require buffer pools up to ~90GB.
#
# NOTES:
#     This script is intentionally simple. It does not install software,
#     switch versions, or perform multi-version comparison. Those tasks
#     belong to TAF's general test drivers and automation pipeline.
#===============================================================================
#!/bin/bash
set -e

# ----------------------------------------
# User configuration
# ----------------------------------------

# The release version under test.
# Assumption: this version is already installed and marked "active" in TAF.
RELEASE_VERSION="13.0.2"

# List of MDEV performance change cases to run.
TEST_CASES=(
    "MDEV32750_AHI_ON.properties"
    "MDEV32750_AHI_OFF.properties"
)

# ----------------------------------------
# Optional deterministic CPU behavior
# ----------------------------------------
# Uncomment and adjust for your host if you want pinned CPU frequency.
# This is NOT required for correctness, only for reproducibility.
# sudo cpupower frequency-set -g performance >/dev/null 2>&1
# sudo cpupower frequency-set -u 2700MHz >/dev/null 2>&1
# sudo cpupower frequency-set -d 2700MHz >/dev/null 2>&1


# -------------------------------
# Auto-detect TAF root
# -------------------------------

# ReleaseTesting.sh lives in taf/scripts/mariadb/mdevs/
# So TAF root is three levels up.
TAF_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

# Setup a log for output
LOG_DIR="$TAF_ROOT/logs"
LOG_FILE="$LOG_DIR/${RELEASE_VERSION}_release.log"

# Properties directory
PROPS_DIR="$TAF_ROOT/properties/mariadb/mdevs"

# -------------------------------
# Execution loop
# -------------------------------
{
    cd "$TAF_ROOT"

    for case in "${TEST_CASES[@]}"; do

        # Strip .properties to get the MDEV tag portion
        CASE_TAG="${case%%.properties}"

        # Construct the test-case-tag
        TEST_CASE_TAG="RELEASE_${RELEASE_VERSION}_${CASE_TAG}"

        echo "Running $case on active install ($RELEASE_VERSION) with tag $TEST_CASE_TAG"

        perl "$TAF_ROOT/taf.pl" \
            --properties="$PROPS_DIR/$case" \
            --test-case-tag="$TEST_CASE_TAG"
    done
} 2>&1 | tee "$LOG_FILE"