package taf.backend.parser;
/******************************************************************************
 * WorkloadType.java
 * TAF-Backend-Parser Version: 1.0
 * 
 * Created: May 2026
 * Last Modified: June 2026
 *
 * This file is part of the Test Automation Framework (TAF).
 * Copyright (c) 2026 MariaDB Foundation and Jonathan "jeb" Miller
 *
 * Licensed under the GNU General Public License, version 2 or later (GPLv2+).
 * See https://www.gnu.org/licenses/ for details.
 *
 * PURPOSE:
 *     Define the set of supported workload types recognized by the TAF backend.
 *     These values classify raw test output and drive workload specific parsing
 *     and metric interpretation in downstream components.
 *
 * SCOPE OF THIS MODULE:
 *     - Provide a stable enumeration of workload identifiers.
 *     - Serve as the return type for workload detection logic.
 *     - Ensure consistent naming across all parser and ingest modules.
 *
 * NOTES:
 *     This enum must remain stable. Any addition or removal of workload types
 *     requires corresponding updates in workload detection, parsing, and
 *     reporting components.
 ******************************************************************************/
public enum WorkloadType {
    SYSBENCH_LUA,
    HAMMERDB_TPROCC,
    HAMMERDB_TPROCH,
    UNKNOWN
}