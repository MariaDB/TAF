#!/usr/bin/env bash
# =============================================================================
# setup_almalinux10.sh — Prerequisites for TAF PostgreSQL tests
#
# Target: RHEL/AlmaLinux/Virtuozzo 8–10 (x86_64, aarch64)
# Usage: sudo bash tests/setup_almalinux10.sh [--method=percona|pgdg|appstream]
#
# PostgreSQL installation methods (--method):
#   percona   (default) — tarball from downloads.percona.com
#                         https://docs.percona.com/postgresql/18/tarball.html
#   pgdg      — RPM from pgdg.postgresql.org
#   appstream — system postgresql from dnf (AlmaLinux 10 AppStream ships a
#               versioned postgresql18 package alongside the unversioned
#               postgresql (16) one; --allowerasing swaps 16 out for 18)
#
# EXPECTED_PG_VERSION (below) is pinned to 18.4 -- the current stable
# PostgreSQL release as of 2026-07 (https://www.postgresql.org/docs/release/18.4/,
# released 2026-05-14). Update it here when a newer release ships. All three
# methods are verified against this after install; a mismatch is a hard error
# (see step 3b) rather than a silent partial upgrade.
#
# After completion:
#   - PostgreSQL 18.4 available in $PG_INSTALL_DIR
#   - Python 3 + pytest installed
#   - Build tools for sysbench ready
#   - Env saved to .taf_pg_env (source before tests)
#
# Env variables (can be overridden before pytest):
#   TAF_PG_INSTALL_DIR    (set automatically)
#   TAF_PG_PORT           (default: 5433)
#   TAF_MARIADB_DIR       (optional, for L6 regression test)
#   PERCONA_LOCAL_ARCHIVE (--method=percona only) path to an already-downloaded
#                         percona-postgresql-*.tar.gz; skips the
#                         downloads.percona.com fetch. Set by taf_manage.py
#                         --PERCONA_ARCHIVE_LOCAL, which SCPs it here once from
#                         the control machine instead of every guest fetching
#                         it independently.
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
# Expected PostgreSQL version (pre-test gate, step 3b)
# ---------------------------------------------------------------------------
# Pinned to the current stable PostgreSQL release. Verified 2026-07 against
# https://www.postgresql.org/docs/release/18.4/ (released 2026-05-14).
# Update this when a newer release ships -- installs of any --method that
# don't produce this exact version fail hard rather than silently running
# benchmarks against an unintended/outdated PostgreSQL version.
EXPECTED_PG_VERSION="18.4"

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
# 1b. "postgres" OS user/group
# ---------------------------------------------------------------------------
# The appstream/pgdg RPM packages create this via their own %pre scriptlet,
# but --method=percona just extracts a tarball -- nothing ever creates it.
# postgres.pm's new() constructor requires an OS user literally named
# "postgres" to drop root privileges before running initdb (PostgreSQL
# refuses `initdb`/`postgres` as root unconditionally); without it, initdb
# runs as root and fails with "initdb: error: cannot be run as root" on
# every single host. Mirrors the standard RHEL/Fedora postgresql-server RPM
# %pre scriptlet (group+user, system account, home /var/lib/pgsql) so the
# result is identical regardless of --method, and running this unconditionally
# for all three methods is a no-op if the RPM path already created it.
step "Ensuring OS user/group 'postgres' exists"
getent group postgres >/dev/null || groupadd -r postgres
if getent passwd postgres >/dev/null; then
    info "OS user 'postgres' already exists"
else
    mkdir -p /var/lib/pgsql
    useradd -r -g postgres -d /var/lib/pgsql -s /bin/bash -c "PostgreSQL Server" postgres
    chown postgres:postgres /var/lib/pgsql
    info "OS user 'postgres' created (system account, home /var/lib/pgsql)"
fi

# ---------------------------------------------------------------------------
# 2. POSTGRESQL — according to chosen method
# ---------------------------------------------------------------------------
step "Installing PostgreSQL ${EXPECTED_PG_VERSION} (method: ${METHOD})"

PG_INSTALL_DIR=""
LIBPQ_INCDIR=""
LIBPQ_LIBDIR=""

