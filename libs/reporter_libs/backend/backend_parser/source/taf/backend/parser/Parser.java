package taf.backend.parser;
/******************************************************************************
 * Parser.java
 * TAF-Backend-Parser Version: 1.0
 * 
 * Created: May 2026
 * Last Modified: June 2026
 *
 * This file is part of the Test Automation Framework (TAF).
 * Copyright (c) 2026 MariaDB Foundation and Jonathan "jeb" Miller
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; version 2 or later of the License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335
 *
 * Licensed under the GNU General Public License, version 2 or later (GPLv2+).
 * See https://www.gnu.org/licenses/ for details.
 *
 * PURPOSE:
 *     Convert raw line oriented test output into structured key value records
 *     for use by TAF reporting and result processing components. This parser
 *     identifies record boundaries, tokenizes fields, and normalizes values
 *     into a stable internal representation.
 *
 * ARCHITECTURAL ROLE:
 *     - Acts as the first stage in the TAF result processing pipeline.
 *     - Consumes raw text from test clients and transforms it into maps that
 *       downstream components can interpret.
 *     - Provides a deterministic and contributor proof parsing layer that
 *       isolates higher level modules from raw output formats.
 *     - Ensures consistent field naming and normalization across all tests.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not interpret semantics of fields or enforce correctness rules.
 *     - Does not perform result comparison or change detection.
 *     - Does not write reports or archives.
 *     - Does not manage directories or file lifecycles.
 *
 * CONTRACT:
 *     Input:
 *         - Line oriented text stream from a test client.
 *     Output:
 *         - ParsedTestRun representing a single test run with iterations/metrics.
 *     Requirements:
 *         - Caller must provide a valid input stream.
 *         - Parser must not throw on malformed input; it must degrade safely.
 *         - All output keys and values must be normalized consistently.
 *
 * GUARANTEES:
 *     - Parsing is deterministic for identical input.
 *     - Record boundaries are detected using stable rules.
 *     - No implicit interpretation or filtering of fields.
 *     - All failures are explicit and surfaced to the caller.
 *
 * NOTES:
 *     - This parser is a foundational component of TAF result handling.
 *     - Any change to field normalization or record structure must be reflected
 *       in this header and in the TAF manual.
 ******************************************************************************/
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;

public class Parser {

