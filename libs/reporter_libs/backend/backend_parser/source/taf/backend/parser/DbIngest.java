package taf.backend.parser;

import java.util.Map;
import java.util.LinkedHashMap;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.Timestamp;
import java.sql.Types;
import java.security.MessageDigest;

public class DbIngest {

    // ------------------------------------------------------------
    // Insert system identity
    // ------------------------------------------------------------
    public static long insertSystemIdentity(ParsedTestRun tr) throws Exception {
        try (Connection conn = Db.getConnection()) {

            CallableStatement cs = conn.prepareCall(
                "{ call insert_system_identity(?,?,?,?,?,?,?,?,?,?,?,?,?) }"
            );

            cs.setString(1,  tr.hostName);
            cs.setString(2,  tr.cpuModel);
            cs.setInt(3,     tr.cpuCount);
            cs.setInt(4,     tr.coreCount);
            cs.setInt(5,     tr.socketCount);
            cs.setInt(6,     tr.ramGb);
            cs.setString(7,  tr.ramRaw);
            cs.setString(8,  tr.osName);
            cs.setString(9,  tr.osVersion);
            cs.setString(10, tr.osKernel);
            cs.setString(11, tr.osArch);

            cs.registerOutParameter(12, Types.BIGINT);
            cs.registerOutParameter(13, Types.CHAR);

            cs.execute();
            return cs.getLong(12);
        }
    }

    // ------------------------------------------------------------
    // Insert DB config
    // ------------------------------------------------------------
    public static long insertConfig(ParsedTestRun tr) throws Exception {
        try (Connection conn = Db.getConnection()) {

            CallableStatement cs = conn.prepareCall(
                "{ call insert_full_db_config(?,?,?) }"
            );

            cs.setString(1, tr.configName);
            cs.setString(2, tr.configJsonBlob);

            cs.registerOutParameter(3, Types.BIGINT);

            cs.execute();
            return cs.getLong(3);
        }
    }

