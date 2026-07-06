package taf.backend.parser;
/******************************************************************************
 * RawResultParser.java
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
 *     Provide the entry points for parsing raw test output into a structured
 *     ParsedTestRun. This module supports both stdin and file-based input,
 *     performs workload detection, emits debug context, and dispatches to the
 *     unified Parser for workload-specific interpretation.
 *
 * SCOPE OF THIS MODULE:
 *     - Read raw text from stdin or file.
 *     - Split input into lines and validate basic structure.
 *     - Detect workload type using WorkloadDetector.
 *     - Emit debug information for traceability.
 *     - Invoke Parser.parse to produce a ParsedTestRun instance.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not parse metrics or extract values (delegates to Parser).
 *     - Does not interpret workload semantics.
 *     - Does not perform ingest or reporting actions.
 *     - Does not manage database configuration or baseline logic.
 *
 * CONTRACT:
 *     Input:
 *         - Raw text (stdin mode) or a readable file path (file mode).
 *     Output:
 *         - ParsedTestRun populated with workload type, metadata, and
 *           iteration structures.
 *     Requirements:
 *         - Input must contain at least one line.
 *         - Workload type must be detectable; UNKNOWN is treated as error.
 *
 * NOTES:
 *     This module defines the boundary between raw text ingestion and the
 *     structured parsing pipeline. Any change to workload detection or parser
 *     invocation must be reflected in this header and in the TAF manual.
 ******************************************************************************/
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Collectors;

public class RawResultParser {

    // ------------------------------------------------------------
    // Parse raw text (stdin mode)
    // ------------------------------------------------------------
    public static ParsedTestRun parse(String rawText) throws Exception {

        if (rawText == null || rawText.isBlank()) {
            throw new Exception("Raw text input is empty");
        }

        List<String> lines = rawText.lines().collect(Collectors.toList());

        if (lines.isEmpty()) {
            throw new Exception("Raw text contains no lines");
        }

        WorkloadType type = WorkloadDetector.detect(lines);

        if (type == WorkloadType.UNKNOWN) {
            throw new Exception("Unknown or unsupported workload type in raw text input");
        }

        TafBackendCli.debug("Detected workload type: " + type);

        String raw = String.join("\n", lines);

        TafBackendCli.debug("=== RAW INPUT (first 500 chars) ===");
        TafBackendCli.debug(raw.substring(0, Math.min(500, raw.length())));
        TafBackendCli.debug("====================================");

        return Parser.parse(lines, type, "<stdin>");
    }

    // ------------------------------------------------------------
    // Parse from file path (file mode)
    // ------------------------------------------------------------
    public static ParsedTestRun parse(Path filePath) throws Exception {

        if (filePath == null) {
            throw new Exception("File path is null");
        }

        if (!Files.exists(filePath)) {
            throw new Exception("File does not exist: " + filePath);
        }

        List<String> lines = Files.readAllLines(filePath, java.nio.charset.StandardCharsets.UTF_8);

        if (lines.isEmpty()) {
            throw new Exception("File contains no lines: " + filePath);
        }

        WorkloadType type = WorkloadDetector.detect(lines);

        if (type == WorkloadType.UNKNOWN) {
            throw new Exception("Unknown or unsupported workload type in file: " + filePath);
        }

        TafBackendCli.debug("Detected workload type: " + type);

        return Parser.parse(lines, type, filePath.toString());
    }
}
