#!/usr/bin/env bash
# =============================================================================
# setup_almalinux10.sh — Prerequisites for TAF PostgreSQL tests
#
# Target: RHEL/AlmaLinux/Virtuozzo 8–10 (x86_64, aarch64)
# Usage: sudo bash tests/setup_almalinux10.sh [--method=percona|pgdg|appstream]
#
# PostgreSQL installation methods (--method):
#   percona   (default) — tarball from downloads.percona.com
#                         https://docs.percona.com/postgresql/16/tarball.html
#   pgdg      — RPM from pgdg.postgresql.org
#   appstream — system postgresql from dnf
#
# After completion:
#   - PostgreSQL 16 available in $PG_INSTALL_DIR
#   - Python 3 + pytest installed
#   - Build tools for sysbench ready
#   - Env saved to .taf_pg_env (source before tests)
#
# Env variables (can be overridden before pytest):
#   TAF_PG_INSTALL_DIR  (set automatically)
#   TAF_PG_PORT         (default: 5433)
#   TAF_MARIADB_DIR     (optional, for L6 regression test)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors and helper functions
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

[[ $EUID -eq 0 ]] || error "Script must be run as root (sudo bash $0)"

# ---------------------------------------------------------------------------
# Parametry
# ---------------------------------------------------------------------------
METHOD="percona"
for arg in "$@"; do
    case "$arg" in
        --method=percona)   METHOD=percona   ;;
        --method=pgdg)      METHOD=pgdg      ;;
        --method=appstream) METHOD=appstream ;;
        --help|-h)
            echo "Usage: sudo bash $0 [--method=percona|pgdg|appstream]"
            echo "  percona    (default) Tarball from downloads.percona.com"
            echo "  pgdg       RPM from pgdg.postgresql.org"
            echo "  appstream  System postgresql from dnf"
            exit 0 ;;
        *) warn "Unknown parameter: $arg" ;;
    esac
done

ARCH=$(uname -m)
TAF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info "PG installation method: ${CYAN}${METHOD}${NC}"
info "Architecture:           ${ARCH}"
info "TAF directory:          ${TAF_DIR}"

# ---------------------------------------------------------------------------
# 1. BASE DEPENDENCIES
# ---------------------------------------------------------------------------
step "Installing base dependencies"
dnf install -y epel-release 2>/dev/null || true
dnf install -y \
    gcc gcc-c++ make cmake automake libtool pkg-config \
    perl perl-devel \
    python3 python3-pip \
    git wget curl tar \
    libaio-devel readline-devel \
    openssl openssl-devel \
    acl

# ---------------------------------------------------------------------------
# 2. POSTGRESQL — according to chosen method
# ---------------------------------------------------------------------------
step "Installing PostgreSQL 16 (method: ${METHOD})"

PG_INSTALL_DIR=""
LIBPQ_INCDIR=""
LIBPQ_LIBDIR=""

