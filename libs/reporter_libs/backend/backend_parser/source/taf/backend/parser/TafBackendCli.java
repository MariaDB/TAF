package taf.backend.parser;
/******************************************************************************
 * TafBackendCli.java
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
 *     Provide the command line interface for the TAF backend. This module
 *     implements all user facing backend operations including raw result
 *     processing, baseline comparison, and baseline creation. It coordinates
 *     parser invocation, configuration loading, and database ingest actions
 *     to produce a complete backend workflow.
 *
 * SCOPE OF THIS MODULE:
 *     - Parse and validate CLI arguments and enforce mode exclusivity.
 *     - Load backend configuration and optional DB parameter metadata.
 *     - Read raw test output from file or stdin and invoke RawResultParser.
 *     - Ingest system identity, configuration, test run metadata, and
 *       iteration results into the backend database.
 *     - Perform baseline comparison for an existing run.
 *     - Mark a run as the baseline for its test and configuration.
 *     - Provide deterministic exit codes for automation and CI integration.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not parse raw test output (delegates to RawResultParser).
 *     - Does not implement SQL or database schema logic (delegates to DbIngest).
 *     - Does not perform metric comparison or change detection logic.
 *     - Does not interpret test semantics or enforce correctness rules.
 *
 * CONTRACT:
 *     - Exactly one mode must be selected: process, compare, set-baseline,
 *       or stdin processing.
 *     - backend.conf must be readable and valid.
 *     - Raw results must be provided via file or stdin in process mode.
 *     - All failures must be explicit and produce a nonzero exit code.
 *
 * NOTES:
 *     This module defines the public CLI behavior of the TAF backend. Any
 *     change to mode semantics, ingest workflow, or configuration handling
 *     must be reflected in this header and in the TAF manual.
 ******************************************************************************/
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;

public class TafBackendCli {

    private static final Logger LOG = Logger.getLogger(TafBackendCli.class.getName());
    public static boolean DEBUG = true;

    public static void main(String[] args) {
        CliArgs cli;
        try {
            cli = CliArgs.parse(args);
        } catch (Exception e) {
            System.out.println("Error: " + e.getMessage());
            printUsage();
            System.exit(1);
            return;
        }

        if (cli.isHelp()) {
            printUsage();
            System.exit(0);
            return;
        }

        if (!validateMode(cli)) {
            printUsage();
            System.exit(1);
            return;
        }

        if (!loadBackendConfig(cli)) {
            System.exit(2);
            return;
        }

        if (cli.isProcessMode() || cli.stdinMode) {
            int rc = runProcess(cli);
            System.exit(rc);
        }

        if (cli.isCompareMode()) {
            int rc = runCompare(cli);
            System.exit(rc);
        }

        if (cli.isSetBaselineMode()) {
            int rc = runSetBaseline(cli);
            System.exit(rc);
        }
    }

    public static void debug(String msg) {
        if (DEBUG) System.out.println(msg);
    }

    // ------------------------------------------------------------
    // Mode validation
    // ------------------------------------------------------------
    private static boolean validateMode(CliArgs cli) {
        int modes = 0;
        if (cli.isProcessMode())     modes++;
        if (cli.isCompareMode())     modes++;
        if (cli.isSetBaselineMode()) modes++;
        if (cli.stdinMode) modes++;

        if (modes == 0) {
            System.out.println("Error: must specify one of --raw-results-file, --run-id, or --set-baseline.");
            return false;
        }

        if (modes > 1) {
            System.out.println("Error: only one mode may be used at a time.");
            return false;
        }

        if (cli.isProcessMode() && !cli.stdinMode && (cli.rawResultsFile == null || cli.rawResultsFile.isBlank())) {
            System.out.println("Error: --raw-results-file requires a valid path unless --stdin is used.");
            return false;
        }

        if (cli.isProcessMode() && (cli.rawResultsFile == null || cli.rawResultsFile.isBlank())) {
            System.out.println("Error: --raw-results-file requires a valid path.");
            return false;
        }

        if (cli.isCompareMode() && cli.runId <= 0) {
            System.out.println("Error: --run-id must be a positive integer.");
            return false;
        }

        if (cli.isSetBaselineMode() && cli.setBaselineId <= 0) {
            System.out.println("Error: --set-baseline requires a positive run id.");
            return false;
        }

        return true;
    }

