package taf.backend.parser;
/******************************************************************************
 * PrimaryMetricClassifier.java
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
 *     Determine the primary metric for a workload iteration. This module
 *     inspects parsed metrics, applies workload-specific rules, and assigns
 *     exactly one metric as primary when raw data has not already done so.
 *
 * SCOPE OF THIS MODULE:
 *     - Detect whether a primary metric is already present.
 *     - Apply workload rules:
 *           * HammerDB TPROC-H: GeometricMean
 *           * HammerDB TPROC-C: NOPM
 *           * Sysbench-Lua: TPS or QPS fallback
 *     - Provide deterministic fallback behavior when no rule matches.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not parse raw metrics or extract values.
 *     - Does not validate metric correctness or semantics.
 *     - Does not perform ingest, reporting, or change detection.
 *
 * CONTRACT:
 *     Input:
 *         - WorkloadType for the iteration.
 *         - List<ParsedMetric> with names and types.
 *     Output:
 *         - Exactly one metric marked as "primary".
 *     Requirements:
 *         - Raw data may already specify a primary metric; classifier must
 *           preserve it and perform no further action.
 *
 * NOTES:
 *     Primary metric selection is central to TAF result interpretation. Any
 *     change to workload rules or fallback behavior must be reflected in this
 *     header and in the TAF manual.
 ******************************************************************************/
import java.util.List;

public class PrimaryMetricClassifier {

    public static void classify(WorkloadType type, List<ParsedMetric> metrics) {

        // If raw data already marked a primary metric, do nothing.
        if (hasPrimary(metrics)) {
            return;
        }

        switch (type) {
            case HAMMERDB_TPROCH:
                setPrimaryByName(metrics, "GeometricMean");
                break;

            case HAMMERDB_TPROCC:
                setPrimaryByName(metrics, "NOPM");
                break;

            case SYSBENCH_LUA:
                // Sysbench usually provides type, but if not, fallback:
                classifySysbench(metrics);
                break;

            default:
                // Fallback: first metric becomes primary
                if (!metrics.isEmpty()) {
                    metrics.get(0).type = "primary";
                }
                break;
        }
    }

    private static boolean hasPrimary(List<ParsedMetric> metrics) {
        for (ParsedMetric m : metrics) {
            if ("primary".equalsIgnoreCase(m.type)) {
                return true;
            }
        }
        return false;
    }

    private static void setPrimaryByName(List<ParsedMetric> metrics, String primaryName) {
        for (ParsedMetric m : metrics) {
            if (primaryName.equalsIgnoreCase(m.name)) {
                m.type = "primary";
                return;
            }
        }
        // If not found, fallback to first metric
        if (!metrics.isEmpty()) {
            metrics.get(0).type = "primary";
        }
    }

    private static void classifySysbench(List<ParsedMetric> metrics) {
        ParsedMetric tps = null;
        ParsedMetric qps = null;

        for (ParsedMetric m : metrics) {
            String n = m.name;
            if ("TPS".equalsIgnoreCase(n)) {
                tps = m;
            } else if ("queries_per_second".equalsIgnoreCase(n)
                    || "QPS".equalsIgnoreCase(n)) {
                qps = m;
            }
        }

        if (tps != null) {
            tps.type = "primary";
            return;
        }

        if (qps != null) {
            qps.type = "primary";
            return;
        }

        // Fallback
        if (!metrics.isEmpty()) {
            metrics.get(0).type = "primary";
        }
    }
}
