#!/usr/bin/env bash
# =============================================================================
# run_tests.sh — Runs the complete TAF PostgreSQL test suite
#
# Usage:
#   bash framework_functional_tests/run_tests.sh [pytest arguments...]
#
# Examples:
#   bash framework_functional_tests/run_tests.sh                        # all tests
#   bash framework_functional_tests/run_tests.sh -v                     # verbose
#   bash framework_functional_tests/run_tests.sh -v -k TestL5            # L5 only
#   bash framework_functional_tests/run_tests.sh --co -q                # list tests only
#
# Env variables (override automatic detection):
#   TAF_PG_INSTALL_DIR   PostgreSQL installation directory
#   TAF_PG_PORT          port for TAF-managed PG (default: 5433)
#   TAF_MARIADB_DIR      (optional) for L6 MariaDB regression test
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAF_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# PostgreSQL installation detection
# ---------------------------------------------------------------------------
detect_pg_install() {
    # 1. Respect explicitly set variable
    if [[ -n "${TAF_PG_INSTALL_DIR:-}" ]]; then
        echo "${TAF_PG_INSTALL_DIR}"
        return
    fi

    # 2. Source .taf_pg_env if it exists (created by setup_almalinux10.sh)
    if [[ -f "${TAF_ROOT}/.taf_pg_env" ]]; then
        # shellcheck source=/dev/null
        source "${TAF_ROOT}/.taf_pg_env"
        if [[ -n "${TAF_PG_INSTALL_DIR:-}" ]]; then
            echo "${TAF_PG_INSTALL_DIR}"
            return
        fi
    fi

    # 3. TAF's own install location (setup_almalinux10.sh's --method=percona
    # installs via `perl taf.pl --db-software-install`, which always lands
    # here, not at a hardcoded /opt path).
    local found
    found=$(find "${TAF_ROOT}/database_software_installs" -mindepth 2 -maxdepth 4 \
        -type f -name postgres -path "*/bin/postgres" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        dirname "$(dirname "$found")"
        return
    fi

    # 4. PGDG RPM
    for dir in /usr/pgsql-18 /usr/pgsql-16 /usr/pgsql-15 /usr/pgsql-14; do
        if [[ -x "${dir}/bin/postgres" ]]; then
            echo "${dir}"
            return
        fi
    done

    # 5. AppStream / system PG
    if [[ -x "/usr/bin/postgres" ]]; then
        echo "/usr"
        return
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# MariaDB installation detection (optional -- only enables L6)
# ---------------------------------------------------------------------------
detect_mariadb_dir() {
    if [[ -n "${TAF_MARIADB_DIR:-}" ]]; then
        echo "${TAF_MARIADB_DIR}"
        return
    fi

    if [[ -f "${TAF_ROOT}/.taf_pg_env" ]]; then
        # shellcheck source=/dev/null
        source "${TAF_ROOT}/.taf_pg_env"
        if [[ -n "${TAF_MARIADB_DIR:-}" ]]; then
            echo "${TAF_MARIADB_DIR}"
            return
        fi
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[TEST]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

cd "${TAF_ROOT}"

PG_INSTALL="$(detect_pg_install)"
if [[ -z "$PG_INSTALL" ]]; then
    error "PostgreSQL not found. Run first: sudo bash framework_functional_tests/setup_almalinux10.sh"
fi
export TAF_PG_INSTALL_DIR="${PG_INSTALL}"
export TAF_PG_PORT="${TAF_PG_PORT:-5433}"

# MARIADB_DIR="$(detect_mariadb_dir)" also runs in a subshell, same as
# PG_INSTALL above -- re-export explicitly here or TAF_MARIADB_DIR from
# .taf_pg_env never reaches pytest and L6 silently self-skips even when
# setup_almalinux10.sh did install MariaDB.
MARIADB_DIR="$(detect_mariadb_dir)"
[[ -n "${MARIADB_DIR}" ]] && export TAF_MARIADB_DIR="${MARIADB_DIR}"

# Add PG's bin to PATH (for pg_config below and manual psql/pg_ctl use).
#
# Deliberately NOT exporting LD_LIBRARY_PATH here, unlike setup_almalinux10.sh's
# own /etc/profile.d snippet: TAF::DatabaseSoftwareInstalls::_SetLibraryPath
# already sets it internally, scoped to taf.pl's own subprocess calls, right
# when a command actually needs it -- exporting it globally in *this* shell
# instead poisons the python3 process about to run pytest itself. On a
# Percona-bundled Python (VzLinux/Virtuozzo: /usr/bin/python3 wraps
# /opt/percona-python3), the mere presence of PostgreSQL's lib/ ahead of the
# system libs in LD_LIBRARY_PATH is enough to make Python's own dynamic
# linking pick up an incompatible shared library and crash before even
# importing `encodings` ("ModuleNotFoundError: No module named 'encodings'"),
# which looks exactly like "pytest not found" below but has nothing to do
# with pytest.
export PATH="${PG_INSTALL}/bin:${PATH}"

# Virtuozzo/VzLinux: add system site-packages to Percona Python
PERCONA_PY_SITEPKGS="/opt/percona-python3/lib/python3.12/site-packages"
if [[ -d "$PERCONA_PY_SITEPKGS" ]]; then
    PTH_FILE="${PERCONA_PY_SITEPKGS}/system-sitepackages.pth"
    if [[ ! -f "$PTH_FILE" ]]; then
        echo "/usr/lib/python3.12/site-packages"  > "$PTH_FILE"
        echo "/usr/lib64/python3.12/site-packages" >> "$PTH_FILE"
    fi
fi

info "PostgreSQL:  ${PG_INSTALL} ($(pg_config --version 2>/dev/null || echo 'version unknown'))"
info "Port:        ${TAF_PG_PORT}"
[[ -n "${TAF_MARIADB_DIR:-}" ]] && info "MariaDB:     ${TAF_MARIADB_DIR} (L6 enabled)"

# Sysbench is built by the test suite itself (each of L4/L5/L6/L7 rebuilds it
# via `taf.pl --action=*-build-client-run-tests`, one driver per invocation --
# cmake links WITH_PGSQL xor WITH_MYSQL, never both), not by this script.
# Nothing to check for here; the client_source/sysbench-lua/sysbench binary
# simply won't exist yet on a fresh checkout, and that's expected.

# Verify pytest
python3 -m pytest --version >/dev/null 2>&1 || \
    error "pytest not found. Run: pip3 install pytest"

# ---------------------------------------------------------------------------
# Running tests
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  TAF PostgreSQL Integration Tests${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
echo ""

PYTEST_ARGS=("framework_functional_tests/test_taf_postgresql.py")

# Default verbose if no arguments provided
if [[ $# -eq 0 ]]; then
    PYTEST_ARGS+=("-v" "--tb=short")
else
    PYTEST_ARGS+=("$@")
fi

python3 -m pytest "${PYTEST_ARGS[@]}"
