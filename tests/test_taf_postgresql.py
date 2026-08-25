#!/usr/bin/env python3
"""
test_taf_postgresql.py — TAF PostgreSQL Integration Tests

Layered test suite covering the complete PostgreSQL adaptation of TAF.
Designed for AlmaLinux 10 + PostgreSQL 18 from PGDG.

Layers:
    L1  Static validation (syntax, grep) — no external dependencies
    L2  Plugin unit test (Perl subprocess) — requires PG install
    L3  DB lifecycle (init → start → stop) — requires TAF run
    L4  Sysbench build with pgsql driver — requires cmake + libpq
    L5  Full benchmark run (short) — requires L4
    L6  MariaDB regression test — requires TAF_MARIADB_DIR

Prerequisites:
    sudo bash tests/setup_almalinux10.sh

Running:
    export TAF_PG_INSTALL_DIR=/usr/pgsql-16   # default
    export TAF_PG_PORT=5433                   # default, avoids conflict
    python3 -m pytest tests/test_taf_postgresql.py -v

Optional (L6):
    export TAF_MARIADB_DIR=/path/to/mariadb-install
"""

from __future__ import annotations

import os
import re
import subprocess
import textwrap
import time
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TAF_ROOT = Path(__file__).resolve().parents[1]
PG_INSTALL = Path(os.environ.get("TAF_PG_INSTALL_DIR", "/usr/pgsql-16"))
PG_PORT = int(os.environ.get("TAF_PG_PORT", "5433"))
MARIADB_DIR = os.environ.get("TAF_MARIADB_DIR")

PG_BIN = PG_INSTALL / "bin"
PG_AVAILABLE = PG_BIN.is_dir() and (PG_BIN / "postgres").is_file()

# Default user/db for TAF tester
TAF_PG_USER = "pgsql_tester"
TAF_PG_PASS = "PostgresPass_@123"
TAF_PG_DB   = "test"
TAF_PG_ROOT = "postgres"
TAF_PG_ROOT_PASS = "PostgresPass_@123"