# ─── 2a. PERCONA TARBALL (default) ─────────────────────────────────────────
# Dokumentace: https://docs.percona.com/postgresql/18/tarball.html
install_percona_tarball() {
    local VERSION="18.4"
    local INSTALL_BASE="/opt/pgdistro"
    local PG_SUBDIR="percona-postgresql18"

    # Detect OpenSSL version → choose tarball variant.
    # PG18 tarballs ship three variants (unlike PG16's two: ssl1/ssl3) --
    # ssl1.1, ssl3 (OpenSSL 3.0-3.4), and ssl3.5 (OpenSSL 3.5+). AlmaLinux 10
    # ships OpenSSL 3.5.x, so the major-version-only check used for PG16
    # would silently grab the wrong (but still installable) ssl3 build here;
    # compare major.minor instead.
    local OPENSSL_VER
    OPENSSL_VER=$(openssl version | awk '{print $2}')
    local SSL_TAG
    local ssl_major="${OPENSSL_VER%%.*}"
    local ssl_minor="${OPENSSL_VER#*.}"; ssl_minor="${ssl_minor%%.*}"
    case "$ssl_major" in
        1) SSL_TAG="ssl1.1" ;;
        3)
            if [[ "$ssl_minor" -ge 5 ]]; then
                SSL_TAG="ssl3.5"
            else
                SSL_TAG="ssl3"
            fi
            ;;
        *) SSL_TAG="ssl3.5"; warn "Unknown OpenSSL version ${OPENSSL_VER}, trying ssl3.5" ;;
    esac

    # Map architecture to tarball name
    local TARARCH
    case "$ARCH" in
        x86_64)  TARARCH="linux-x86_64" ;;
        aarch64) TARARCH="linux-aarch64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac

    local TARBALL="percona-postgresql-${VERSION}-${SSL_TAG}-${TARARCH}.tar.gz"
    local URL="https://downloads.percona.com/downloads/postgresql-distribution-18/${VERSION}/binary/tarball/${TARBALL}"

    info "Tarball: ${TARBALL}"
    info "URL:     ${URL}"

    # Skip if binary already exists
    if [[ -x "${INSTALL_BASE}/${PG_SUBDIR}/bin/postgres" ]]; then
        info "Percona PostgreSQL 18 already installed in ${INSTALL_BASE}/${PG_SUBDIR}"
        PG_INSTALL_DIR="${INSTALL_BASE}/${PG_SUBDIR}"
        return 0
    fi

    mkdir -p "${INSTALL_BASE}"

    local TMPTAR="/tmp/${TARBALL}"
    # Fetch-once-distribute: with N guests all running setup at once, N
    # independent downloads hammer downloads.percona.com. If the orchestrator
    # already staged a copy here (taf_manage.py --PERCONA_ARCHIVE_LOCAL, SCP'd
    # to REMOTE_WORKDIR before setup), use it instead of downloading.
    if [[ -n "${PERCONA_LOCAL_ARCHIVE:-}" ]] && [[ -f "$PERCONA_LOCAL_ARCHIVE" ]]; then
        info "Using pre-staged tarball: ${PERCONA_LOCAL_ARCHIVE}"
        local abs_src abs_dst
        abs_src=$(readlink -f "$PERCONA_LOCAL_ARCHIVE")
        abs_dst=$(readlink -f "$TMPTAR" 2>/dev/null || echo "")
        [[ "$abs_src" != "$abs_dst" ]] && cp "$PERCONA_LOCAL_ARCHIVE" "$TMPTAR"
    elif [[ ! -f "$TMPTAR" ]]; then
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
        cat > /etc/profile.d/percona-pg18.sh <<PROFILE
# Percona PostgreSQL 18 — added by setup_almalinux10.sh
export PATH="${PG_INSTALL_DIR}/bin:\$PATH"
export LD_LIBRARY_PATH="${PG_LIB}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
PROFILE
        info "Profile written: /etc/profile.d/percona-pg18.sh"
    fi
}

# ─── 2b. PGDG RPM ──────────────────────────────────────────────────────────
install_pgdg_rpm() {
    local PG_REPO_RPM="https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
    if dnf install -y "$PG_REPO_RPM" 2>/dev/null; then
        info "PGDG repository added"
        dnf -qy module disable postgresql 2>/dev/null || true
        dnf install -y postgresql18-server postgresql18-devel postgresql18
        PG_INSTALL_DIR="/usr/pgsql-18"
    else
        warn "PGDG EL10 repo unavailable, falling back to AppStream"
        install_appstream
    fi
}