	 // ------------------------------------------------------------
	 // Insert test run (updated for expanded test_run schema)
	 // ------------------------------------------------------------
    public static long insertTestRun(ParsedTestRun tr, long systemId, long configId) throws Exception {

        tr.systemId = systemId;
        tr.configId = configId;

        try (Connection conn = Db.getConnection()) {

            CallableStatement cs = conn.prepareCall(
                "{ call insert_test_run(" +
                // 1–8: test_name .. client_version
                "?,?,?,?,?,?,?,?," +
                // 9–17: db_maker .. database_under_test
                "?,?,?,?,?,?,?,?,?," +
                // 18: config_id
                "?," +
                // 19–25: NEW fields (tagging + properties + provenance)
                "?,?,?,?,?,?,?," +
                // 26: is_baseline
                "?," +
                // 27–30: pct_warning .. pct_duration_drift
                "?,?,?,?," +
                // 31–32: test_type, comments
                "?,?," +
                // 33–35: test_timestamp, test_end_time, test_duration
                "?,?,?," +
                // 36–37: warmup_threads, warmup_duration
                "?,?," +
                // 38–42: test_suite_revision .. range_size
                "?,?,?,?,?," +
                // 43–44: connector, thread_list
                "?,?," +
                // 45: metadata
                "?," +
                // 46–47: OUT params
                "?,?" +
                ") }"
            );

            int i = 1;

            // 1–8: core identity
            cs.setString(i++, tr.testName);
            cs.setLong(i++, systemId);
            cs.setString(i++, tr.tafHarnessName);
            cs.setString(i++, tr.tafHarnessVersion);
            cs.setString(i++, tr.suiteName);
            cs.setString(i++, tr.suiteVersion);
            cs.setString(i++, tr.clientProgram);
            cs.setString(i++, tr.clientVersion);

            // 9–17: DB metadata
            cs.setString(i++, tr.dbMaker);
            cs.setString(i++, tr.dbEngine);
            cs.setString(i++, tr.dbVersion);
            cs.setString(i++, tr.dbUser);
            cs.setString(i++, tr.dbRootUser);
            cs.setString(i++, tr.dbInstallDir);

            if (tr.dbPort != null) cs.setInt(i++, tr.dbPort);
            else cs.setNull(i++, Types.INTEGER);

            cs.setString(i++, tr.dbSocket);
            cs.setString(i++, tr.databaseUnderTest);

            // 18: config_id
            cs.setLong(i++, configId);

            // 19–25: NEW fields (tagging + properties + provenance)
            cs.setString(i++, tr.testCaseTag);
            cs.setString(i++, tr.autogenTags);
            cs.setString(i++, tr.testRunProperties);
            cs.setString(i++, tr.testRunPropertiesContents);
            cs.setString(i++, tr.dbConfigOrigin);
            cs.setString(i++, tr.dbConfigSourceFile);
            cs.setString(i++, tr.dbConfigTmpFile);

            // 26: baseline flag
            cs.setBoolean(i++, tr.isBaseline);

            // 27–30: thresholds
            if (tr.pctWarning != null) cs.setInt(i++, tr.pctWarning);
            else cs.setNull(i++, Types.INTEGER);

            if (tr.pctFail != null) cs.setInt(i++, tr.pctFail);
            else cs.setNull(i++, Types.INTEGER);

            if (tr.pctGain != null) cs.setInt(i++, tr.pctGain);
            else cs.setNull(i++, Types.INTEGER);

            if (tr.pctDurationDrift != null) cs.setInt(i++, tr.pctDurationDrift);
            else cs.setNull(i++, Types.INTEGER);

            // 31–32: test metadata
            cs.setString(i++, tr.testType);
            cs.setString(i++, tr.comments);

            // 33–35: timestamps + duration
            cs.setTimestamp(i++, Timestamp.valueOf(tr.testTimestamp));

            if (tr.testEndTime != null)
                cs.setTimestamp(i++, Timestamp.valueOf(tr.testEndTime));
            else
                cs.setNull(i++, Types.TIMESTAMP);

            if (tr.testDuration != null)
                cs.setInt(i++, tr.testDuration);
            else
                cs.setNull(i++, Types.INTEGER);

            // 36–37: warmup metadata
            if (tr.warmupThreads != null) cs.setInt(i++, tr.warmupThreads);
            else cs.setNull(i++, Types.INTEGER);

            if (tr.warmupDuration != null) cs.setInt(i++, tr.warmupDuration);
            else cs.setNull(i++, Types.INTEGER);

            // 38–42: suite metadata
            if (tr.testSuiteRevision != null) cs.setInt(i++, tr.testSuiteRevision);
            else cs.setNull(i++, Types.INTEGER);

            cs.setString(i++, tr.testSuitePmFile);

            if (tr.numberOfRows != null) cs.setInt(i++, tr.numberOfRows);
            else cs.setNull(i++, Types.INTEGER);

            if (tr.numberOfTables != null) cs.setInt(i++, tr.numberOfTables);
            else cs.setNull(i++, Types.INTEGER);

            if (tr.rangeSize != null) cs.setInt(i++, tr.rangeSize);
            else cs.setNull(i++, Types.INTEGER);

            // 43–44: connector + thread list
            cs.setString(i++, tr.connector);
            cs.setString(i++, tr.threadList);

            // 45: raw metadata JSON
            cs.setString(i++, tr.metadata != null ? JsonUtil.toJson(tr.metadata) : "{}");

            // 46–47: OUT params
            cs.registerOutParameter(i++, Types.BIGINT);
            cs.registerOutParameter(i++, Types.VARCHAR);

            cs.execute();

            return cs.getLong(i - 2);
        }
    }