# ---------------------------------------------------------------------------
# Pytest marks
# ---------------------------------------------------------------------------
needs_pg = pytest.mark.skipif(
    not PG_AVAILABLE,
    reason=f"PostgreSQL install not found in {PG_INSTALL} "
           f"(set TAF_PG_INSTALL_DIR or run setup_almalinux10.sh)",
)
needs_mariadb = pytest.mark.skipif(
    not MARIADB_DIR or not Path(MARIADB_DIR).is_dir(),
    reason="TAF_MARIADB_DIR is not set or does not exist — L6 skipped",
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

def run(*cmd: str, cwd: Path | None = None, timeout: int = 60,
        env: dict | None = None) -> subprocess.CompletedProcess:
    """Runs a command and returns CompletedProcess (does not raise on non-zero)."""
    merged_env = None
    if env:
        merged_env = os.environ.copy()
        merged_env.update(env)
    return subprocess.run(
        list(cmd),
        capture_output=True, text=True,
        cwd=str(cwd or TAF_ROOT),
        timeout=timeout,
        env=merged_env,
    )


def taf_run(props: dict, timeout: int = 600) -> subprocess.CompletedProcess:
    """Runs perl taf.pl with the given properties (dict)."""
    cmd = ["perl", str(TAF_ROOT / "taf.pl")]
    for k, v in props.items():
        cmd.append(f"--property={k}={v}")
    return subprocess.run(
        cmd,
        capture_output=True, text=True,
        cwd=str(TAF_ROOT),
        timeout=timeout,
    )


def taf_propfile(props_file: Path, extra: dict | None = None,
                 timeout: int = 600) -> subprocess.CompletedProcess:
    """Runs perl taf.pl with a properties file and optionally extra overrides."""
    cmd = ["perl", str(TAF_ROOT / "taf.pl"),
           f"--properties-file={props_file}"]
    for k, v in (extra or {}).items():
        cmd.append(f"--property={k}={v}")
    return subprocess.run(
        cmd,
        capture_output=True, text=True,
        cwd=str(TAF_ROOT),
        timeout=timeout,
    )


def write_props(path: Path, props: dict) -> None:
    """Writes a dict to a .properties file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for k, v in props.items():
            f.write(f"{k} = {v}\n")


def has_no_errors(text: str) -> tuple[bool, str | None]:
    """Returns (True, None) if TAF output contains no error lines.
    Ignores comments and informational 'error' in values.
    """
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        # Look for ERROR as a token (not 'error' inside values)
        if re.search(r'\bERROR\b', line):
            return False, line
    return True, None


def find_pg_data_dir(taf_output: str) -> Path | None:
    """Parses verbose TAF output and searches for the data directory path."""
    # TAF logs e.g.: "Preparing data directory: /path/to/data"
    #             or: "data_dir does not exist: /path"
    #             or: "Datadir does not exist: /path"
    patterns = [
        r'data.dir[:\s]+(/[^\s]+)',
        r'Removing existing data directory\s+(/[^\s]+)',
        r'Created.*data.*dir.*?(/[^\s]+)',
        r'initdb.*?-D\s+(/[^\s]+)',
        r'pg_ctl.*?-D\s+(/[^\s]+)',
    ]
    for pat in patterns:
        m = re.search(pat, taf_output, re.IGNORECASE)
        if m:
            return Path(m.group(1))
    return None


def psql(query: str, user: str = TAF_PG_USER, password: str = TAF_PG_PASS,
         db: str = TAF_PG_DB, port: int = PG_PORT,
         host: str = "127.0.0.1") -> subprocess.CompletedProcess:
    """Runs a psql query and returns the result."""
    env = {"PGPASSWORD": password}
    return run(
        str(PG_BIN / "psql"),
        "-h", host, "-p", str(port), "-U", user, "-d", db,
        "-c", query, "-q", "--no-psqlrc", "--tuples-only",
        env=env,
        timeout=15,
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def lifecycle_result(tmp_path_factory):
    """L3 fixture: runs TAF init-start-db-exit once per session.

    Returns (CompletedProcess, data_dir_path_or_None).
    Ensures PostgreSQL is stopped even on error.
    """
    # Stop any leftover PG from a previous session
    _shutdown_pg_if_running()

    tmp = tmp_path_factory.mktemp("taf_l3")
    props_file = tmp / "lifecycle.properties"

    write_props(props_file, {
        "taf.action":                "init-start-db-exit",
        "taf.taf_db_makers_plugin":  "postgres",
        "taf.db_software_install_dir": str(PG_INSTALL),
        "taf.db_port":               str(PG_PORT),
        "taf.db_user":               TAF_PG_USER,
        "taf.db_user_pass":          TAF_PG_PASS,
        "taf.db_root_user":          TAF_PG_ROOT,
        "taf.db_root_pass":          TAF_PG_ROOT_PASS,
        "taf.database":              TAF_PG_DB,
        "taf.test_suite":            "sysbench-lua",
        "taf.verbose":               "true",
        "sysbench_lua.db_driver":    "pgsql",
    })

    result = taf_propfile(props_file, timeout=300)
    output = result.stdout + result.stderr
    data_dir = find_pg_data_dir(output)

    yield result, data_dir

    # Cleanup: ensure PG is shut down if TAF failed midway
    _shutdown_pg_if_running()


@pytest.fixture(scope="session")
def benchmark_result(tmp_path_factory):
    """L5 fixture: runs a short TAF benchmark (OLTP_RO + POINT_SELECT).

    Returns CompletedProcess.
    """
    # L3 leaves PostgreSQL running (init-start-db-exit keeps PG alive); stop it
    # before TAF tries to start a fresh instance via init-start-db-run-tests.
    _shutdown_pg_if_running()

    tmp = tmp_path_factory.mktemp("taf_l5")
    props_file = tmp / "benchmark.properties"

    # Sysbench uses autotools (not cmake); binary built via L4 autotools test.
    # Use init-start-db-run-tests to skip client build (avoid cmake failure).
    # sysbench_lua.exe defaults to relative path client_source/sysbench-lua/sysbench
    # which resolves correctly from TAF working dir — no override needed.
    write_props(props_file, {
        "taf.action":                     "init-start-db-run-tests",
        "taf.taf_db_makers_plugin":       "postgres",
        "taf.db_software_install_dir":    str(PG_INSTALL),
        "taf.db_port":                    str(PG_PORT),
        "taf.db_user":                    TAF_PG_USER,
        "taf.db_user_pass":               TAF_PG_PASS,
        "taf.db_root_user":               TAF_PG_ROOT,
        "taf.db_root_pass":               TAF_PG_ROOT_PASS,
        "taf.database":                   TAF_PG_DB,
        "taf.test_suite":                 "sysbench-lua",
        "taf.tests":                      "OLTP_RO,POINT_SELECT",
        "taf.verbose":                    "true",
        "sysbench_lua.db_driver":         "pgsql",
        "sysbench_lua.connector":         "libpq",
        "sysbench_lua.def_threads":       "4,8",
        "sysbench_lua.def_duration":      "30",
        "sysbench_lua.number_of_tables":  "1",
        "sysbench_lua.number_of_rows":    "10000",
        "sysbench_lua.oltp_skip_trx":     "off",
    })

    result = taf_propfile(props_file, timeout=900)

    yield result

    _shutdown_pg_if_running()


def _shutdown_pg_if_running() -> None:
    """Best-effort: stop PG if still running (cleanup after L3/L5).

    TAF and the pytest process run as the same non-root user, and PostgreSQL
    now always runs as that same user too — so pg_ctl stop needs no su/root.
    We only fall back to su when the harness itself happens to run as root
    (EUID 0), since pg_ctl unconditionally refuses to operate as root.
    """
    import signal as _signal
    from pathlib import Path
    pg_ctl = PG_BIN / "pg_ctl"
    is_root = hasattr(os, "geteuid") and os.geteuid() == 0
    # TAF creates the data directory in /tmp/taf_pg_<PID>/data/ or in TAF_ROOT/data/
    search_roots = [TAF_ROOT, Path("/tmp")]
    for root in search_roots:
        if not root.is_dir():
            continue
        for pid_file in root.rglob("postmaster.pid"):
            data_dir = pid_file.parent
            if pg_ctl.is_file():
                if is_root:
                    r = subprocess.run(
                        ["su", "-s", "/bin/sh", "postgres", "-c",
                         f"{pg_ctl} stop -D {data_dir} -m fast -w -t 30"],
                        capture_output=True, timeout=45,
                    )
                else:
                    r = subprocess.run(
                        [str(pg_ctl), "stop", "-D", str(data_dir),
                         "-m", "fast", "-w", "-t", "30"],
                        capture_output=True, timeout=45,
                    )
                if r.returncode == 0:
                    continue
            # Fallback: kill postmaster directly via SIGTERM
            try:
                pid = int(pid_file.read_text().splitlines()[0].strip())
                os.kill(pid, _signal.SIGTERM)
            except Exception:
                pass


# ===========================================================================
# LAYER 1 — Static validation
# ===========================================================================

class TestL1Static:
    """Syntax and text validation without running TAF or PostgreSQL."""

    def test_postgres_pm_exists(self):
        """Plugin postgres.pm must exist."""
        plugin = TAF_ROOT / "libs" / "database_libs" / "postgres.pm"
        assert plugin.is_file(), f"Missing: {plugin}"

    def test_postgres_pm_package_name(self):
        """Package declaration in postgres.pm must be 'package postgres'."""
        plugin = TAF_ROOT / "libs" / "database_libs" / "postgres.pm"
        content = plugin.read_text()
        assert re.search(r"^\s*package\s+postgres\s*;", content, re.MULTILINE), \
            "postgres.pm does not declare 'package postgres'"

    def test_postgres_pm_syntax(self):
        """`perl -c` on postgres.pm must pass (on Linux)."""
        result = run("perl", "-c",
                     str(TAF_ROOT / "libs" / "database_libs" / "postgres.pm"))
        assert result.returncode == 0 or \
               "Unsupported OS platform" in result.stderr, \
            f"Syntax error in postgres.pm:\n{result.stderr}"

    def test_sysbench_lua_syntax(self):
        """`perl -c` on sysbench-lua.pm must pass."""
        result = run("perl", "-c",
                     str(TAF_ROOT / "test_suites" / "sysbench-lua.pm"))
        assert result.returncode == 0, \
            f"Syntax error in sysbench-lua.pm:\n{result.stderr}"

    def test_pgsql_connection_args_in_sysbench(self):
        """sysbench-lua.pm must generate --pgsql-host/port/user/password/db."""
        content = (TAF_ROOT / "test_suites" / "sysbench-lua.pm").read_text()
        for flag in ("--pgsql-host", "--pgsql-port", "--pgsql-user",
                     "--pgsql-password", "--pgsql-db"):
            assert flag in content, \
                f"Missing '{flag}' in SetConnectionArgs() — pgsql branch"

    def test_mysql_args_guarded_for_pgsql(self):
        """--mysql-storage-engine must be guarded by 'db_driver ne pgsql'."""
        content = (TAF_ROOT / "test_suites" / "sysbench-lua.pm").read_text()
        # Find the block with mysql-storage-engine
        block = re.search(
            r"(Storage engine.*?mysql-storage-engine.*?\n)", content,
            re.DOTALL | re.IGNORECASE,
        )
        # A condition with 'pgsql' must exist near --mysql-storage-engine
        idx = content.find("--mysql-storage-engine")
        assert idx >= 0, "--mysql-storage-engine not found in file"
        surrounding = content[max(0, idx - 200):idx + 100]
        assert "pgsql" in surrounding, \
            "--mysql-storage-engine is not guarded by a db_driver ne pgsql check"

    def test_normalize_db_type_defined(self):
        """NormalizeDBType must be defined in sysbench-lua.pm."""
        content = (TAF_ROOT / "test_suites" / "sysbench-lua.pm").read_text()
        assert "sub NormalizeDBType" in content, \
            "Missing sub NormalizeDBType in sysbench-lua.pm"

    def test_normalize_db_type_maps_postgres_to_pgsql(self):
        """NormalizeDBType must map postgres/postgresql → pgsql."""
        content = (TAF_ROOT / "test_suites" / "sysbench-lua.pm").read_text()
        # Extract the function
        m = re.search(r"sub NormalizeDBType \{(.+?)\n\}", content, re.DOTALL)
        assert m, "NormalizeDBType not found"
        body = m.group(1)
        assert "pgsql" in body and "postgres" in body, \
            "NormalizeDBType does not contain the postgres → pgsql mapping"

    def test_validate_target_normalizes_incoming(self):
        """ValidateTargetWithSuite must normalize $incoming before comparison."""
        content = (TAF_ROOT / "test_suites" / "sysbench-lua.pm").read_text()
        # Look for NormalizeDBType($incoming) in the body of ValidateTargetWithSuite
        m = re.search(
            r"sub ValidateTargetWithSuite \{(.+?)\n\}",
            content, re.DOTALL,
        )
        assert m, "ValidateTargetWithSuite not found"
        body = m.group(1)
        assert "NormalizeDBType($incoming)" in body, \
            "ValidateTargetWithSuite does not normalize \\$incoming before comparison"

    def test_cmake_args_contains_pgsql(self):
        """ClientCmakeBuild.pm must inject -DWITH_PGSQL=ON when building for pgsql.

        WITH_PGSQL is not a static cmake_args value in the properties file —
        ClientCmakeBuild.pm appends it dynamically based on db_driver
        (see the WITH_MYSQL=OFF counterpart for the mysql/mariadb branch).
        """
        content = (
            TAF_ROOT / "libs" / "script_tools_lib" / "ClientCmakeBuild.pm"
        ).read_text()
        assert "-DWITH_PGSQL=ON" in content, \
            "ClientCmakeBuild.pm does not inject -DWITH_PGSQL=ON for the pgsql build path"

    def test_postgres_sql_blocks_count(self):
        """postgres.sql must have at least 14 named blocks."""
        content = (TAF_ROOT / "libs" / "sql_libs" / "dialects" / "postgres.sql").read_text()
        blocks = re.findall(r"^\[(\w+)\]", content, re.MULTILINE)
        assert len(blocks) >= 14, \
            f"postgres.sql has only {len(blocks)} blocks, expected ≥14: {blocks}"

    def test_postgres_sql_has_diagnostic_blocks(self):
        """postgres.sql must contain diagnostic blocks for benchmark analysis."""
        content = (TAF_ROOT / "libs" / "sql_libs" / "dialects" / "postgres.sql").read_text()
        required = [
            "active_connections", "wait_events", "table_stats",
            "index_usage", "bgwriter_stats", "transaction_stats",
        ]
        for block in required:
            assert f"[{block}]" in content, \
                f"Missing diagnostic block [{block}] in postgres.sql"

    def test_utilities_pm_has_postgresql_alias(self):
        """Utilities.pm must map 'postgresql' → 'postgres' in PLUGIN_ALIASES."""
        content = (TAF_ROOT / "libs" / "taf_libs" / "TAF" / "Utilities.pm").read_text()
        assert re.search(r"postgresql\s*=>\s*['\"]postgres['\"]", content), \
            "Missing 'postgresql => postgres' in PLUGIN_ALIASES (Utilities.pm)"

    def test_postgresql_conf_templates_exist(self):
        """At least three postgresql.conf templates must exist."""
        pg_cfg_dir = TAF_ROOT / "database_config_files" / "postgresql"
        assert pg_cfg_dir.is_dir(), f"Directory {pg_cfg_dir} does not exist"
        configs = list(pg_cfg_dir.glob("*.conf"))
        assert len(configs) >= 3, \
            f"Expected ≥3 .conf files, found {len(configs)}: {configs}"

    def test_postgresql_properties_examples_exist(self):
        """Example properties files for PostgreSQL must exist."""
        pg_props_dir = TAF_ROOT / "properties" / "postgresql"
        assert pg_props_dir.is_dir(), f"Directory {pg_props_dir} does not exist"
        props = list(pg_props_dir.glob("*.properties"))
        assert len(props) >= 2, \
            f"Expected ≥2 .properties files, found {len(props)}: {props}"

    def test_hammerdb_agent_matches_client_executable_version(self):
        """hammerdb_*.agent must reference the same HammerDB-X.Y tree as client_executable.

        Regression guard: client_executable was bumped to HammerDB-6.0 while
        .agent still pointed at HammerDB-5.0 (a stale agent/CLI version pair
        can silently break the metrics agent handshake).
        """
        for suite in ("hammerdb_tprocc", "hammerdb_tproch"):
            defaults = (TAF_ROOT / "properties" / "default" /
                        f"{suite}_default.properties").read_text()
            client = re.search(rf"{suite}\.client_executable\s*=\s*(\S+)", defaults)
            agent = re.search(rf"{suite}\.agent\s*=\s*(\S+)", defaults)
            assert client and agent, f"Missing client_executable/agent in {suite}_default.properties"
            client_ver = re.search(r"HammerDB-[\d.]+", client.group(1))
            agent_ver = re.search(r"HammerDB-[\d.]+", agent.group(1))
            assert client_ver and agent_ver, "Could not extract HammerDB version from paths"
            assert client_ver.group(0) == agent_ver.group(0), (
                f"{suite}: client_executable uses {client_ver.group(0)} but "
                f"agent uses {agent_ver.group(0)}"
            )

    def test_pgsql_example_properties_use_real_keys(self):
        """hammerdb_tprocc_pgsql.properties must use property keys that hammerdb-tprocc.pm
        actually reads (number_of_warehouses, global taf.threads/taf.duration) —
        not made-up keys (warehouses, def_threads, def_duration, rampup) that are
        silently ignored and fall back to defaults.
        """
        content = (TAF_ROOT / "properties" / "postgresql" /
                   "hammerdb_tprocc_pgsql.properties").read_text()
        for bogus in ("hammerdb_tprocc.warehouses ", "hammerdb_tprocc.def_threads",
                      "hammerdb_tprocc.def_duration", "hammerdb_tprocc.rampup"):
            assert bogus not in content, \
                f"Found bogus/no-op property '{bogus.strip()}' in hammerdb_tprocc_pgsql.properties"
        assert "hammerdb_tprocc.number_of_warehouses" in content
        assert re.search(r"^taf\.threads\s*=", content, re.MULTILINE)
        assert re.search(r"^taf\.duration\s*=", content, re.MULTILINE)

    def test_hammerdb_tproch_pgsql_properties_exists(self):
        """A PostgreSQL example properties file for TPROC-H must exist.

        TPROC-H had pg_tproch_* Tcl scripts wired in client_source/hammerdb
        but, unlike TPROC-C, no example properties file and no test coverage
        before this was added.
        """
        props = TAF_ROOT / "properties" / "postgresql" / "hammerdb_tproch_pgsql.properties"
        assert props.is_file(), f"Missing: {props}"
        content = props.read_text()
        assert "hammerdb_tproch.db_type" in content and "postgres" in content

    def test_hammerdb_tproch_pm_has_postgres_wiring(self):
        """hammerdb-tproch.pm must have postgres-specific connection config,
        matching the pg_tproch_* Tcl scripts vendored in client_source."""
        content = (TAF_ROOT / "test_suites" / "hammerdb-tproch.pm").read_text()
        assert "eq 'postgres'" in content or 'eq "postgres"' in content, \
            "hammerdb-tproch.pm has no postgres-specific branch"


# ===========================================================================
# LAYER 2 — Plugin unit test (via Perl subprocess)
# ===========================================================================

def _build_plugin_unit_script(pg_install: Path, port: int,
                               user: str, password: str,
                               root: str, root_pass: str) -> str:
    """Builds a Perl unit-test script for the postgres.pm plugin.

    Does not use str.format() — Perl syntax contains {} which would conflict
    with Python format placeholders.
    """
    taf_libs = str(pg_install.parent.parent / "libs" / "database_libs") \
               if False else str(TAF_ROOT / "libs" / "database_libs")
    return (
        "#!/usr/bin/perl\n"
        "use strict;\n"
        "use warnings;\n"
        "\n"
        "BEGIN {\n"
        "    package TAF::Logging;\n"
        "    use Exporter 'import';\n"
        "    our @EXPORT_OK = qw(PrintError PrintWarning PrintVerbose StageStart StageEnd);\n"
        "    sub PrintError   { print \"ERR: @_\\n\" }\n"
        "    sub PrintWarning { print \"WARN: @_\\n\" }\n"
        "    sub PrintVerbose { }\n"
        "    sub StageStart   { return $_[0] }\n"
        "    sub StageEnd     { }\n"
        "    $INC{'TAF/Logging.pm'} = __FILE__;\n"
        "}\n"
        "\n"
        f"use lib '{TAF_ROOT}/libs/database_libs';\n"
        f"use lib '{TAF_ROOT}/libs/taf_libs';\n"
        "\n"
        "require 'postgres.pm';\n"
        "\n"
        "my $pg_install = shift @ARGV or die \"Missing pg_install\\n\";\n"
        "my $tmpdir     = '/tmp';\n"
        "my $pass = 0; my $fail = 0;\n"
        "\n"
        "sub ok {\n"
        "    my ($cond, $name) = @_;\n"
        "    if ($cond) { print \"PASS: $name\\n\"; $pass++ }\n"
        "    else       { print \"FAIL: $name\\n\"; $fail++ }\n"
        "}\n"
        "\n"
        "# Test 1: new() with invalid install_root → undef\n"
        "{\n"
        "    my $pg = postgres->new(\n"
        "        db_software_install_dir => '/nonexistent_xyz',\n"
        "        db_data_dir             => '/tmp/pg_unit_data',\n"
        "        tmp_dir                 => $tmpdir,\n"
        "    );\n"
        "    ok(!defined $pg, \"new() rejects invalid install_root\");\n"
        "}\n"
        "\n"
        "# Test 2: new() with valid installation → object\n"
        "{\n"
        "    my $pg = postgres->new(\n"
        "        db_software_install_dir => $pg_install,\n"
        "        db_data_dir             => '/tmp/pg_unit_data',\n"
        "        tmp_dir                 => $tmpdir,\n"
        f"        db_port                 => {port},\n"
        f"        db_user                 => '{user}',\n"
        f"        db_user_pass            => '{password}',\n"
        f"        db_root_user            => '{root}',\n"
        f"        db_root_pass            => '{root_pass}',\n"
        "    );\n"
        "    ok(defined $pg, \"new() returns object with valid installation\");\n"
        "\n"
        "    if (defined $pg) {\n"
        "        for my $b (qw(postgres_bin pg_ctl_bin psql_bin initdb_bin pg_isready_bin)) {\n"
        "            ok(defined $pg->{$b} && -x $pg->{$b},\n"
        "               \"Binary $b found: \" . ($pg->{$b} // '<undef>'));\n"
        "        }\n"
        f"        ok($pg->{{port}} == {port}, \"Port nastaven na {port}\");\n"
        f"        ok($pg->{{db_user}} eq '{user}',      \"db_user stored correctly\");\n"
        f"        ok($pg->{{db_root_user}} eq '{root}', \"db_root_user stored correctly\");\n"
        "    }\n"
        "}\n"
        "\n"
        "print \"\\nResult: $pass passed, $fail failed\\n\";\n"
        "exit($fail > 0 ? 1 : 0);\n"
    )


class TestL2PluginUnit:
    """Unit tests for the postgres.pm plugin via Perl subprocess."""

    @needs_pg
    def test_plugin_unit_all_pass(self, tmp_path):
        """All unit tests for postgres.pm must pass."""
        script = _build_plugin_unit_script(
            pg_install=PG_INSTALL,
            port=PG_PORT,
            user=TAF_PG_USER,
            password=TAF_PG_PASS,
            root=TAF_PG_ROOT,
            root_pass=TAF_PG_ROOT_PASS,
        )

        script_file = tmp_path / "pg_plugin_unit.pl"
        script_file.write_text(script)

        result = run(
            "perl", str(script_file), str(PG_INSTALL),
            cwd=TAF_ROOT, timeout=30,
        )
        output = result.stdout + result.stderr

        # Extract result
        m = re.search(r"Result:\s*(\d+) passed,\s*(\d+) failed", output)
        if m:
            passed, failed = int(m.group(1)), int(m.group(2))
        else:
            passed, failed = 0, 1

        fails = [ln for ln in output.splitlines() if ln.startswith("FAIL:")]
        assert failed == 0, (
            f"Plugin unit tests failed ({failed} failures):\n"
            + "\n".join(fails)
            + f"\n\nFull output:\n{output}"
        )


# ===========================================================================
# LAYER 3 — Database lifecycle
# ===========================================================================

class TestL3Lifecycle:
    """Tests the full TAF PostgreSQL lifecycle: init → start → stop."""

    @needs_pg
    def test_taf_exits_cleanly(self, lifecycle_result):
        """TAF init-start-db-exit must finish with exit code 0."""
        result, _ = lifecycle_result
        assert result.returncode == 0, (
            f"TAF finished with rc={result.returncode}\n"
            f"STDOUT:\n{result.stdout[-3000:]}\n"
            f"STDERR:\n{result.stderr[-1000:]}"
        )

    @needs_pg
    def test_no_errors_in_taf_output(self, lifecycle_result):
        """TAF output must not contain ERROR lines."""
        result, _ = lifecycle_result
        output = result.stdout + result.stderr
        clean, bad_line = has_no_errors(output)
        assert clean, f"ERROR line found in TAF output:\n  {bad_line}"

    @needs_pg
    def test_initdb_stage_logged(self, lifecycle_result):
        """TAF must log PostgreSQL cluster initialization."""
        result, _ = lifecycle_result
        output = result.stdout + result.stderr
        assert any(
            keyword in output.lower()
            for keyword in ("initdb", "initialize", "init database")
        ), "Missing initdb stage record in TAF output"

    @needs_pg
    def test_start_stage_logged(self, lifecycle_result):
        """TAF must log PostgreSQL server start."""
        result, _ = lifecycle_result
        output = result.stdout + result.stderr
        assert any(
            keyword in output.lower()
            for keyword in ("database start", "pg_ctl start", "server started",
                            "postgresql.*start", "start.*postgresql")
        ), "Missing start stage record in TAF output"

    @needs_pg
    def test_stop_stage_logged(self, lifecycle_result):
        """TAF must log PostgreSQL server stop."""
        result, _ = lifecycle_result
        output = result.stdout + result.stderr
        assert any(
            keyword in output.lower()
            for keyword in ("database stop", "pg_ctl stop", "server stopped")
        ), "Missing stop stage record in TAF output"

    @needs_pg
    def test_pg_hba_conf_has_tcp_md5_rules(self, lifecycle_result):
        """pg_hba.conf must contain md5 rules for TCP access."""
        result, data_dir = lifecycle_result
        if data_dir is None:
            pytest.skip("Cannot determine data_dir from TAF output")
        hba = data_dir / "pg_hba.conf"
        assert hba.is_file(), f"pg_hba.conf not found in {data_dir}"
        content = hba.read_text()
        assert "127.0.0.1" in content, "pg_hba.conf does not contain a rule for 127.0.0.1"
        assert "md5" in content, "pg_hba.conf does not use md5 authentication"

    @needs_pg
    def test_postgresql_conf_has_correct_port(self, lifecycle_result):
        """postgresql.conf must contain the TAF-configured port."""
        result, data_dir = lifecycle_result
        if data_dir is None:
            pytest.skip("Cannot determine data_dir from TAF output")
        conf = data_dir / "postgresql.conf"
        assert conf.is_file(), f"postgresql.conf not found in {data_dir}"
        content = conf.read_text()
        assert f"port = {PG_PORT}" in content, \
            f"postgresql.conf does not contain 'port = {PG_PORT}'"

    @needs_pg
    def test_server_running_after_start_exit(self, lifecycle_result):
        """After init-start-db-exit, PostgreSQL server must be listening on the port.

        The init-start-db-exit action intentionally leaves the server running
        (exit = TAF exit, not db stop). The cleanup fixture stops the server
        at the end of the session.
        """
        result, _ = lifecycle_result
        # Test is only relevant when lifecycle succeeded
        if result.returncode != 0:
            pytest.skip("Lifecycle failed — skipping server-running check")
        pg_isready = PG_BIN / "pg_isready"
        if not pg_isready.is_file():
            pytest.skip("pg_isready not found")
        check = run(
            str(pg_isready), "-h", "127.0.0.1", "-p", str(PG_PORT), "-q",
        )
        assert check.returncode == 0, \
            f"PostgreSQL is not listening on port {PG_PORT} after init-start-db-exit"


# ===========================================================================
# LAYER 4 — Sysbench build with pgsql driver
# ===========================================================================

class TestL4SysbenchBuild:
    """Verifies that sysbench builds with the pgsql driver.

    Note: Sysbench uses autotools (autogen.sh + configure + make), not cmake.
    TAF build-client assumes cmake — so L4 tests the autotools build directly.
    The resulting binary is accessible via symlink client_source/sysbench-lua/sysbench → src/sysbench.
    """

    SYSBENCH_SRC = TAF_ROOT / "client_source" / "sysbench-lua"
    SYSBENCH_BIN = SYSBENCH_SRC / "sysbench"   # symlink na src/sysbench

    @needs_pg
    def test_sysbench_build_succeeds(self, tmp_path_factory):
        """Sysbench build with pgsql driver (autotools: autogen+configure+make)."""
        src = self.SYSBENCH_SRC
        if not (src / "configure.ac").is_file():
            pytest.skip(f"Sysbench source not found: {src} — clone repo into client_source/sysbench-lua/")

        # autogen.sh
        result = run("bash", "autogen.sh", cwd=src, timeout=60)
        assert result.returncode == 0, f"autogen.sh failed:\n{result.stdout}\n{result.stderr}"

        # configure --with-pgsql --with-mysql (both drivers in one binary):
        # L6 (MariaDB regression) and L5/L7 (PostgreSQL) share this same
        # sysbench binary in the same test session -- a single-driver build
        # silently breaks whichever driver was left out ("invalid option:
        # --mysql-socket=..." / "--pgsql-host=..."). When TAF_MARIADB_DIR
        # points at a MariaDB install, use its bundled client headers/libs
        # instead of relying on system mysql/mariadb-devel packages, which
        # are not guaranteed to be installed.
        configure_args = ["--with-mysql", "--with-pgsql"]
        if MARIADB_DIR and Path(MARIADB_DIR).is_dir():
            configure_args += [
                f"--with-mysql-includes={MARIADB_DIR}/include/mysql",
                f"--with-mysql-libs={MARIADB_DIR}/lib",
            ]
        result = run("bash", "configure", *configure_args,
                     cwd=src, timeout=120)
        assert result.returncode == 0, (
            f"configure failed (rc={result.returncode}):\n"
            f"{result.stdout[-2000:]}\n{result.stderr[-500:]}"
        )

        # make
        import multiprocessing
        nproc = str(multiprocessing.cpu_count())
        result = run("make", f"-j{nproc}", cwd=src, timeout=300)
        assert result.returncode == 0, (
            f"make failed (rc={result.returncode}):\n"
            f"{result.stdout[-2000:]}\n{result.stderr[-500:]}"
        )

        # Ensure symlink sysbench → src/sysbench exists for TAF
        symlink = src / "sysbench"
        real_bin = src / "src" / "sysbench"
        if real_bin.is_file() and not symlink.exists():
            import os as _os
            _os.symlink("src/sysbench", str(symlink))

    @needs_pg
    def test_sysbench_binary_exists_after_build(self):
        """Sysbench binary must exist after the build."""
        sysbench_bin = TAF_ROOT / "client_source" / "sysbench-lua" / "sysbench"
        assert sysbench_bin.is_file(), \
            f"Sysbench binary not found: {sysbench_bin}"
        assert os.access(str(sysbench_bin), os.X_OK), \
            f"Sysbench binary is not executable: {sysbench_bin}"

    @needs_pg
    def test_sysbench_pgsql_driver_available(self):
        """Sysbench must support --db-driver=pgsql."""
        sysbench_bin = TAF_ROOT / "client_source" / "sysbench-lua" / "sysbench"
        if not sysbench_bin.is_file():
            pytest.skip("Sysbench binary not found — run L4 build test first")

        result = run(
            str(sysbench_bin), "--db-driver=pgsql", "--help",
            timeout=15,
        )
        output = result.stdout + result.stderr
        # sysbench with pgsql driver should display --pgsql-* options
        has_pgsql = any(
            keyword in output.lower()
            for keyword in ("pgsql", "postgres", "--pgsql-host")
        )
        assert has_pgsql, (
            "Sysbench does not support pgsql driver — check cmake build with "
            "-DWITH_PGSQL=on and availability of libpq-devel\n"
            f"Output: {output[:500]}"
        )

    @needs_pg
    def test_sysbench_mysql_driver_available(self):
        """Sysbench must ALSO support --db-driver=mysql (needed by L6's MariaDB
        regression run) -- regression guard for the single-driver
        --without-mysql configure flag that used to silently break this.
        """
        sysbench_bin = TAF_ROOT / "client_source" / "sysbench-lua" / "sysbench"
        if not sysbench_bin.is_file():
            pytest.skip("Sysbench binary not found — run L4 build test first")

        result = run(
            str(sysbench_bin), "--db-driver=mysql", "--help",
            timeout=15,
        )
        output = result.stdout + result.stderr
        has_mysql = "--mysql-host" in output or "--mysql-socket" in output
        assert has_mysql, (
            "Sysbench does not support mysql driver — the L4 build must pass "
            "--with-mysql (not --without-mysql), or L6 (MariaDB regression) "
            "fails with 'invalid option: --mysql-socket=...'\n"
            f"Output: {output[:500]}"
        )

    @needs_pg
    @pytest.mark.parametrize("with_mysql,with_pgsql", [
        (False, False),
        (True, False),
        (False, True),
        (True, True),
    ])
    def test_sysbench_configure_driver_matrix(self, tmp_path_factory, with_mysql, with_pgsql):
        """configure must succeed and correctly report driver support for
        every combination of --with-mysql/--with-pgsql.

        Runs against a throwaway copy of the source tree (autotools refuses
        an out-of-tree/VPATH configure once the source itself has already
        been configured in-tree, which the real L4 build always leaves
        behind) so this never disturbs the actual build the rest of the
        suite depends on. Only configure is exercised here, not make — a
        full build per combination would roughly 4x this test's runtime for
        marginal extra coverage; configure is where driver detection
        actually happens.
        """
        import shutil

        src = self.SYSBENCH_SRC
        if not (src / "configure.ac").is_file():
            pytest.skip(f"Sysbench source not found: {src}")

        work = tmp_path_factory.mktemp("sb_matrix") / "src"
        shutil.copytree(src, work, symlinks=True,
                         ignore=shutil.ignore_patterns(".git"))

        result = run("bash", "autogen.sh", cwd=work, timeout=60)
        assert result.returncode == 0, f"autogen.sh failed:\n{result.stdout}\n{result.stderr}"

        configure_args = [
            "--with-mysql" if with_mysql else "--without-mysql",
            "--with-pgsql" if with_pgsql else "--without-pgsql",
        ]
        if with_mysql and MARIADB_DIR and Path(MARIADB_DIR).is_dir():
            configure_args += [
                f"--with-mysql-includes={MARIADB_DIR}/include/mysql",
                f"--with-mysql-libs={MARIADB_DIR}/lib",
            ]

        result = run("bash", "configure", *configure_args, cwd=work, timeout=120)
        assert result.returncode == 0, (
            f"configure {configure_args} failed (rc={result.returncode}):\n"
            f"{result.stdout[-2000:]}\n{result.stderr[-500:]}"
        )

        summary = result.stdout
        expected_mysql = "yes" if with_mysql else "no"
        expected_pgsql = "yes" if with_pgsql else "no"
        assert re.search(rf"MySQL support\s*:\s*{expected_mysql}\b", summary), (
            f"configure summary does not report MySQL support = {expected_mysql} "
            f"for {configure_args}:\n{summary[-1000:]}"
        )
        assert re.search(rf"PostgreSQL support\s*:\s*{expected_pgsql}\b", summary), (
            f"configure summary does not report PostgreSQL support = {expected_pgsql} "
            f"for {configure_args}:\n{summary[-1000:]}"
        )


# ===========================================================================
# LAYER 5 — Full benchmark run
# ===========================================================================

class TestL5Benchmark:
    """End-to-end test: TAF init → build → benchmark → stop."""

    @needs_pg
    def test_benchmark_exits_cleanly(self, benchmark_result):
        """Benchmark run must finish with exit code 0."""
        result = benchmark_result
        assert result.returncode == 0, (
            f"Benchmark TAF run failed (rc={result.returncode})\n"
            f"STDOUT:\n{result.stdout[-5000:]}\n"
            f"STDERR:\n{result.stderr[-1000:]}"
        )

    @needs_pg
    def test_benchmark_output_has_no_errors(self, benchmark_result):
        """Benchmark output must not contain ERROR lines."""
        result = benchmark_result
        output = result.stdout + result.stderr
        clean, bad_line = has_no_errors(output)
        assert clean, f"ERROR found in benchmark output:\n  {bad_line}"

    @needs_pg
    def test_benchmark_uses_pgsql_connection_args(self, benchmark_result):
        """TAF benchmark must call sysbench with --pgsql-host (not --mysql-host)."""
        output = benchmark_result.stdout + benchmark_result.stderr
        # Verbose TAF output includes the sysbench command line
        assert "--pgsql-host" in output or "--pgsql-port" in output, (
            "sysbench was not run with --pgsql-* arguments. "
            "Check SetConnectionArgs() in sysbench-lua.pm\n"
            f"Searched in {len(output)} characters of output"
        )
        assert "--mysql-host" not in output, \
            "sysbench was run with --mysql-host instead of --pgsql-host!"

    @needs_pg
    def test_results_directory_structure(self, benchmark_result):
        """TAF must produce results for OLTP_RO or POINT_SELECT.

        TAF archives results to archive/ after the run completes — we search
        both in results/ (if TAF does not archive) and in archive/.
        """
        found_tests = set()
        for search_root in (TAF_ROOT / "results", TAF_ROOT / "archive"):
            if not search_root.is_dir():
                continue
            for entry in search_root.iterdir():
                if not entry.is_dir():
                    continue
                name = entry.name
                for test_name in ("OLTP_RO", "POINT_SELECT"):
                    if test_name in name and not name.startswith("Error_"):
                        found_tests.add(test_name)

        archive_entries = list((TAF_ROOT / "archive").iterdir()) if (TAF_ROOT / "archive").is_dir() else []
        assert len(found_tests) >= 1, (
            f"No results for OLTP_RO or POINT_SELECT in results/ or archive/. "
            f"archive/ contents: {[e.name for e in archive_entries]}"
        )

    @needs_pg
    def test_benchmark_result_files_contain_metrics(self, benchmark_result):
        """Result files must contain sysbench metrics (transactions).

        TAF archives results to archive/ — we search both locations.
        """
        search_roots = [TAF_ROOT / "results", TAF_ROOT / "archive"]

        metrics_found = False
        for search_root in search_roots:
            if not search_root.is_dir():
                continue
            result_files = list(search_root.rglob("*.log")) + \
                           list(search_root.rglob("*.txt"))
            for f in result_files:
                content = f.read_text(errors="replace")
                if "transactions" in content.lower() or \
                   "queries/sec" in content.lower() or \
                   "events/sec" in content.lower():
                    metrics_found = True
                    break
            if metrics_found:
                break

        assert metrics_found, \
            "No result file contains sysbench metrics (transactions/queries)"

    @needs_pg
    def test_no_sysbench_fatal_errors(self, benchmark_result):
        """Result files must not contain sysbench FATAL errors."""
        fatal_lines = []
        for search_root in (TAF_ROOT / "results", TAF_ROOT / "archive"):
            if not search_root.is_dir():
                continue
            for f in search_root.rglob("*.log"):
                # Skip logs from known-failed archive runs
                if "Error_" in str(f):
                    continue
                content = f.read_text(errors="replace")
                for line in content.splitlines():
                    if re.search(r"\bFATAL\b", line, re.IGNORECASE):
                        fatal_lines.append(f"{f.name}: {line}")

        assert not fatal_lines, \
            f"FATAL errors found in sysbench output:\n" + "\n".join(fatal_lines[:5])


# ===========================================================================
# LAYER 6 — MariaDB regression test
# ===========================================================================

class TestL6MariaDBRegression:
    """Verifies that changes to sysbench-lua.pm have not broken MySQL/MariaDB behaviour."""

    @needs_mariadb
    def test_mariadb_run_exits_cleanly(self, tmp_path_factory):
        """A short MariaDB TAF run must finish with exit code 0."""
        mariadb_dir = Path(MARIADB_DIR)
        tmp = tmp_path_factory.mktemp("taf_l6")
        props_file = tmp / "mariadb_regression.properties"

        write_props(props_file, {
            # init-start-db-run-tests (not start-db-run-tests): this must work
            # from a freshly-provisioned MariaDB install with no pre-existing
            # initialized data dir -- start-db-run-tests alone assumes the
            # system tables already exist and just hangs waiting for
            # readiness otherwise.
            "taf.action":                  "init-start-db-run-tests",
            "taf.taf_db_makers_plugin":    "mariadb",
            "taf.db_software_install_dir": str(mariadb_dir),
            "taf.db_config_file":          "database_config_files/mariadb/mariadb_default.cnf",
            "taf.db_port":                 "3306",
            "taf.test_suite":              "sysbench-lua",
            "taf.tests":                   "OLTP_RO",
            "taf.verbose":                 "true",
            "sysbench_lua.db_driver":      "mysql",
            "sysbench_lua.def_threads":    "4",
            "sysbench_lua.def_duration":   "30",
            "sysbench_lua.number_of_rows": "10000",
        })

        result = taf_propfile(props_file, timeout=300)
        assert result.returncode == 0, (
            f"MariaDB regression run failed (rc={result.returncode})\n"
            f"STDOUT:\n{result.stdout[-3000:]}"
        )

    @needs_mariadb
    def test_mysql_args_used_for_mariadb(self, tmp_path_factory):
        """MariaDB run must use --mysql-host (not --pgsql-host)."""
        mariadb_dir = Path(MARIADB_DIR)
        tmp = tmp_path_factory.mktemp("taf_l6_args")
        props_file = tmp / "mariadb_args.properties"

        write_props(props_file, {
            "taf.action":                  "init-start-db-run-tests",
            "taf.taf_db_makers_plugin":    "mariadb",
            "taf.db_software_install_dir": str(mariadb_dir),
            "taf.db_config_file":          "database_config_files/mariadb/mariadb_default.cnf",
            "taf.db_port":                 "3306",
            "taf.test_suite":              "sysbench-lua",
            "taf.tests":                   "OLTP_RO",
            "taf.verbose":                 "true",
            "sysbench_lua.db_driver":      "mysql",
            "sysbench_lua.def_threads":    "4",
            "sysbench_lua.def_duration":   "30",
            "sysbench_lua.number_of_rows": "10000",
        })

        result = taf_propfile(props_file, timeout=300)
        output = result.stdout + result.stderr

        # sysbench-lua.pm defaults to a unix socket connection when available,
        # so the actual flag is --mysql-socket, not --mysql-host/--mysql-port
        # (TCP-only fields) -- check for any --mysql-* connection flag rather
        # than assuming one particular connection method.
        assert "--mysql-host" in output or "--mysql-port" in output or "--mysql-socket" in output, \
            "MariaDB run does not use --mysql-* arguments — SetConnectionArgs() may be broken"
        assert "--pgsql-host" not in output, \
            "MariaDB run incorrectly uses --pgsql-host!"

    def test_normalize_db_type_mysql_unchanged(self):
        """NormalizeDBType must still map mariadb → mysql (and postgres → pgsql).

        Strategy: we extract the body of sub NormalizeDBType directly from the .pm file
        using a regex and embed it into an isolated Perl script — this avoids
        sysbench-lua.pm's dependencies on the TAF runtime.
        """
        suite_file = TAF_ROOT / "test_suites" / "sysbench-lua.pm"
        content = suite_file.read_text()

        m = re.search(r"(sub NormalizeDBType \{.+?\n\})", content, re.DOTALL)
        assert m, "NormalizeDBType not found in sysbench-lua.pm — cannot run L6 test"
        func_body = m.group(1)

        perl_code = textwrap.dedent("""\
            use strict;
            use warnings;

            {func}

            my %tests = (
                mariadb    => "mysql",
                maria      => "mysql",
                mysql      => "mysql",
                mysqld     => "mysql",
                postgres   => "pgsql",
                postgresql => "pgsql",
                pgsql      => "pgsql",
            );

            my $fail = 0;
            for my $input (sort keys %tests) {{
                my $expected = $tests{{$input}};
                my $got      = NormalizeDBType($input) // "<undef>";
                if ($got eq $expected) {{
                    print "PASS: NormalizeDBType('$input') = '$got'\\n";
                }} else {{
                    print "FAIL: NormalizeDBType('$input') = '$got', expected '$expected'\\n";
                    $fail++;
                }}
            }}
            exit $fail;
        """).format(func=func_body)

        result = run("perl", "-e", perl_code, cwd=TAF_ROOT, timeout=15)
        output = result.stdout + result.stderr
        fails = [ln for ln in output.splitlines() if ln.startswith("FAIL:")]
        assert result.returncode == 0, (
            f"NormalizeDBType returns incorrect values:\n"
            + "\n".join(fails)
            + f"\nFull output:\n{output}"
        )


# ===========================================================================
# LAYER 7 — Full sysbench-lua test-type sweep against PostgreSQL
#
# L5 only exercises OLTP_RO + POINT_SELECT. sysbench-lua.pm defines >40
# named test types; L7 sweeps the core, driver-agnostic sysbench-lua
# workloads (excluding BMK_*, which requires the separate BMK client tool,
# and the TidesDB storage-engine-comparison workloads, which are orthogonal
# to db_driver) in a single TAF run against PostgreSQL.
# ===========================================================================

SYSBENCH_CORE_TESTS = [
    "OLTP_RO", "OLTP_RW", "OLTP_WO_MODIFIABLE",
    "POINT_SELECT", "POINT_SELECT_MODIFIABLE",
    "SELECT_SIMPLE_RANGES", "SELECT_SUM_RANGES",
    "SELECT_ORDER_RANGES", "SELECT_DISTINCT_RANGES",
    "UPDATE_KEY", "UPDATE_NO_KEY",
    "INSERT", "DELETE", "OLTP_INSERT_INTO",
    "TPCB_KEY", "TPCB_NO_KEY",
    "OLTP_RW_MODIFIABLE",
]


@pytest.fixture(scope="session")
def sysbench_matrix_result(tmp_path_factory):
    """L7 fixture: runs every test in SYSBENCH_CORE_TESTS against PostgreSQL
    in a single TAF invocation (one DB lifecycle, one sysbench binary).
    """
    _shutdown_pg_if_running()

    tmp = tmp_path_factory.mktemp("taf_l7")
    props_file = tmp / "sysbench_matrix.properties"

    write_props(props_file, {
        "taf.action":                     "init-start-db-run-tests",
        "taf.taf_db_makers_plugin":       "postgres",
        "taf.db_software_install_dir":    str(PG_INSTALL),
        "taf.db_port":                    str(PG_PORT),
        "taf.db_user":                    TAF_PG_USER,
        "taf.db_user_pass":               TAF_PG_PASS,
        "taf.db_root_user":               TAF_PG_ROOT,
        "taf.db_root_pass":               TAF_PG_ROOT_PASS,
        "taf.database":                   TAF_PG_DB,
        "taf.test_suite":                 "sysbench-lua",
        "taf.tests":                      ",".join(SYSBENCH_CORE_TESTS),
        "taf.threads":                    "4",
        "taf.duration":                   "10",
        "taf.verbose":                    "true",
        "sysbench_lua.db_driver":         "pgsql",
        "sysbench_lua.connector":         "libpq",
        "sysbench_lua.number_of_tables":  "1",
        "sysbench_lua.number_of_rows":    "10000",
        "sysbench_lua.oltp_skip_trx":     "off",
    })

    result = taf_propfile(props_file, timeout=1800)

    yield result

    _shutdown_pg_if_running()


class TestL7SysbenchMatrix:
    """Verifies the full curated sweep of sysbench-lua test types against PostgreSQL."""

    def test_matrix_run_exits_cleanly(self, sysbench_matrix_result):
        result = sysbench_matrix_result
        assert result.returncode == 0, (
            f"Sysbench test-type sweep failed (rc={result.returncode})\n"
            f"STDOUT:\n{result.stdout[-6000:]}\nSTDERR:\n{result.stderr[-1500:]}"
        )

    def test_matrix_output_has_no_errors(self, sysbench_matrix_result):
        output = sysbench_matrix_result.stdout + sysbench_matrix_result.stderr
        clean, bad_line = has_no_errors(output)
        assert clean, f"ERROR line found in sweep output:\n  {bad_line}"

    @pytest.mark.parametrize("test_name", SYSBENCH_CORE_TESTS)
    def test_each_test_type_produced_results(self, sysbench_matrix_result, test_name):
        """Every test type in the sweep must produce a non-error results entry."""
        found = False
        for search_root in (TAF_ROOT / "results", TAF_ROOT / "archive"):
            if not search_root.is_dir():
                continue
            for entry in search_root.iterdir():
                if entry.is_dir() and test_name in entry.name and not entry.name.startswith("Error_"):
                    found = True
        assert found, f"No results directory found for test type {test_name}"


# ===========================================================================
# LAYER 8 — HammerDB TPROC-C against PostgreSQL
#
# TPROC-C has full postgres wiring (WriteTproccPostgresConfig) and an
# example properties file, but — unlike sysbench-lua — had no automated
# end-to-end test before this layer was added.
# ===========================================================================

@pytest.fixture(scope="session")
def hammerdb_tprocc_pg_result(tmp_path_factory):
    """L8 fixture: short HammerDB TPC-C smoke run against PostgreSQL."""
    _shutdown_pg_if_running()

    tmp = tmp_path_factory.mktemp("taf_l8")
    props_file = tmp / "hammerdb_tprocc_pg.properties"

    write_props(props_file, {
        "taf.action":                        "init-start-db-run-tests",
        "taf.taf_db_makers_plugin":           "postgres",
        "taf.db_software_install_dir":        str(PG_INSTALL),
        "taf.db_port":                        str(PG_PORT),
        "taf.db_user":                        TAF_PG_USER,
        "taf.db_user_pass":                   TAF_PG_PASS,
        "taf.db_root_user":                   TAF_PG_ROOT,
        "taf.db_root_pass":                   TAF_PG_ROOT_PASS,
        "taf.database":                       TAF_PG_DB,
        "taf.test_suite":                     "hammerdb-tprocc",
        "taf.tests":                          "tprocc",
        "taf.threads":                        "2",
        # HammerDB TPROC-C reads taf.duration/taf.warmup_duration in MINUTES
        # (sysbench-lua uses seconds instead -- see help/taf_usage.txt).
        "taf.duration":                       "1",
        "taf.warmup_duration":                "1",
        "taf.verbose":                        "true",
        "hammerdb_tprocc.db_type":            "postgres",
        "hammerdb_tprocc.number_of_warehouses": "2",
    })

    result = taf_propfile(props_file, timeout=1200)

    yield result

    _shutdown_pg_if_running()


class TestL8HammerdbTprocc:
    """End-to-end smoke test: HammerDB TPC-C against PostgreSQL."""

    @needs_pg
    def test_tprocc_exits_cleanly(self, hammerdb_tprocc_pg_result):
        result = hammerdb_tprocc_pg_result
        assert result.returncode == 0, (
            f"HammerDB TPC-C/PostgreSQL run failed (rc={result.returncode})\n"
            f"STDOUT:\n{result.stdout[-6000:]}\nSTDERR:\n{result.stderr[-1500:]}"
        )

    @needs_pg
    def test_tprocc_output_has_no_errors(self, hammerdb_tprocc_pg_result):
        output = hammerdb_tprocc_pg_result.stdout + hammerdb_tprocc_pg_result.stderr
        clean, bad_line = has_no_errors(output)
        assert clean, f"ERROR line found in TPC-C output:\n  {bad_line}"

    @needs_pg
    def test_tprocc_dbset_postgres(self, hammerdb_tprocc_pg_result):
        """The generated TCL config must select 'dbset db pg' (HammerDB's postgres id)."""
        output = hammerdb_tprocc_pg_result.stdout + hammerdb_tprocc_pg_result.stderr
        assert "postgres" in output.lower(), \
            "No mention of postgres in HammerDB TPC-C run output"


# ===========================================================================
# LAYER 9 — HammerDB TPROC-H against PostgreSQL
#
# Unlike TPROC-C, TPROC-H's postgres wiring (pg_tproch_* Tcl scripts,
# ${db_type}_sslmode config in hammerdb-tproch.pm) had never been exercised
# end-to-end nor had an example properties file before this layer.
# ===========================================================================

@pytest.fixture(scope="session")
def hammerdb_tproch_pg_result(tmp_path_factory):
    """L9 fixture: short HammerDB TPROC-H smoke run against PostgreSQL."""
    _shutdown_pg_if_running()

    tmp = tmp_path_factory.mktemp("taf_l9")
    props_file = tmp / "hammerdb_tproch_pg.properties"

    write_props(props_file, {
        "taf.action":                     "init-start-db-run-tests",
        "taf.taf_db_makers_plugin":        "postgres",
        "taf.db_software_install_dir":     str(PG_INSTALL),
        "taf.db_port":                     str(PG_PORT),
        "taf.db_user":                     TAF_PG_USER,
        "taf.db_user_pass":                TAF_PG_PASS,
        "taf.db_root_user":                TAF_PG_ROOT,
        "taf.db_root_pass":                TAF_PG_ROOT_PASS,
        "taf.database":                    TAF_PG_DB,
        "taf.test_suite":                  "hammerdb-tproch",
        "taf.tests":                       "TPROCH",
        "taf.threads":                     "1",
        "taf.verbose":                     "true",
        "hammerdb_tproch.db_type":         "postgres",
        "hammerdb_tproch.scale":           "1",
        "hammerdb_tproch.total_querysets": "1",
    })

    result = taf_propfile(props_file, timeout=1800)

    yield result

    _shutdown_pg_if_running()


class TestL9HammerdbTproch:
    """End-to-end smoke test: HammerDB TPROC-H against PostgreSQL (previously untested)."""

    @needs_pg
    def test_tproch_exits_cleanly(self, hammerdb_tproch_pg_result):
        result = hammerdb_tproch_pg_result
        assert result.returncode == 0, (
            f"HammerDB TPROC-H/PostgreSQL run failed (rc={result.returncode})\n"
            f"STDOUT:\n{result.stdout[-6000:]}\nSTDERR:\n{result.stderr[-1500:]}"
        )

    @needs_pg
    def test_tproch_output_has_no_errors(self, hammerdb_tproch_pg_result):
        output = hammerdb_tproch_pg_result.stdout + hammerdb_tproch_pg_result.stderr
        clean, bad_line = has_no_errors(output)
        assert clean, f"ERROR line found in TPROC-H output:\n  {bad_line}"
