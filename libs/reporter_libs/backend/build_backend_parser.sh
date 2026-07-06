#!/bin/sh
#===============================================================================
# build_backend_parser.sh
# TAF-Backend-Parser Version: 1.0
#
# Created: May 2026
# Last Modified: June 2026
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
#     all Java sources under backend_parser/source, includes the JSON library
#     on the classpath, generates a manifest with the correct Main-Class entry,
#     and packages the compiled classes into a reproducible JAR.
#
# SCOPE OF THIS SCRIPT:
#     - Clean old .class files without removing configuration files.
#     - Compile Java sources with the JSON library.
#     - Generate a manifest for TafBackendCli.
#     - Produce BackendParser.jar in backend_parser/working.
#
# NOTES:
#     This script assumes a POSIX shell environment. Any change to directory
#     layout, classpath requirements, or main entry point must be reflected in
#     this header and in the TAF manual.
#===============================================================================
SRC=backend_parser/source/taf/backend/parser
OUT=backend_parser/working
JAR=$OUT/BackendParser.jar

# Path to your JSON library
JSON_JAR=backend_parser/working/json-20260522.jar

# ensure working directory exists
mkdir -p $OUT

# remove ONLY old .class files and old jar, NOT configs
find $OUT -name "*.class" -delete
rm -f $JAR

# compile with JSON jar on classpath
javac -cp $JSON_JAR -d $OUT $(find $SRC -name "*.java") || {
    echo "Compilation failed"
    exit 1
}

# correct main class
echo "Main-Class: taf.backend.parser.TafBackendCli" > $OUT/manifest.txt

# package jar
jar cfm $JAR $OUT/manifest.txt -C $OUT .

echo "Built: $JAR"
