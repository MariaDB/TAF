####################################################
# MariaDB Foundation – Performance Regression Test Script
# MDEV-37992: select with large IN-list has excessive mutex contention
# https://jira.mariadb.org/browse/MDEV-37992
#
# This script is part of the MariaDB Foundation's reproducible
# performance regression testing framework. It automates running
# the MDEV-37992 workload across multiple MariaDB versions under
# deterministic CPU conditions using TAF.
#
# Purpose: Captures the TAF parameters for running the sysbench points-covered
# workload used to investigate the version-specific PK lookup regression in
# MDEV-37992. This test case exists thanks to Mark Callaghan, who identified
# the workload pattern and its cross-version performance impact.
#
# Modify the variables below to adapt paths or versions for your environment.
####################################################

#!/bin/bash

# Execute from TAF main directory: /home/jeb/taf-perl

PROP="/home/jeb/taf-perl/properties/mariadb/MDEV37992.properties"
OUT="mdev37992.out"
INSTALL_DIR="/home/jeb/taf-perl/database_software_installs"

# Deterministic CPU behavior
sudo cpupower frequency-set -g performance >/dev/null 2>&1
sudo cpupower frequency-set -d 2100MHz >/dev/null 2>&1
sudo cpupower frequency-set -u 2100MHz >/dev/null 2>&1
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null 2>&1

###############################################
# MariaDB 11.8
###############################################

perl taf.pl \
  --properties=$PROP \
  --test-case-tag=MDEV33966_11.8_PARENT_CACHED \
  --db-software-install-dir=$INSTALL_DIR/mariadb-14362356d14 > $OUT 2>&1
sleep 5

perl taf.pl \
  --properties=$PROP \
  --test-case-tag=MDEV33966_11.8_PATCH_CACHED \
  --db-software-install-dir=$INSTALL_DIR/mariadb-db94f391be4e >> $OUT 2>&1
sleep 5


###############################################
# MariaDB 12
###############################################

perl taf.pl \
  --properties=$PROP \
  --test-case-tag=MDEV33966_12.3_PARENT_CACHED \
  --db-software-install-dir=$INSTALL_DIR/mariadb-5981efcecd8 >> $OUT 2>&1
sleep 5

perl taf.pl \
  --properties=$PROP \
  --test-case-tag=MDEV33966_12.3_PATCH_CACHED \
  --db-software-install-dir=$INSTALL_DIR/mariadb-4083fbef83 >> $OUT 2>&1
sleep 5


###############################################
# MariaDB 13
###############################################

perl taf.pl \
  --properties=$PROP \
  --test-case-tag=MDEV33966_13.1_PARENT_CACHED \
  --db-software-install-dir=$INSTALL_DIR/mariadb-d0661d9bb8c >> $OUT 2>&1
sleep 5

perl taf.pl \
  --properties=$PROP \
  --test-case-tag=MDEV33966_13.1_PATCH_CACHED \
  --db-software-install-dir=$INSTALL_DIR/mariadb-5ab51d6248 >> $OUT 2>&1