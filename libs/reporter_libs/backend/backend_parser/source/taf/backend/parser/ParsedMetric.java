package taf.backend.parser;
/******************************************************************************
 * ParsedMetric.java
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
 *     Represent a single normalized metric extracted from a workload iteration.
 *     Each metric includes a name, type (primary or additional), dimension,
 *     unit, and numeric value. This structure is consumed by ingest and
 *     reporting components.
 *
 * SCOPE OF THIS MODULE:
 *     - Provide a stable container for metric attributes.
 *     - Support primary metric classification via PrimaryMetricClassifier.
 *     - Maintain consistent naming and normalization across all workloads.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not parse raw text or extract values.
 *     - Does not determine primary metric status.
 *     - Does not perform ingest, reporting, or validation.
 *
 * NOTES:
 *     Any change to metric fields or naming conventions must be reflected in
 *     this header and in the TAF manual. ParsedMetric defines the schema for
 *     all metric-level ingest operations.
 ******************************************************************************/

public class ParsedMetric {
    public String name;
    public String type;        // "primary" or "additional"
    public String dimension;
    public String unit;
    public double value;

    public ParsedMetric(String name, String type, String dimension, String unit, double value) {
        this.name = name;
        this.type = type;
        this.dimension = dimension;
        this.unit = unit;
        this.value = value;
    }
}