# ─── 2a. PERCONA TARBALL (default) ─────────────────────────────────────────
# Dokumentace: https://docs.percona.com/postgresql/16/tarball.html
install_percona_tarball() {
    local VERSION="16.14"
    local INSTALL_BASE="/opt/pgdistro"
    local PG_SUBDIR="percona-postgresql16"

    # Detect OpenSSL version → choose tarball variant
    local OPENSSL_VER
    OPENSSL_VER=$(openssl version | awk '{print $2}')
    local SSL_TAG
    case "${OPENSSL_VER%%.*}" in
        1) SSL_TAG="ssl1" ;;
        3) SSL_TAG="ssl3" ;;
        *) SSL_TAG="ssl3"; warn "Unknown OpenSSL version ${OPENSSL_VER}, trying ssl3" ;;
    esac

    # Map architecture to tarball name
    local TARARCH
    case "$ARCH" in
        x86_64)  TARARCH="linux-x86_64" ;;
        aarch64) TARARCH="linux-aarch64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac

    local TARBALL="percona-postgresql-${VERSION}-${SSL_TAG}-${TARARCH}.tar.gz"
    local URL="https://downloads.percona.com/downloads/postgresql-distribution-16/${VERSION}/binary/tarball/${TARBALL}"

    info "Tarball: ${TARBALL}"
    info "URL:     ${URL}"

    # Skip if binary already exists
    if [[ -x "${INSTALL_BASE}/${PG_SUBDIR}/bin/postgres" ]]; then
        info "Percona PostgreSQL 16 already installed in ${INSTALL_BASE}/${PG_SUBDIR}"
        PG_INSTALL_DIR="${INSTALL_BASE}/${PG_SUBDIR}"
        return 0
    fi

    mkdir -p "${INSTALL_BASE}"

    local TMPTAR="/tmp/${TARBALL}"
    if [[ ! -f "$TMPTAR" ]]; then
        info "Downloading tarball..."
        wget -q --show-progress -O "$TMPTAR" "$URL" 2>/dev/null || \
        wget -O "$TMPTAR" "$URL" || \
        curl -fL -o "$TMPTAR" "$URL"
    else
        info "Tarball already downloaded: ${TMPTAR}"
    fi

    info "Extracting to ${INSTALL_BASE}/..."
    tar -xf "$TMPTAR" -C "${INSTALL_BASE}/"

    # Move Perl/Python/Tcl modules one level up (per documentation)
    for mod in percona-perl percona-python3 percona-tcl; do
        if [[ -d "${INSTALL_BASE}/${mod}" ]] && [[ ! -d "/opt/${mod}" ]]; then
            info "Moving ${mod} -> /opt/${mod}"
            mv "${INSTALL_BASE}/${mod}" "/opt/${mod}"
        fi
    done

    PG_INSTALL_DIR="${INSTALL_BASE}/${PG_SUBDIR}"

    # LD_LIBRARY_PATH for bundled libraries
    local PG_LIB="${PG_INSTALL_DIR}/lib"
    if [[ -d "$PG_LIB" ]]; then
        export LD_LIBRARY_PATH="${PG_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        cat > /etc/profile.d/percona-pg16.sh <<PROFILE
# Percona PostgreSQL 16 — added by setup_almalinux10.sh
export PATH="${PG_INSTALL_DIR}/bin:\$PATH"
export LD_LIBRARY_PATH="${PG_LIB}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
PROFILE
        info "Profile written: /etc/profile.d/percona-pg16.sh"
    fi
}

# ─── 2b. PGDG RPM ──────────────────────────────────────────────────────────
install_pgdg_rpm() {
    local PG_REPO_RPM="https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    if dnf install -y "$PG_REPO_RPM" 2>/dev/null; then
        info "PGDG repository added"
        dnf -qy module disable postgresql 2>/dev/null || true
        dnf install -y postgresql16-server postgresql16-devel postgresql16
        PG_INSTALL_DIR="/usr/pgsql-16"
    else
        warn "PGDG EL10 repo unavailable, falling back to AppStream"
        install_appstream
    fi
}

# ─── 2c. APPSTREAM ─────────────────────────────────────────────────────────
install_appstream() {
    dnf install -y postgresql-server postgresql-devel
    PG_INSTALL_DIR="/usr"
    warn "PostgreSQL installed from AppStream into ${PG_INSTALL_DIR}"
}

case "$METHOD" in
    percona)   install_percona_tarball ;;
    pgdg)      install_pgdg_rpm        ;;
    appstream) install_appstream       ;;
esac

# ---------------------------------------------------------------------------
# 3. VERIFY POSTGRESQL BINARIES
# ---------------------------------------------------------------------------
step "Verifying PostgreSQL binaries"
PG_BIN="${PG_INSTALL_DIR}/bin"
MISSING=0
for BIN in postgres pg_ctl psql initdb pg_isready pg_config; do
    if [[ -x "${PG_BIN}/${BIN}" ]]; then
        info "  ✓ ${PG_BIN}/${BIN}"
    else
        warn "  ✗ ${PG_BIN}/${BIN} not found"
        MISSING=$((MISSING + 1))
    fi
