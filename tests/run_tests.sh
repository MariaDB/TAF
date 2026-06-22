#!/usr/bin/env bash
# =============================================================================
# run_tests.sh — Runs the complete TAF PostgreSQL test suite
#
# Usage:
#   bash tests/run_tests.sh [pytest arguments...]
#
# Examples:
#   bash tests/run_tests.sh                        # all tests
#   bash tests/run_tests.sh -v                     # verbose
#   bash tests/run_tests.sh -v -k TestL5            # L5 only
#   bash tests/run_tests.sh --co -q                # list tests only
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

    # 3. Look for Percona tarball (default installation method)
    if [[ -x "/opt/pgdistro/percona-postgresql16/bin/postgres" ]]; then
        echo "/opt/pgdistro/percona-postgresql16"
        return
    fi

    # 4. PGDG RPM
    for dir in /usr/pgsql-16 /usr/pgsql-15 /usr/pgsql-14; do
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
# Prerequisites check
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[TEST]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

cd "${TAF_ROOT}"

PG_INSTALL="$(detect_pg_install)"
if [[ -z "$PG_INSTALL" ]]; then
    error "PostgreSQL not found. Run first: sudo bash tests/setup_almalinux10.sh"
fi
export TAF_PG_INSTALL_DIR="${PG_INSTALL}"
export TAF_PG_PORT="${TAF_PG_PORT:-5433}"

# Add PG bin and lib to PATH/LD_LIBRARY_PATH
export PATH="${PG_INSTALL}/bin:${PATH}"
PG_LIB="${PG_INSTALL}/lib"
if [[ -d "${PG_LIB}" ]]; then
    export LD_LIBRARY_PATH="${PG_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

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
info "Sysbench:    ${TAF_ROOT}/client_source/sysbench-lua/sysbench"
[[ -n "${TAF_MARIADB_DIR:-}" ]] && info "MariaDB:     ${TAF_MARIADB_DIR} (L6 enabled)"

# Sysbench binary check
SYSBENCH_BIN="${TAF_ROOT}/client_source/sysbench-lua/sysbench"
if [[ ! -x "${SYSBENCH_BIN}" ]]; then
    warn "Sysbench not found (${SYSBENCH_BIN})"
    warn "L4/L5 tests will be skipped. Run setup_almalinux10.sh to build."
fi

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

PYTEST_ARGS=("tests/test_taf_postgresql.py")

# Default verbose if no arguments provided
if [[ $# -eq 0 ]]; then
    PYTEST_ARGS+=("-v" "--tb=short")
else
    PYTEST_ARGS+=("$@")
fi

python3 -m pytest "${PYTEST_ARGS[@]}"