    // ------------------------------------------------------------
    // Load backend.conf
    // ------------------------------------------------------------
    private static boolean loadBackendConfig(CliArgs cli) {
        try {
            DbConfig.load(cli.backendConfigPath);
            return true;
        } catch (Exception e) {
            System.out.println("Failed to load backend config: " + e.getMessage());
            LOG.log(Level.SEVERE, "Config load failed", e);
            return false;
        }
    }

    // ------------------------------------------------------------
    // PROCESS MODE
    // ------------------------------------------------------------
    private static int runProcess(CliArgs cli) {

        ParsedTestRun parsed = null;

        try {
            // ------------------------------------------------------------
            // Determine input source: file or stdin
            // ------------------------------------------------------------
            if (cli.stdinMode) {
                debug("Reading raw results from STDIN");

                String rawText = new String(System.in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);

                if (rawText == null || rawText.isBlank()) {
                    System.out.println("Error: no raw results received on stdin.");
                    return 3;
                }

                parsed = RawResultParser.parse(rawText);

            } else {
                // Existing file mode
                File f = new File(cli.rawResultsFile);

                if (!f.exists() || !f.canRead()) {
                    System.out.println("Error: cannot read file: " + cli.rawResultsFile);
                    return 3;
                }

                debug("Reading raw results: " + cli.rawResultsFile);
                parsed = RawResultParser.parse(Path.of(cli.rawResultsFile));
            }

            // ------------------------------------------------------------
            // Validate parser output
            // ------------------------------------------------------------
            if (parsed == null) {
                System.out.println("Error: parser returned no data.");
                return 4;
            }

            // ------------------------------------------------------------
            // Load DB config file (optional)
            // ------------------------------------------------------------
            if (cli.dbConfigFile != null) {
                debug("Loading DB config file: " + cli.dbConfigFile);

                try {
                	List<String> lines = Files.readAllLines(Path.of(cli.dbConfigFile), java.nio.charset.StandardCharsets.UTF_8);
                    List<Map<String, String>> params = new ArrayList<>();

                    for (String line : lines) {
                        line = line.trim();

                        if (line.isEmpty() || line.startsWith("#") || line.startsWith(";"))
                            continue;

                        if (line.startsWith("[") && line.endsWith("]"))
                            continue;

                        int eq = line.indexOf('=');
                        if (eq > 0) {
                            String name  = line.substring(0, eq).trim().toLowerCase();
                            String value = line.substring(eq + 1).trim();
                            if (value == null) value = "";
                            Map<String, String> entry = new HashMap<>();
                            entry.put("name", name);
                            entry.put("value", value);
                            params.add(entry);
                            continue;
                        }

                        // flag with no value
                        String name = line.toLowerCase();
                        Map<String, String> entry = new HashMap<>();
                        entry.put("name", name);
                        entry.put("value", "");
                        params.add(entry);
                    }

                    Map<String, Object> blob = new HashMap<>();
                    blob.put("parameters", params);

                    parsed.configJsonBlob = JsonUtil.toJson(blob);
                    parsed.configName = Path.of(cli.dbConfigFile).getFileName().toString();

                } catch (Exception e) {
                    System.out.println("Error: cannot read DB config file: " + cli.dbConfigFile);
                    return 2;
                }

            } else {
                System.out.println("WARNING: No --db-config-file provided. Using placeholder config.");
                Map<String, Object> blob = new HashMap<>();
                blob.put("parameters", new ArrayList<Map<String, String>>());
                parsed.configJsonBlob = JsonUtil.toJson(blob);
                parsed.configName = "NO_CONFIG";
            }

            // ------------------------------------------------------------
            // Debug dump
            // ------------------------------------------------------------
            if (DEBUG) {
                System.out.println("=== ParsedTestRun (top-level) ===");
                System.out.println("testName=" + parsed.testName);
                System.out.println("suiteName=" + parsed.suiteName);
                System.out.println("configName=" + parsed.configName);
                System.out.println("configJsonBlob=" + parsed.configJsonBlob);
                System.out.println("iterations=" + parsed.iterations.size());
                System.out.println("metadata keys=" + parsed.metadata.keySet());
                System.out.println("=================================");
            }

            // ------------------------------------------------------------
            // DB ingest
            // ------------------------------------------------------------
            long systemId  = DbIngest.insertSystemIdentity(parsed);
            long configId  = DbIngest.insertConfig(parsed);
            long testRunId = DbIngest.insertTestRun(parsed, systemId, configId);

            DbIngest.insertResults(testRunId, parsed);

            DbIngest.BaselineResult res = DbIngest.checkForBaseline(testRunId);

            System.out.println("Ingest complete. test_run_id=" + testRunId);
            printBaselineStatus(res);

            return 0;

        } catch (Exception e) {
            System.out.println("Ingest failed: " + e.getMessage());
            LOG.log(Level.SEVERE, "Ingest failure", e);
            return 5;
        }
    }


