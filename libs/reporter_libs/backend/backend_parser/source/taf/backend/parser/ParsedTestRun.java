package taf.backend.parser;
/******************************************************************************
 * ParsedTestRun.java
 * TAF-Backend-Parser Version: 1.5
 *
 * Created: May 2026
 * Last Modified: August 2026
 *
 * This file is part of the Test Automation Framework (TAF).
 * Copyright (c) 2026 MariaDB Foundation and Jonathan "jeb" Miller
 *
 * Licensed under the GNU General Public License, version 2 or later (GPLv2+).
 * See https://www.gnu.org/licenses/ for details.
 *
 * PURPOSE:
 *     Represent a fully parsed test run record produced by the backend parser.
 *     This structure holds canonical metadata, provenance fields, and all
 *     run-level attributes required for backend ingestion and reporting.
 *
 * SCOPE OF THIS MODULE:
 *     - Store canonical config identity (configName, configJsonBlob).
 *     - Store DB configuration provenance (origin, source_file, tmp_file).
 *     - Store test case tagging (testCaseTag, autogenTags).
 *     - Store generated test case properties (name + contents).
 *     - Store all standard test run metadata (suite, testname, timings, etc.).
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not perform ingestion, parsing, or DB operations.
 *     - Does not validate metadata semantics.
 *     - Does not read external files; all fields are populated upstream.
 *
 * CONTRACT:
 *     Input:
 *         - Metadata extracted from raw reporter output.
 *     Output:
 *         - A fully populated ParsedTestRun instance.
 *     Requirements:
 *         - All provenance fields must be provided by upstream parser logic.
 *
 * NOTES:
 *     ParsedTestRun defines the canonical backend schema for TAF 4.0.
 *     Any change to provenance fields or run metadata must be reflected here
 *     and in backend SQL ingestion procedures.
 ******************************************************************************/

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

public class ParsedTestRun {

    public WorkloadType workloadType;

    // identity
    public String testName;
    public String suiteName;
    public String suiteVersion;
    public String testType;
    public LocalDateTime testTimestamp;      // start time
    public LocalDateTime testEndTime;        // end time
    public Integer testDuration;             // actual duration (normalized)

    // run identity (DB-assigned externally)
    public long systemId;
    public long configId;

    // system identity
    public String hostName;
    public String cpuModel;
    public int    cpuCount;
    public int    coreCount;
    public int    socketCount;
    public int    ramGb;
    public String ramRaw;
    public String osName;
    public String osVersion;
    public String osKernel;
    public String osArch;

    // db identity
    public String dbMaker;
    public String dbEngine;
    public String dbVersion;

    // extended DB metadata
    public String dbUser;
    public String dbRootUser;
    public String dbInstallDir;
    public Integer dbPort;
    public String dbSocket;
    public String databaseUnderTest;

    // config identity (canonicalized)
    public String configName;        // logical name of config (from raw properties)
    public String configJsonBlob;    // canonical JSON blob of DB config parameters

    // NEW: DB config provenance (run-specific)
    public String dbConfigOrigin;        // inline, metadata, tmp, etc.
    public String dbConfigSourceFile;    // original file path if applicable
    public String dbConfigTmpFile;       // temp file path if applicable

    // taf / client
    public String tafHarnessName;
    public String tafHarnessVersion;
    public String clientProgram;
    public String clientVersion;

    // baseline + thresholds
    public boolean isBaseline;
    public Integer pctWarning;
    public Integer pctFail;
    public Integer pctGain;
    public Integer pctDurationDrift;

    // workload identity
    public String workloadHash;

    // comments, raw test type
    public String comments;
    public String testTypeRaw;

    // NEW: test case tagging
    public String testCaseTag;       // user-defined semantic tag
    public String autogenTags;       // machine-generated JSON tags

    // NEW: full properties file (name + contents)
    public String testRunProperties;           // generated_properties_file (NAME)
    public String testRunPropertiesContents;   // generated_properties_file_contents (CONTENTS)

    // warmup metadata
    public Integer warmupThreads;
    public Integer warmupDuration;

    // test suite metadata
    public Integer testSuiteRevision;
    public String  testSuitePmFile;
    public Integer numberOfRows;
    public Integer numberOfTables;
    public Integer rangeSize;

    // connector + thread list
    public String connector;
    public String threadList;

    // raw metadata blob
    public Map<String, Object> metadata;

    // parsed iterations
    public List<ParsedIteration> iterations = new ArrayList<>();
}