# ─── 2c. APPSTREAM ─────────────────────────────────────────────────────────
install_appstream() {
    # AlmaLinux 10 AppStream ships both the unversioned "postgresql" (16, the
    # default stream) and a versioned "postgresql18" package set side by
    # side; they conflict at the file level (postgresql-any / postgresql-
    # server-any virtual provides), so --allowerasing is required to swap 16
    # out for 18 on a base image that already has 16 installed.
    # libpq-devel is version-independent (provides libpq-fe.h for sysbench)
    # and does not conflict with postgresql18-*.
    dnf install -y --allowerasing postgresql18 postgresql18-server libpq-devel
    PG_INSTALL_DIR="/usr"
    warn "PostgreSQL installed from AppStream into ${PG_INSTALL_DIR}"
    warn "AppStream may lag behind the latest point release (EXPECTED_PG_VERSION=${EXPECTED_PG_VERSION:-18.4}) -- the version check in step 3b will fail loudly if so; use --method=percona for a guaranteed exact match."
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
for BIN in postgres pg_ctl psql initdb pg_isready; do
    if [[ -x "${PG_BIN}/${BIN}" ]]; then
        info "  ✓ ${PG_BIN}/${BIN}"
    else
        warn "  ✗ ${PG_BIN}/${BIN} not found"
        MISSING=$((MISSING + 1))
    fi
done
[[ $MISSING -eq 0 ]] || error "Missing binaries — check installation in ${PG_INSTALL_DIR}"

# pg_config is provided by postgresql-server-devel, which conflicts with
# libpq-devel on EL10 AppStream. It is only needed to locate libpq headers
# for sysbench; fall back to hardcoded AppStream paths when unavailable.
if [[ -x "${PG_BIN}/pg_config" ]]; then
    info "PostgreSQL version: $("${PG_BIN}/pg_config" --version)"
    LIBPQ_INCDIR=$("${PG_BIN}/pg_config" --includedir)
    LIBPQ_LIBDIR=$("${PG_BIN}/pg_config" --libdir)
else
    warn "pg_config not found (postgresql-server-devel not installed); using AppStream defaults"
    info "PostgreSQL version: $("${PG_BIN}/postgres" --version 2>/dev/null || echo unknown)"
    LIBPQ_INCDIR="/usr/include"
    LIBPQ_LIBDIR="/usr/lib64"
fi
info "includedir: ${LIBPQ_INCDIR}"
info "libdir:     ${LIBPQ_LIBDIR}"

# ---------------------------------------------------------------------------
# 3b. VERIFY POSTGRESQL VERSION MATCHES EXPECTED CURRENT STABLE RELEASE
# ---------------------------------------------------------------------------
# Any installed version other than EXPECTED_PG_VERSION is a hard error --
# better to fail loudly here than to silently benchmark an unintended
# PostgreSQL version (e.g. AppStream lagging a point release behind, or a
# stale cached tarball/RPM repo).
step "Verifying PostgreSQL version"
ACTUAL_PG_VERSION=$("${PG_BIN}/postgres" --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
if [[ -z "$ACTUAL_PG_VERSION" ]]; then
    error "Could not determine installed PostgreSQL version from '${PG_BIN}/postgres --version'"
fi
if [[ "$ACTUAL_PG_VERSION" != "$EXPECTED_PG_VERSION" ]]; then
    error "Installed PostgreSQL version ${ACTUAL_PG_VERSION} != expected ${EXPECTED_PG_VERSION} (method=${METHOD}, dir=${PG_INSTALL_DIR}). Either a newer release has shipped (update EXPECTED_PG_VERSION at the top of this script), or this --method's repo/tarball is out of date for the pinned version -- try a different --method (percona guarantees an exact-version tarball)."
fi
info "PostgreSQL version OK: ${ACTUAL_PG_VERSION}"

# ---------------------------------------------------------------------------
# 4. LIBPQ HEADERS FOR SYSBENCH
# ---------------------------------------------------------------------------
step "Checking libpq-fe.h for sysbench"
if [[ -f "${LIBPQ_INCDIR}/libpq-fe.h" ]]; then
    info "libpq-fe.h found: ${LIBPQ_INCDIR}/libpq-fe.h"
else
    warn "libpq-fe.h not found, trying system packages..."
    dnf install -y --allowerasing postgresql-devel libpq-devel 2>/dev/null || \
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
    # Submodule check: LuaJIT Makefile is only present after a proper git clone
    # with --recurse-submodules. Zip-extracted source lacks .git/ so submodules
    # are empty. Force a fresh clone whenever the submodule is missing.
    if [[ ! -f "${SYSBENCH_SRC}/third_party/luajit/luajit/Makefile" ]]; then
        info "Cloning sysbench (submodules missing or incomplete)..."
        rm -rf "${SYSBENCH_SRC}"
        mkdir -p "${TAF_DIR}/client_source"
        git clone --depth=1 --recurse-submodules https://github.com/akopytov/sysbench "${SYSBENCH_SRC}"
    fi

    info "Building sysbench with pgsql support..."
    cd "${SYSBENCH_SRC}"

    # Use bash explicitly — files from a zip archive may lack execute bits.
    bash autogen.sh
    bash configure --without-mysql --with-pgsql \
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