    // ------------------------------------------------------------
    // Insert results and compute workload hash
    // ------------------------------------------------------------
    public static void insertResults(long testRunId, ParsedTestRun tr) throws Exception {
        try (Connection conn = Db.getConnection()) {

            for (ParsedIteration it : tr.iterations) {
                for (ParsedMetric m : it.metrics) {

                    CallableStatement cs = conn.prepareCall(
                        "{ call insert_result(?,?,?,?,?,?,?,?,?,?,?, ?,?) }"
                    );

                    cs.setLong(1, testRunId);
                    cs.setInt(2, it.threads);
                    cs.setInt(3, it.iterationId);
                    cs.setString(4, it.runTime);

                    cs.setString(5, m.name);
                    cs.setString(6, m.type);
                    cs.setString(7, m.dimension);
                    cs.setString(8, m.unit);
                    cs.setDouble(9, m.value);

                    cs.setString(10, null);
                    cs.setString(11, null);
                    cs.setString(12, null);

                    cs.registerOutParameter(13, Types.BIGINT);

                    cs.execute();
                }
            }

            String hash = computeWorkloadHash(tr);
            updateWorkloadHash(testRunId, hash);
            
            String tags = computeAutogenTags(tr);
            updateAutogenTags(testRunId, tags);
        }
    }

    // ------------------------------------------------------------
    // Extract integer metadata
    // ------------------------------------------------------------
    private static Integer getIntMeta(ParsedTestRun tr, String key) {
        if (tr.metadata == null) return null;
        Object v = tr.metadata.get(key);
        if (v == null) return null;
        if (v instanceof Number) return ((Number)v).intValue();
        try { return Integer.parseInt(v.toString()); }
        catch (Exception e) { return null; }
    }

    // ------------------------------------------------------------
    // Insert results and compute workload hash
    // ------------------------------------------------------------
    public static String computeWorkloadHash(ParsedTestRun tr) throws Exception {

        StringBuilder sb = new StringBuilder();

        // Test identity
        sb.append("TEST=").append(tr.testName).append("|");
        sb.append("SUITE=").append(tr.suiteName).append("|");
        sb.append("SUITE_VER=").append(tr.suiteVersion).append("|");
        sb.append("SUITE_REV=").append(tr.testSuiteRevision).append("|");
        sb.append("PMFILE=").append(tr.testSuitePmFile).append("|");

        // System identity
        sb.append("SYS=").append(tr.systemId).append("|");

        // DB identity
        sb.append("DB_MAKER=").append(tr.dbMaker).append("|");
        sb.append("DB_ENGINE=").append(tr.dbEngine).append("|");
        // Normalize to major only, ignore everything else (use same logic as extractMajor)
        String major = extractMajor(tr.dbVersion);
        sb.append("DB_VER=").append(major).append("|");




        // Config identity
        sb.append("CFG=").append(tr.configId).append("|");

        // Workload parameters
        sb.append("THREADS=").append(tr.threadList).append("|");
        sb.append("WARM_THREADS=").append(tr.warmupThreads).append("|");
        sb.append("WARM_DURATION=").append(tr.warmupDuration).append("|");
        sb.append("ROWS=").append(tr.numberOfRows).append("|");
        sb.append("TABLES=").append(tr.numberOfTables).append("|");
        sb.append("RANGE=").append(tr.rangeSize).append("|");
        sb.append("CONNECTOR=").append(tr.connector).append("|");

        // Versions
        sb.append("TAF_VER=").append(tr.tafHarnessVersion).append("|");
        sb.append("CLIENT_VER=").append(tr.clientVersion).append("|");

        // Iteration structure
        int iterationCount = tr.iterations != null ? tr.iterations.size() : 0;
        sb.append("ITER=").append(iterationCount).append("|");

        // Test duration (requested)
        sb.append("DURATION=").append(tr.testDuration).append("|");

        // Compute SHA-256
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] digest = md.digest(sb.toString().getBytes("UTF-8"));

        StringBuilder hex = new StringBuilder();
        for (byte b : digest) {
            hex.append(String.format("%02x", b));
        }

