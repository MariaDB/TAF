#############################################################################
# MDEV39497 HammerDB TPROCC profiles Runner
#
# URL: https://jira.mariadb.org/browse/MDEV-39497
# Created: Nov 2026
# Version: 3.0
#
# Purpose:
#   Execute all MariaDB TPROC‑C benchmark profiles in a deterministic,
#   reproducible manner for hardware and software performance testing.
#
# Notes:
#   - Designed for repeated use across AMD/Intel platforms
#   - CPU frequency forced to deterministic mode
#   - Automatically iterates all normalized profile files
#   - Supports external MariaDB install directory via $INSTALL
#   - Make changes needed for host under test and layout
#############################################################################
#!/bin/bash

# Deterministic CPU behavior for benchmarking
sudo cpupower frequency-set -g performance >/dev/null 2>&1
sudo cpupower frequency-set -u 2700MHz >/dev/null 2>&1
sudo cpupower frequency-set -d 2700MHz >/dev/null 2>&1

# Directory containing your normalized profiles
PROFILE_DIR="./"

# MariaDB install directory (user sets this before running)
INSTALL="${INSTALL:-/path/to/taf-perl/database_software_install/mariadb/install}"

run_profile() {
    local file="$1"
    echo "Running profile: $file"
    perl taf.pl \
        --prop="${PROFILE_DIR}/${file}" \
        --db-software-install-dir="${INSTALL}" \
        > "run_${file}.out" 2>&1
    sleep 5
}

# Loop through all normalized profiles
for profile in ${PROFILE_DIR}/mariadb_tprocc_profile_*.properties; do
    base=$(basename "$profile")
    run_profile "$base"
done

echo "All profiles completed."
