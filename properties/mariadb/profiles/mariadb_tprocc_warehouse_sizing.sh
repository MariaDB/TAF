#############################################################################
# MDEV39497 HammerDB‑TPROCC Warehouse Sizing Sweep
#
# URL: https://jira.mariadb.org/browse/MDEV-39497
# Created: Nov 2026
# Version: 3.0
#
# Purpose:
#   Determine optimal HammerDB TPROC‑C warehouse count for a given machine.
#
# Notes:
#   - Uses baseline profile only
#   - Overrides warehouse count dynamically
#   - Runs a single iteration per warehouse size
#   - Produces a clean scaling curve for AMD/Intel hardware testing
#   - Make changes needed for current host being used
#############################################################################

#!/bin/bash

# Deterministic CPU behavior for benchmarking
sudo cpupower frequency-set -g performance >/dev/null 2>&1
sudo cpupower frequency-set -u 2700MHz >/dev/null 2>&1
sudo cpupower frequency-set -d 2700MHz >/dev/null 2>&1

# Baseline profile
PROFILE="./profiles/mariadb_tprocc_profile_baseline.properties"

# MariaDB install directory (user sets externally or defaults)
INSTALL="${INSTALL:-/path/to/mariadb/install}"

# Warehouse counts to sweep
WAREHOUSE_COUNTS=(5 10 15 20 50 100 500 1000)

for wh in "${WAREHOUSE_COUNTS[@]}"; do
    echo "Running baseline with ${wh} warehouses..."
    perl taf.pl \
        --prop="${PROFILE}" \
        --db-software-install-dir="${INSTALL}" \
        --test-suite-properties="number_of_warehouses=${wh},taf.iterations=1" \
        > "warehouse_${wh}.out" 2>&1
    sleep 5
done

echo "Warehouse sizing sweep completed."