done
[[ $MISSING -eq 0 ]] || error "Missing binaries — check installation in ${PG_INSTALL_DIR}"

info "PostgreSQL version: $("${PG_BIN}/pg_config" --version)"
LIBPQ_INCDIR=$("${PG_BIN}/pg_config" --includedir)
LIBPQ_LIBDIR=$("${PG_BIN}/pg_config" --libdir)
info "includedir: ${LIBPQ_INCDIR}"
info "libdir:     ${LIBPQ_LIBDIR}"

# ---------------------------------------------------------------------------
# 4. LIBPQ HEADERS FOR SYSBENCH
# ---------------------------------------------------------------------------
step "Checking libpq-fe.h for sysbench"
if [[ -f "${LIBPQ_INCDIR}/libpq-fe.h" ]]; then
    info "libpq-fe.h found: ${LIBPQ_INCDIR}/libpq-fe.h"
else
    warn "libpq-fe.h not found, trying system packages..."
    dnf install -y postgresql-devel libpq-devel 2>/dev/null || \
    dnf install -y postgresql16-devel 2>/dev/null || \
        warn "libpq-devel unavailable — sysbench build may fail"
fi

# Export for ./configure sysbench
export PKG_CONFIG_PATH="${LIBPQ_LIBDIR}/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="-I${LIBPQ_INCDIR}"
export LDFLAGS="-L${LIBPQ_LIBDIR} -Wl,-rpath,${LIBPQ_LIBDIR}"

# ---------------------------------------------------------------------------
# 5. PYTHON + PYTEST
# ---------------------------------------------------------------------------
step "Installing pytest"

# Virtuozzo/VzLinux Python3 uses Percona Python as stdlib
# (/usr/bin/python3 is a small wrapper, sys.prefix=/opt/percona-python3).
# Pytest must be in /opt/percona-python3/lib/python3.12/site-packages/
# or accessible via a .pth file. System pip3/ssl may not work
# (Percona Python requires OpenSSL 3.3+, system has 3.2.x).

PERCONA_PY_SITEPKGS="/opt/percona-python3/lib/python3.12/site-packages"
SYS_SITEPKGS="/usr/lib/python3.12/site-packages"

# Strategy 1: add system site-packages to Percona Python via .pth
if [[ -d "$PERCONA_PY_SITEPKGS" ]]; then
    PTH_FILE="${PERCONA_PY_SITEPKGS}/system-sitepackages.pth"
    if [[ ! -f "$PTH_FILE" ]]; then
        info "Adding system site-packages to Percona Python path..."
        echo "/usr/lib/python3.12/site-packages"  > "$PTH_FILE"
        echo "/usr/lib64/python3.12/site-packages" >> "$PTH_FILE"
    fi
fi

# Strategy 2: install pytest via dnf (preferred for Virtuozzo)
PYTEST_INSTALLED=0
if python3 -m pytest --version >/dev/null 2>&1; then
    PYTEST_INSTALLED=1
elif dnf install -y python3-pytest >/dev/null 2>&1; then
    PYTEST_INSTALLED=1
else
    # Strategy 3: copy pytest from /usr/local (installed by earlier pip)
    if [[ -d "/usr/local/lib/python3.12/site-packages/pytest" ]]; then
        for pkg in pytest _pytest pluggy iniconfig py.py; do
            src="/usr/local/lib/python3.12/site-packages/${pkg}"
            [[ -e "$src" ]] && cp -r "$src" "${PERCONA_PY_SITEPKGS}/" 2>/dev/null || true
        done
        for dist in /usr/local/lib/python3.12/site-packages/{pytest,pluggy,iniconfig}-*.dist-info; do
            [[ -e "$dist" ]] && cp -r "$dist" "${PERCONA_PY_SITEPKGS}/" 2>/dev/null || true
        done
        python3 -m pytest --version >/dev/null 2>&1 && PYTEST_INSTALLED=1
    fi
fi

