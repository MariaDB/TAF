package taf.backend.parser;
/******************************************************************************
 * CliArgs.java
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
 *     Parse and store command-line arguments for the TAF backend parser.
 *     This module defines all supported flags, performs minimal validation,
 *     and exposes mode-detection helpers used by TafBackendCli.
 *
 * SCOPE OF THIS MODULE:
 *     - Support raw results ingestion via --raw-results-file or --stdin.
 *     - Load backend configuration via --backend-config.
 *     - Load DB configuration via --db-config-file.
 *     - Support comparison mode via --run-id.
 *     - Support baseline creation via --set-baseline.
 *     - Provide a --help flag for usage output.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not validate file existence or workload semantics.
 *     - Does not perform parsing, ingest, or comparison logic.
 *     - Does not load configuration files or manage DB connections.
 *
 * CONTRACT:
 *     Input:
 *         - Raw command-line arguments.
 *     Output:
 *         - A populated CliArgs instance with mode-detection helpers.
 *     Requirements:
 *         - Unknown arguments are reported but not fatal.
 *
 * NOTES:
 *     CliArgs defines the public CLI surface of the backend parser. Any change
 *     to supported flags or mode semantics must be reflected in this header
 *     and in the TAF manual.
 ******************************************************************************/

public class CliArgs {

    // ingestion
    public String rawResultsFile;
    public String dbConfigFile;
    public boolean stdinMode;

    // backend config (DB connection)
    public String backendConfigPath = "./backend.conf";

    // compare / baseline
    public long runId;
    public long setBaselineId;

    // help
    public boolean help;

    public static CliArgs parse(String[] args) {
        CliArgs c = new CliArgs();

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {

                case "--raw-results-file":
                    c.rawResultsFile = args[++i];
                    break;
                    
                case "--stdin":
                	c.stdinMode = true;
                    break;

                case "--db-config-file":
                    c.dbConfigFile = args[++i];
                    break;

                case "--backend-config":
                    c.backendConfigPath = args[++i];
                    break;

                case "--run-id":
                    c.runId = Long.parseLong(args[++i]);
                    break;

                case "--set-baseline":
                    c.setBaselineId = Long.parseLong(args[++i]);
                    break;

                case "--help":
                    c.help = true;
                    break;

                default:
                    System.out.println("Unknown argument: " + args[i]);
            }
        }

        return c;
    }

    // mode detection
    public boolean isProcessMode()      { return rawResultsFile != null; }
    public boolean isCompareMode()      { return runId > 0; }
    public boolean isSetBaselineMode()  { return setBaselineId > 0; }
    public boolean isHelp()             { return help; }
}