    // ------------------------------------------------------------
    // Unified structured parser for sysbench-lua, TPROC-C, TPROC-H
    // ------------------------------------------------------------
    public static ParsedTestRun parse(List<String> lines,
                                      WorkloadType type,
                                      String filename) throws Exception {

        // Join raw lines
        String raw = String.join("\n", lines);

        // Convert Ruby => List<Map<String,Object>>
        List<Map<String, Object>> runs = RubyHashConverter.convertToList(raw);
        TafBackendCli.debug("Runs parsed: " + runs.size());
        TafBackendCli.debug("First run keys: " + runs.get(0).keySet());

        if (runs == null || runs.isEmpty()) {
            throw new IllegalArgumentException("No runs found in: " + filename);
        }

        // First run contains global metadata
        Map<String, Object> first = runs.get(0);
        Map<String, Object> meta = castMap(first.get("metadata"));
        TafBackendCli.debug("Metadata keys: " + meta.keySet());

        ParsedTestRun tr = new ParsedTestRun();

        // ------------------------------------------------------------
        // Core metadata
        // ------------------------------------------------------------
        tr.testName       = asString(meta.get("test_name"));
        tr.suiteName      = asString(meta.get("test_suite"));
        tr.suiteVersion   = asString(meta.get("test_suite_version"));
        tr.testType       = asString(meta.get("test_type"));
        tr.comments       = asString(meta.get("comments"));

        tr.hostName       = asString(meta.get("test_host"));
        tr.cpuModel       = asString(meta.get("cpu"));
        tr.cpuCount       = asInt(meta.get("cpu_count"));
        tr.coreCount      = asInt(meta.get("core_count"));
        tr.socketCount    = asInt(meta.get("socket_count"));

        tr.ramGb          = parseRamGb(asString(meta.get("ram")));
        tr.ramRaw         = asString(meta.get("ram"));

        tr.osName         = asString(meta.get("os"));
        tr.osVersion      = asString(meta.get("os_version"));
        tr.osKernel       = asString(meta.get("os_kernel"));
        tr.osArch         = asString(meta.get("os_arch"));

        tr.dbMaker        = asString(meta.get("database_maker"));
        tr.dbEngine       = asString(meta.get("database_eng"));
        tr.dbVersion      = asString(meta.get("database_version"));

        tr.tafHarnessName    = asString(meta.get("framework"));
        tr.tafHarnessVersion = asString(meta.get("framework_version"));

        tr.clientProgram  = clientProgramFor(type);
        tr.clientVersion  = asString(meta.get("test_client_version"));

        tr.configName     = asString(meta.get("db_config_file"));
        tr.testTimestamp  = parseTimestamp(asString(meta.get("test_end_date_time")));

        // ------------------------------------------------------------
        // Additional DB metadata
        // ------------------------------------------------------------
        tr.dbUser             = asString(meta.get("db_user"));
        tr.dbRootUser         = asString(meta.get("db_root_user"));
        tr.dbInstallDir       = asString(meta.get("db_install_dir"));

        if (meta.get("port") != null)
            tr.dbPort = asInt(meta.get("port"));

        tr.dbSocket           = asString(meta.get("socket"));
        tr.databaseUnderTest  = asString(meta.get("database_under_test"));

        // ------------------------------------------------------------
        // Warmup metadata
        // ------------------------------------------------------------
        if (meta.get("warmup_threads") != null)
            tr.warmupThreads = asInt(meta.get("warmup_threads"));

        if (meta.get("warmup_duration") != null)
            tr.warmupDuration = asInt(meta.get("warmup_duration"));

        // ------------------------------------------------------------
        // Test suite metadata
        // ------------------------------------------------------------
        if (meta.get("test_suite_revision") != null)
            tr.testSuiteRevision = asInt(meta.get("test_suite_revision"));

        tr.testSuitePmFile = asString(meta.get("test_suite_pm_file"));

        if (meta.get("number_of_rows") != null)
            tr.numberOfRows = asInt(meta.get("number_of_rows"));

        if (meta.get("number_of_tables") != null)
            tr.numberOfTables = asInt(meta.get("number_of_tables"));

        if (meta.get("range_size") != null)
            tr.rangeSize = asInt(meta.get("range_size"));

        // ------------------------------------------------------------
        // Lifecycle metadata (for test_run.test_end_time / test_duration)
        // ------------------------------------------------------------
        tr.testEndTime   = parseTimestamp(asString(meta.get("test_end_date_time")));
        tr.testDuration  = asInt(meta.get("duration"));

        // ------------------------------------------------------------
        // Connector + thread list (command line precedence)
        // ------------------------------------------------------------
        tr.connector  = asString(meta.get("connector"));
        tr.threadList = extractThreadList(meta);

        // ------------------------------------------------------------
        // Workload-specific adjustments
        // ------------------------------------------------------------
        switch (type) {

            case SYSBENCH_LUA:
                // Sysbench already reports number_of_rows / number_of_tables / range_size
                // and connector in metadata; threadList is handled via extractThreadList.
                break;

            case HAMMERDB_TPROCC:
                // TPCC-style: warehouses ~= number_of_tables
                if (meta.get("warehouses") != null)
                    tr.numberOfTables = asInt(meta.get("warehouses"));
                // HammerDB does not report number_of_rows; leave as-is/null.
                break;

            case HAMMERDB_TPROCH:
                // TPCH-style: scale ~= number_of_tables
                if (meta.get("scale") != null)
                    tr.numberOfTables = asInt(meta.get("scale"));
                // HammerDB does not report number_of_rows; leave as-is/null.
                break;

            default:
                // Other workloads: leave defaults / metadata-based values.
                break;
        }

        // ------------------------------------------------------------
        // Store raw metadata map (DbIngest stores as LONGTEXT)
        // ------------------------------------------------------------
        tr.metadata = meta;

        // ------------------------------------------------------------
        // Parse each iteration
        // ------------------------------------------------------------
        for (Map<String, Object> run : runs) {

            Map<String, Object> m = castMap(run.get("metadata"));

            int iterationId = asInt(run.get("iteration_id"));
            int threads     = asInt(m.get("thread_count"));
            String duration = Integer.toString(asInt(m.get("run_duration_seconds")));

            ParsedIteration it = new ParsedIteration(iterationId, threads, duration);

            @SuppressWarnings("unchecked")
            List<Map<String, Object>> metrics =
                (List<Map<String, Object>>) run.getOrDefault("metrics", Collections.emptyList());

            for (Map<String, Object> mm : metrics) {

                if (!mm.containsKey("name")) continue;

                String name       = asString(mm.get("name"));
                String metricType = asString(mm.get("type"));
                String dim        = asString(mm.get("dimension"));
                String unit       = asString(mm.get("unit"));
                double val        = asDouble(mm.get("value"));

                ParsedMetric pm = new ParsedMetric(name, metricType, dim, unit, val);
                it.metrics.add(pm);
            }

            tr.iterations.add(it);
        }

        return tr;
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------
    @SuppressWarnings("unchecked")
    private static Map<String, Object> castMap(Object o) {
        if (o instanceof Map) return (Map<String, Object>) o;
        return Collections.emptyMap();
    }

    private static String asString(Object o) {
        return o == null ? null : o.toString();
    }

    private static int asInt(Object o) {
        if (o == null) return 0;
        if (o instanceof Number) return ((Number) o).intValue();
        return Integer.parseInt(o.toString());
    }

    private static double asDouble(Object o) {
        if (o == null) return 0.0;
        if (o instanceof Number) return ((Number) o).doubleValue();
        return Double.parseDouble(o.toString());
    }

    private static int parseRamGb(String ramStr) {
        if (ramStr == null) return 0;
        String digits = ramStr.replaceAll("[^0-9.]", "");
        if (digits.isEmpty()) return 0;
        return (int)Math.round(Double.parseDouble(digits));
    }

    private static final DateTimeFormatter FLEX_TS =
        DateTimeFormatter.ofPattern("yyyy-M-d H:mm:ss");

    private static LocalDateTime parseTimestamp(String ts) {
        if (ts == null) return null;
        ts = ts.replace("T", " ").split("\\.")[0].trim();
        return LocalDateTime.parse(ts, FLEX_TS);
    }

    // Command-line–first thread list extraction:
    // 1) taf.threads=...
    // 2) --threads=...
    // 3) metadata["threads"]
    private static String extractThreadList(Map<String,Object> meta) {
        String cmd = asString(meta.get("taf_commandline"));
        if (cmd != null) {

            int idx = cmd.indexOf("taf.threads=");
            if (idx >= 0) {
                String sub = cmd.substring(idx + "taf.threads=".length());
                int end = sub.indexOf(' ');
                if (end > 0) sub = sub.substring(0, end);
                return sub.trim();
            }

            idx = cmd.indexOf("--threads=");
            if (idx >= 0) {
                String sub = cmd.substring(idx + "--threads=".length());
                int end = sub.indexOf(' ');
                if (end > 0) sub = sub.substring(0, end);
                return sub.trim();
            }
        }

        Object t = meta.get("threads");
        if (t != null) return t.toString();

        return null;
    }

    private static String clientProgramFor(WorkloadType type) {
        switch (type) {
            case SYSBENCH_LUA: return "sysbench-lua";
            case HAMMERDB_TPROCC:
            case HAMMERDB_TPROCH: return "HammerDB";
            default: return "unknown";
        }
    }
}