    // ------------------------------------------------------------
    // COMPARE MODE
    // ------------------------------------------------------------
    private static int runCompare(CliArgs cli) {
        if (cli.dbConfigFile != null) {
            System.out.println("Note: --db-config-file ignored in compare mode.");
        }

        try {
            DbIngest.BaselineResult res = DbIngest.checkForBaseline(cli.runId);
            printBaselineStatus(res);
            return 0;

        } catch (Exception e) {
            System.out.println("Baseline operation failed: " + e.getMessage());
            LOG.log(Level.SEVERE, "Baseline failure", e);
            return 6;
        }
    }

    // ------------------------------------------------------------
    // SET BASELINE MODE
    // ------------------------------------------------------------
    private static int runSetBaseline(CliArgs cli) {
        if (cli.dbConfigFile != null) {
            System.out.println("Note: --db-config-file ignored in baseline mode.");
        }

        try {
            long runId = cli.setBaselineId;
            int rows = DbIngest.setBaseline(runId);

            if (rows > 0) {
                System.out.println("Baseline set for run_id=" + runId);
            } else {
                System.out.println("No such run_id=" + runId + " (baseline not updated).");
            }

            return 0;

        } catch (Exception e) {
            System.out.println("Set-baseline operation failed: " + e.getMessage());
            LOG.log(Level.SEVERE, "Set-baseline failure", e);
            return 7;
        }
    }

    // ------------------------------------------------------------
    // Baseline status printer
    // ------------------------------------------------------------
    private static void printBaselineStatus(DbIngest.BaselineResult res) {
        switch (res.status) {
            case "BASELINE_MATCHED":
                System.out.println("Baseline comparison created: " + res.comparisonId);
                break;

            case "NO_BASELINE_FOUND":
                System.out.println("No baseline exists for this test.");
                break;

            case "NO_COMPATIBLE_BASELINE":
                System.out.println("Baseline(s) exist, but none are metric-compatible.");
                break;

            default:
                System.out.println("Baseline check returned status: " + res.status);
                break;
        }
    }

    // ------------------------------------------------------------
    // Usage text
    // ------------------------------------------------------------
    private static void printUsage() {
        System.out.println();
        System.out.println("Usage:");
        System.out.println("  Process raw text results:");
        System.out.println("    --raw-results-file <path> [--db-config-file <path>] [--backend-config <path>]");
        System.out.println();
        System.out.println("  Compare a run against baseline:");
        System.out.println("    --run-id <id> [--backend-config <path>]");
        System.out.println();
        System.out.println("  Set a run as baseline:");
        System.out.println("    --set-baseline <id> [--backend-config <path>]");
        System.out.println();
        System.out.println("  General:");
        System.out.println("    --help");
        System.out.println();
        System.out.println("Exit Codes:");
        System.out.println("    0  success");
        System.out.println("    1  invalid arguments");
        System.out.println("    2  config load failure");
        System.out.println("    3  file not found or unreadable");
        System.out.println("    4  parser returned no data");
        System.out.println("    5  ingest failure");
        System.out.println("    6  baseline compare failure");
        System.out.println("    7  baseline set failure");
        System.out.println();
    }
}
