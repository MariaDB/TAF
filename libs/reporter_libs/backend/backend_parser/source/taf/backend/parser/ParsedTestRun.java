package taf.backend.parser;

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

    // config identity
    public String configName;
    public String configJsonBlob;

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
