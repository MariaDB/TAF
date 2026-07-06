#!/bin/bash
#===============================================================================
# backend_parser_run.sh
# TAF-Backend-Parser Version: 1.0
#
# Created: May 2026
# Last Modified: June 2026
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
#     Execute the TAF backend parser (BackendParser.jar) in either STDIN mode
#     or file mode. This script resolves all required paths, validates the
#     JDBC client and JSON libraries, loads backend configuration, and invokes
#     TafBackendCli with the correct arguments.
#
# SCOPE OF THIS SCRIPT:
#     - Detect raw results file unless --stdin is used.
#     - Resolve backend.conf, JDBC client JAR, and JSON library JAR.
#     - Validate BackendParser.jar in backend_parser/working.
#     - Execute TafBackendCli in STDIN or file mode with full argument passthrough.
#
# NOTES:
#     This script assumes a POSIX shell environment and a standard backend
#     directory layout. Any change to directory structure, library names, or
#     parser invocation semantics must be reflected in this header and in the
#     TAF manual.
#===============================================================================
# ============================================================
#  Debug helper
# ============================================================
DEBUG=1   # set to 0 to disable debug output

dbg() {
    if [ $DEBUG -eq 1 ]; then
        echo "DEBUG: $*" >&2
    fi
}

# ============================================================
#  Help
# ============================================================
show_help() {
    cat <<EOF
Usage: $(basename "$0") <raw-results-file> [options]

Options:
  --stdin                             Read raw results from STDIN instead of file
  --db-config-file <path>             Full path to DB config file
  --client-jar <path>                 Full path to JDBC client JAR
  --backend-config <path>             Full path to backend.conf
  --json-jar <path>                   Full path to JSON library JAR
  --help                              Show this help message and exit
EOF
}

# ============================================================
#  Flags
# ============================================================
STDIN_MODE=0
DBCFG_PROVIDED=0
CLIENT_PROVIDED=0
BACKENDCFG_PROVIDED=0
JSON_PROVIDED=0

# ============================================================
#  Help shortcut
# ============================================================
if [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

ARGS=()

# ============================================================
#  Detect raw file (unless stdin mode)
# ============================================================
if [[ -n "$1" && "$1" != --* ]]; then
    RAWFILE="$(readlink -f "$1")"
    shift

    if [ ! -f "$RAWFILE" ]; then
        echo "Error: file not found: $RAWFILE"
        exit 1
    fi

    dbg "RAWFILE detected: $RAWFILE"
fi

# ============================================================
#  Parse flags
# ============================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stdin)
            STDIN_MODE=1
            dbg "STDIN mode enabled"
            shift
            ;;
        --db-config-file)
            DBCFG_PROVIDED=1
            CFG="$(readlink -f "$2")"
            dbg "DB config file: $CFG"
            ARGS+=("$1" "$CFG")
            shift 2
            ;;
        --client-jar)
            CLIENT_PROVIDED=1
            CLIENT="$(readlink -f "$2")"
            dbg "Client JAR override: $CLIENT"
            shift 2
            ;;
        --backend-config)
            BACKENDCFG_PROVIDED=1
            BACKENDCFG="$(readlink -f "$2")"
            dbg "Backend config override: $BACKENDCFG"
            shift 2
            ;;
        --json-jar)
            JSON_PROVIDED=1
            JSONJAR="$(readlink -f "$2")"
            dbg "JSON JAR override: $JSONJAR"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            dbg "Passthrough arg: $1"
            ARGS+=("$1")
            shift
            ;;
    esac
done

# ============================================================
#  Resolve working paths
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKING="$SCRIPT_DIR/backend_parser/working"

JAR="$WORKING/BackendParser.jar"
DEFAULT_BACKEND_CONF="$WORKING/backend.conf"

dbg "SCRIPT_DIR=$SCRIPT_DIR"
dbg "WORKING=$WORKING"

# ============================================================
#  Resolve client jar
# ============================================================
if [ $CLIENT_PROVIDED -eq 0 ]; then
    CLIENT="$WORKING/mariadb-java-client-3.5.8.jar"
    echo "Warning: no --client-jar provided. Using default: $CLIENT"
fi

if [ ! -f "$CLIENT" ]; then
    echo "Error: client jar not found: $CLIENT"
    exit 1
fi

# ============================================================
#  Validate BackendParser.jar
# ============================================================
if [ ! -f "$JAR" ]; then
    echo "Error: BackendParser.jar not found in $WORKING"
    exit 1
fi

# ============================================================
#  Resolve backend config
# ============================================================
if [ $BACKENDCFG_PROVIDED -eq 1 ]; then
    if [ ! -f "$BACKENDCFG" ]; then
        echo "Error: backend config file not found: $BACKENDCFG"
        exit 1
    fi
else
    BACKENDCFG="$DEFAULT_BACKEND_CONF"
    if [ ! -f "$BACKENDCFG" ]; then
        echo "Error: default backend.conf not found in $WORKING"
        exit 1
    fi
fi

ARGS+=(--backend-config "$BACKENDCFG")
dbg "Backend config resolved: $BACKENDCFG"

# ============================================================
#  Resolve JSON jar
# ============================================================
if [ $JSON_PROVIDED -eq 1 ]; then
    if [ ! -f "$JSONJAR" ]; then
        echo "Error: JSON jar not found: $JSONJAR"
        exit 1
    fi
else
    JSONJAR="$(ls "$WORKING"/json*.jar 2>/dev/null | head -n 1)"
    if [ -z "$JSONJAR" ]; then
        echo "Error: No JSON library found in $WORKING"
        exit 1
    fi
    JSONJAR="$(readlink -f "$JSONJAR")"
fi

dbg "JSONJAR=$JSONJAR"

# ============================================================
#  Print summary
# ============================================================
echo "Using JSON library: $JSONJAR"
echo "Using backend config: $BACKENDCFG"
echo

echo "Running parser with arguments:"
printf '  %s\n' "${ARGS[@]}"
echo

# ============================================================
#  EXECUTION: STDIN MODE
# ============================================================
if [ $STDIN_MODE -eq 1 ]; then

    if [ -z "$RAWFILE" ]; then
        echo "Error: --stdin requires a raw results file argument"
        exit 1
    fi

    dbg "Entering STDIN execution branch"
    dbg "Piping RAWFILE into Java: $RAWFILE"

    dbg "Executing: cat \"$RAWFILE\" | java -cp \"$JAR:$CLIENT:$JSONJAR\" taf.backend.parser.TafBackendCli --stdin ${ARGS[*]}"

    cat "$RAWFILE" | \
        /usr/lib/jvm/java-11/bin/java \
            -cp "$JAR:$CLIENT:$JSONJAR" \
            taf.backend.parser.TafBackendCli \
            --stdin \
            "${ARGS[@]}"

    exit $?
fi

# ============================================================
#  EXECUTION: FILE MODE
# ============================================================
dbg "Entering FILE execution branch"
dbg "Executing: java -cp \"$JAR:$CLIENT:$JSONJAR\" taf.backend.parser.TafBackendCli --raw-results-file \"$RAWFILE\" ${ARGS[*]}"

exec /usr/lib/jvm/java-11/bin/java \
    -cp "$JAR:$CLIENT:$JSONJAR" \
    taf.backend.parser.TafBackendCli \
    --raw-results-file "$RAWFILE" \
    "${ARGS[@]}"
