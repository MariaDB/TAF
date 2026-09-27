#!/bin/sh
#===============================================================================
# build_backend_parser.sh
# TAF-Backend-Parser Version: 1.1
#
# Created: May 2026
# Last Modified: July 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2026 MariaDB Foundation and Jonathan "jeb" Miller
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
#     Build the TAF backend parser into BackendParser.jar. This script compiles
#     all Java sources under backend_parser/source, uses the JSON library from
#     backend/working/lib, generates a manifest with the correct Main-Class
#     entry, and packages the compiled classes into a reproducible JAR.
#
# SCOPE OF THIS SCRIPT:
#     - Verify this script is running inside reporter_libs/backend/.
#     - Ensure backend/working and backend/working/lib exist (create if missing).
#     - Clean old .class files without removing configuration files.
#     - Compile Java sources with all required libraries under backend/working/lib.
#     - Generate a manifest for TafBackendCli.
#     - Produce BackendParser.jar in backend/working/.
#
# NOTES:
#     This script assumes the unified backend layout where all runtime artifacts
#     (BackendParser.jar, BackendDataGetter.jar, JDBC drivers, JSON libraries)
#     live under reporter_libs/backend/working/. Any change to directory layout,
#     classpath requirements, or main entry point must be reflected in this
#     header and in the TAF manual.
#===============================================================================
#------------------------------------------------------------------------------
# Ensure script is running inside reporter_libs/backend/
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(basename "$SCRIPT_DIR")"

if [ "$PARENT" != "backend" ]; then
    echo "ERROR: build_backend_parser.sh must live inside reporter_libs/backend/"
    echo "Current directory: $SCRIPT_DIR"
    exit 1
fi

#------------------------------------------------------------------------------
# Define unified working directory and source tree
#------------------------------------------------------------------------------
SRC_ROOT="$SCRIPT_DIR/backend_parser/source"
OUT="$SCRIPT_DIR/working"
JAR="$OUT/BackendParser.jar"
MANIFEST="$OUT/manifest.txt"

#------------------------------------------------------------------------------
# Ensure working directory exists
#------------------------------------------------------------------------------
if [ ! -d "$OUT" ]; then
    echo "Creating backend/working directory..."
    mkdir -p "$OUT"
fi

#------------------------------------------------------------------------------
# Required runtime jars (must exist directly in backend/working/)
#------------------------------------------------------------------------------
JSON_JAR="$OUT/json-20260522.jar"
JDBC_JAR="$OUT/mariadb-java-client.jar"

if [ ! -f "$JSON_JAR" ]; then
    echo "ERROR: Required JSON library not found:"
    echo "       $JSON_JAR"
    exit 1
fi

if [ ! -f "$JDBC_JAR" ]; then
    echo "ERROR: Required JDBC driver not found:"
    echo "       $JDBC_JAR"
    exit 1
fi

#------------------------------------------------------------------------------
# Clean old .class files and old jar
#------------------------------------------------------------------------------
find "$OUT" -name "*.class" -delete
rm -f "$JAR"

#------------------------------------------------------------------------------
# Compile ALL Java sources under backend_parser/source/
#------------------------------------------------------------------------------
echo "Compiling Java sources..."
javac -cp "$OUT/*" -d "$OUT" $(find "$SRC_ROOT" -name "*.java") || {
    echo "Compilation failed"
    exit 1
}

#------------------------------------------------------------------------------
# Generate manifest (Main-Class + Class-Path)
#------------------------------------------------------------------------------
echo "Main-Class: taf.backend.parser.TafBackendCli" > "$MANIFEST"
echo "Class-Path: json-20260522.jar mariadb-java-client.jar" >> "$MANIFEST"

#------------------------------------------------------------------------------
# Package jar
#------------------------------------------------------------------------------
echo "Packaging BackendParser.jar..."
jar cfm "$JAR" "$MANIFEST" -C "$OUT" .

echo "BackendParser.jar successfully built in:"
echo "    $JAR"
