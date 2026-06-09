#!/bin/bash
#===============================================================================
# MariaDBCommitBuilder.sh
# TAF-MariaDB-Build Version: 1.0
#
# Created: April 2026
# Last Modified: June 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2026 # MariaDB Foundation and Jonathan "jeb" Miller
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version                  2 or later of the License.
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
#     Build and optionally package a MariaDB server tree at a specific commit.
#     This script checks out the requested commit, configures a clean build
#     directory, compiles the server, and (unless --no-package is used)
#     produces a reproducible tarball suitable for downstream TAF install and
#     performance testing steps.
#
# SCOPE OF THIS SCRIPT:
#     - Fetch and checkout the requested commit from the source tree.
#     - Create isolated build directories per commit.
#     - Run CMake with deterministic build options.
#     - Build the server with all available CPU cores.
#     - Optionally package the resulting installation directory.
#
# NOTES:
#     This script assumes a POSIX shell environment and a local source tree
#     located under ~/mariadb_src/server. Any change to directory layout,
#     build flags, or packaging requirements must be reflected in this header
#     and in the TAF manual.
#===============================================================================

set -euo pipefail

show_help() {
  echo "Usage: $0 <commit-hash> [base-dir] [src-dir] [--no-package]"
  echo
  echo "Arguments:"
  echo "  commit-hash     Required. Git commit to build."
  echo "  base-dir        Optional. Default: ~/mariadb_builds"
  echo "  src-dir         Optional. Default: ~/mariadb_src/server"
  echo
  echo "Flags:"
  echo "  --no-package    Build only. Skip tarball creation."
  echo "  --help          Show this help message."
  exit 0
}

# Parse flags early
NO_PACKAGE=0
for arg in "$@"; do
  case "$arg" in
    --help)
      show_help
      ;;
    --no-package)
      NO_PACKAGE=1
      ;;
  esac
done

# Validate argument count (1–3 positional args allowed)
POS_ARGS=()
for arg in "$@"; do
  [[ "$arg" == --* ]] || POS_ARGS+=("$arg")
done

if [ ${#POS_ARGS[@]} -lt 1 ] || [ ${#POS_ARGS[@]} -gt 3 ]; then
  echo "Usage: $0 <commit-hash> [base-dir] [src-dir] [--no-package]"
  exit 1
fi

COMMIT="${POS_ARGS[0]}"
BASE_DIR="${POS_ARGS[1]:-$HOME/mariadb_builds}"
SRC_DIR="${POS_ARGS[2]:-$HOME/mariadb_src/server}"

BUILD_DIR="$BASE_DIR/build-$COMMIT"
INSTALL_DIR="$BASE_DIR/install-$COMMIT"
TARBALL="$BASE_DIR/mariadb-$COMMIT.tar.gz"

echo "=== Checking out commit $COMMIT ==="
cd "$SRC_DIR"
git fetch --all --quiet
git checkout "$COMMIT"

# Clean stale CMake state if present
rm -f CMakeCache.txt
rm -rf CMakeFiles/

echo "=== Cleaning old build directory ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== Running CMake ==="
cmake "$SRC_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DWITH_SSL=system \
  -DWITH_ZLIB=system \
  -DWITH_PCRE=system \
  -DWITH_UNIT_TESTS=OFF

echo "=== Building ==="
make -j"$(nproc)"

echo "=== Installing ==="
make install

if [ "$NO_PACKAGE" -eq 0 ]; then
  echo "=== Packaging ==="
  cd "$BASE_DIR"
  tar -czf "$TARBALL" "install-$COMMIT"
  echo "Tarball:          $TARBALL"
else
  echo "=== Packaging skipped (--no-package) ==="
fi

echo "=== DONE ==="
echo "Install directory: $INSTALL_DIR"
