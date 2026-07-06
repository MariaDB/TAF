package taf.backend.parser;
/******************************************************************************
 * ParsedIteration.java
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
 *     Represent a single iteration within a parsed test run. Each iteration
 *     captures the iteration index, thread count, runtime string, and the
 *     complete list of normalized metrics produced by the workload.
 *
 * SCOPE OF THIS MODULE:
 *     - Provide a stable container for iteration-level metadata.
 *     - Maintain an ordered list of ParsedMetric objects.
 *     - Support ingest and reporting components that rely on deterministic
 *       iteration structure.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not parse raw text or extract metrics.
 *     - Does not classify primary metrics.
 *     - Does not perform ingest, reporting, or validation.
 *
 * NOTES:
 *     ParsedIteration defines the schema for iteration-level ingest. Any
 *     change to iteration fields or ordering must be reflected in this header
 *     and in the TAF manual.
 ******************************************************************************/
import java.util.ArrayList;
import java.util.List;

public class ParsedIteration {
    public int iterationId;
    public int threads;
    public String runTime;
    public List<ParsedMetric> metrics = new ArrayList<>();

    public ParsedIteration(int iterationId, int threads, String runTime) {
        this.iterationId = iterationId;
        this.threads = threads;
        this.runTime = runTime;
    }
}