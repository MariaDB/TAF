package taf.backend.parser;
/******************************************************************************
 * WorkloadDetector.java
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
 *     Detect the workload type of raw test output based on known signature
 *     strings. This module normalizes input lines and applies stable matching
 *     rules to classify results as Sysbench Lua, HammerDB TPROC-C, HammerDB
 *     TPROC-H, or UNKNOWN.
 *
 * SCOPE OF THIS MODULE:
 *     - Join and normalize raw text lines.
 *     - Match against workload specific signature patterns.
 *     - Return a stable WorkloadType enum for downstream parsing logic.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not parse metrics or extract values.
 *     - Does not validate correctness or interpret semantics.
 *     - Does not perform ingest or reporting actions.
 *
 * NOTES:
 *     Signature rules must remain stable. Any change to workload detection
 *     requires coordinated updates across RawResultParser, reporting, and
 *     ingest components.
 ******************************************************************************/
import java.util.List;

public class WorkloadDetector {

    // ------------------------------------------------------------
    // Detect workload type from raw structured Ruby-style output
    // ------------------------------------------------------------
    public static WorkloadType detect(List<String> lines) {

        // Join and normalize
        String lower = String.join("\n", lines).toLowerCase();

        // ------------------------------------------------------------
        // Detect HammerDB TPROC-H (TPCH-style)
        // ------------------------------------------------------------
        // Real signatures from your raw files:
        // - "geometricmean"
        // - "query1", "query2", ... "query22"
        // - "hammerdb-tproch"
        // - "total_querysets"
        if (lower.contains("geometricmean") ||
            lower.contains("query1") ||
            lower.contains("hammerdb-tproch") ||
            lower.contains("total_querysets")) {

            return WorkloadType.HAMMERDB_TPROCH;
        }

        // ------------------------------------------------------------
        // Detect HammerDB TPROC-C
        // ------------------------------------------------------------
        // Real signatures from your raw files:
        // - "nopm"
        // - "tpm"
        // - "neword_ratio"
        // - "payment_ratio"
        // - "warehouses"
        // - "hammerdb-tprocc"
        if (lower.contains("nopm") ||
            lower.contains("tpm") ||
            lower.contains("neword_ratio") ||
            lower.contains("payment_ratio") ||
            lower.contains("warehouses") ||
            lower.contains("hammerdb-tprocc")) {

            return WorkloadType.HAMMERDB_TPROCC;
        }

        // ------------------------------------------------------------
        // Detect Sysbench-Lua (TAF structured output)
        // ------------------------------------------------------------
        // Real signatures from your raw files:
        // - "total_read_ops"
        // - "total_write_ops"
        // - "events_ps"
        // - "tps"
        // - "queries_per_second"
        // - "sysbench-lua"
        if (lower.contains("total_read_ops") ||
            lower.contains("total_write_ops") ||
            lower.contains("events_ps") ||
            lower.contains("queries_per_second") ||
            lower.contains("sysbench-lua") ||
            lower.contains("oltp_")) {   // catches oltp_insert.lua, oltp_read_write.lua, etc.

            return WorkloadType.SYSBENCH_LUA;
        }

        // ------------------------------------------------------------
        // Unknown workload
        // ------------------------------------------------------------
        return WorkloadType.UNKNOWN;
    }
}
