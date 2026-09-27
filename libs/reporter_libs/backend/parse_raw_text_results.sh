#!/bin/bash

DEBUG=0

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
WORKING="$SCRIPT_DIR/working"

JAR="$WORKING/BackendParser.jar"
DEFAULT_BACKEND_CONF="$WORKING/backend.conf"

dbg "SCRIPT_DIR=$SCRIPT_DIR"
dbg "WORKING=$WORKING"

# ============================================================
#  Resolve client jar (auto-detect unless overridden)
# ============================================================
if [ $CLIENT_PROVIDED -eq 0 ]; then
    CLIENT="$(ls "$WORKING"/mariadb-java-client*.jar 2>/dev/null | head -n 1)"
    if [ -z "$CLIENT" ]; then
        echo "Error: No JDBC client jar found in $WORKING"
        exit 1
    fi
    CLIENT="$(readlink -f "$CLIENT")"
    echo "Using JDBC client: $CLIENT"
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
#  Resolve JSON jar (auto-detect unless overridden)
# ============================================================
if [ $JSON_PROVIDED -eq 0 ]; then
    JSONJAR="$(ls "$WORKING"/json*.jar 2>/dev/null | head -n 1)"
    if [ -z "$JSONJAR" ]; then
        echo "Error: No JSON library found in $WORKING"
        exit 1
    fi
    JSONJAR="$(readlink -f "$JSONJAR")"
fi

if [ ! -f "$JSONJAR" ]; then
    echo "Error: JSON jar not found: $JSONJAR"
    exit 1
fi

dbg "JSONJAR=$JSONJAR"

# ============================================================
#  Print summary
# ============================================================
echo "Using JSON library: $JSONJAR"
echo "Using JDBC client:  $CLIENT"
echo "Using backend.conf: $BACKENDCFG"
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

    cat "$RAWFILE" | \
        /usr/bin/java \
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

exec /usr/bin/java \
    -cp "$JAR:$CLIENT:$JSONJAR" \
    taf.backend.parser.TafBackendCli \
    --raw-results-file "$RAWFILE" \
    "${ARGS[@]}"