        return hex.toString();
    }

    // ------------------------------------------------------------
    // Gen auto tags
    // ------------------------------------------------------------
    public static String computeAutogenTags(ParsedTestRun tr) {
        Map<String,Object> tags = new LinkedHashMap<>();

        tags.put("test_name", tr.testName);
        tags.put("suite", tr.suiteName);
        tags.put("suite_version", tr.suiteVersion);
        tags.put("suite_revision", tr.testSuiteRevision);

        tags.put("system_id", tr.systemId);

        tags.put("db_maker", tr.dbMaker);
        tags.put("db_engine", tr.dbEngine);
        tags.put("db_version_major", extractMajor(tr.dbVersion));

        tags.put("config_id", tr.configId);

        tags.put("threads", tr.threadList);
        tags.put("warmup_threads", tr.warmupThreads);
        tags.put("warmup_duration", tr.warmupDuration);
        tags.put("rows", tr.numberOfRows);
        tags.put("tables", tr.numberOfTables);
        tags.put("range", tr.rangeSize);
        tags.put("connector", tr.connector);

        tags.put("taf_version", tr.tafHarnessVersion);
        tags.put("client_version", tr.clientVersion);

        tags.put("iteration_count", tr.iterations.size());
        tags.put("duration", tr.testDuration);

        return JsonUtil.toJson(tags);
    }


    // ------------------------------------------------------------
    // Update workload hash in DB
    // ------------------------------------------------------------
    private static void updateWorkloadHash(long testRunId, String hash) throws Exception {
        try (Connection conn = Db.getConnection()) {
            CallableStatement cs = conn.prepareCall(
                "{ call update_workload_hash(?,?) }"
            );
            cs.setLong(1, testRunId);
            cs.setString(2, hash);
            cs.execute();
        }
    }

    // ------------------------------------------------------------
    // Baseline comparison
    // ------------------------------------------------------------
    public static class BaselineResult {
        public final String status;
        public final long comparisonId;
        public BaselineResult(String status, long comparisonId) {
            this.status = status;
            this.comparisonId = comparisonId;
        }
    }

    public static BaselineResult checkForBaseline(long testRunId) throws Exception {
        try (Connection conn = Db.getConnection()) {

            CallableStatement cs = conn.prepareCall(
                "{ call check_for_baseline(?,?,?) }"
            );

            cs.setLong(1, testRunId);
            cs.registerOutParameter(2, Types.VARCHAR);
            cs.registerOutParameter(3, Types.BIGINT);

            cs.execute();

            return new BaselineResult(
                cs.getString(2),
                cs.getLong(3)
            );
        }
    }

    // ------------------------------------------------------------
    // Set a run as baseline
    // ------------------------------------------------------------
    public static int setBaseline(long runId) throws Exception {
        try (Connection conn = Db.getConnection()) {

            CallableStatement cs = conn.prepareCall(
                "{ call set_baseline(?) }"
            );

            cs.setLong(1, runId);
            return cs.executeUpdate();
        }
    }
    
    
	 // ------------------------------------------------------------
	 // Extract major DB version (matches workload hash logic)
	 // ------------------------------------------------------------
	 private static String extractMajor(String version) {
	     if (version == null) return "0";
	
	     // Strip suffixes like "-MariaDB", "-log", etc.
	     String cleaned = version.replaceAll("[^0-9.].*$", "");
	
	     String[] parts = cleaned.split("\\.");
	     return (parts.length > 0 ? parts[0] : "0");
	 }

	// ------------------------------------------------------------
	// Update autogen tags in DB
	// ------------------------------------------------------------
	private static void updateAutogenTags(long testRunId, String tagsJson) throws Exception {
	    try (Connection conn = Db.getConnection()) {
	        CallableStatement cs = conn.prepareCall(
	            "{ call update_autogen_tags(?,?) }"
	        );
	        cs.setLong(1, testRunId);
	        cs.setString(2, tagsJson);
	        cs.execute();
	    }
	}
}