[[ $PYTEST_INSTALLED -eq 1 ]] || error "Failed to install pytest"
info "pytest: $(python3 -m pytest --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# 6. SYSBENCH — clone and build if missing
# ---------------------------------------------------------------------------
step "Sysbench"
SYSBENCH_SRC="${TAF_DIR}/client_source/sysbench-lua"

# Correct state: sysbench is a symlink to src/sysbench (locally built binary)
SYSBENCH_OK=0
if [[ -L "${SYSBENCH_SRC}/sysbench" ]] && [[ "$(readlink "${SYSBENCH_SRC}/sysbench")" == "src/sysbench" ]] && [[ -x "${SYSBENCH_SRC}/src/sysbench" ]]; then
    SYSBENCH_OK=1
    info "Sysbench already built: $("${SYSBENCH_SRC}/sysbench" --version)"
elif [[ -x "${SYSBENCH_SRC}/sysbench" ]] && [[ ! -L "${SYSBENCH_SRC}/sysbench" ]]; then
    warn "sysbench is a binary (not a symlink) — may have been rsync'd from another host"
    warn "Rebuilding from source for correct architecture and libpq..."
fi
if [[ $SYSBENCH_OK -eq 0 ]]; then
    if [[ ! -f "${SYSBENCH_SRC}/configure.ac" ]]; then
        info "Cloning sysbench..."
        mkdir -p "${TAF_DIR}/client_source"
        git clone --depth=1 https://github.com/akopytov/sysbench "${SYSBENCH_SRC}"
    fi

    info "Building sysbench with pgsql support..."
    cd "${SYSBENCH_SRC}"

    ./autogen.sh
    ./configure --without-mysql --with-pgsql \
        --with-pgsql-includes="${LIBPQ_INCDIR}" \
        --with-pgsql-libs="${LIBPQ_LIBDIR}"
    make -j"$(nproc)"

    if [[ -f "src/sysbench" ]]; then
        # Ensure correct symlink — remove any old binary (e.g. rsync'd from another host)
        if [[ ! -L "sysbench" ]] || [[ "$(readlink sysbench)" != "src/sysbench" ]]; then
            rm -f sysbench
            ln -sf src/sysbench sysbench
            info "Symlink: sysbench-lua/sysbench -> src/sysbench"
        fi
    fi

    cd "${TAF_DIR}"
    info "Sysbench: $("${SYSBENCH_SRC}/sysbench" --version)"
fi

# ---------------------------------------------------------------------------
# 7. /root PERMISSIONS (postgres user needs traverse into TAF dir)
# ---------------------------------------------------------------------------
step "Directory permissions"
ROOT_PERM=$(stat -c '%a' /root)
if [[ "${ROOT_PERM: -1}" == "0" ]]; then
    info "Adding o+x on /root"
    chmod o+x /root
fi
info "/root: $(stat -c '%a' /root)"

# ---------------------------------------------------------------------------
# 8. SAVING ENV VARIABLES
# ---------------------------------------------------------------------------
step "Saving environment"
ENV_FILE="${TAF_DIR}/.taf_pg_env"
cat > "${ENV_FILE}" <<ENV
# Generated by setup_almalinux10.sh (method: ${METHOD})
# Source before running tests:  source .taf_pg_env
export TAF_PG_INSTALL_DIR="${PG_INSTALL_DIR}"
export TAF_PG_PORT="5433"
export LD_LIBRARY_PATH="${PG_INSTALL_DIR}/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
ENV
info "Env saved: ${ENV_FILE}"

# ---------------------------------------------------------------------------
# RESULT
# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════"
echo -e "${GREEN}Prerequisites ready.${NC}  PG: ${PG_INSTALL_DIR}"
echo ""
echo "Running tests:"
echo "  cd ${TAF_DIR}"
echo "  bash tests/run_tests.sh"
echo ""
echo "or manually:"
echo "  source ${ENV_FILE}"
echo "  python3 -m pytest tests/test_taf_postgresql.py -v"
echo ""
echo "Optionally L6 (MariaDB):"
echo "  export TAF_MARIADB_DIR=/path/to/mariadb-install"
echo "═══════════════════════════════════════════════════════════"
