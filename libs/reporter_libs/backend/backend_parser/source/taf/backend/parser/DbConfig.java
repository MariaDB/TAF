package taf.backend.parser;
/******************************************************************************
 * DbConfig.java
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
 *     Load database connection settings for the TAF backend from a simple
 *     key=value configuration file. This module provides default values and
 *     applies overrides from backend.conf at runtime.
 *
 * SCOPE OF THIS MODULE:
 *     - Parse backend.conf using a minimal key=value reader.
 *     - Populate host, port, user, password, and database fields.
 *     - Provide static configuration used by DbIngest and other backend
 *       components requiring JDBC connectivity.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not validate database connectivity.
 *     - Does not manage JDBC connections or pooling.
 *     - Does not interpret advanced configuration or nested structures.
 *
 * CONTRACT:
 *     Input:
 *         - Path to a readable key=value configuration file.
 *     Output:
 *         - Static fields populated with connection parameters.
 *     Requirements:
 *         - Unknown keys are ignored; malformed lines are skipped safely.
 *
 * NOTES:
 *     DbConfig defines the minimal configuration surface for backend ingest.
 *     Any change to required DB parameters must be reflected in this header
 *     and in the TAF manual.
 ******************************************************************************/

import java.io.BufferedReader;
import java.io.FileReader;
import java.util.HashMap;
import java.util.Map;

public class DbConfig {

    public static String host = "localhost";
    public static int port = 3306;
    public static String user = "taf_user";
    public static String password = "taf_password";
    public static String database = "taf_backend";

    // ------------------------------------------------------------
    // Load backend.conf
    // ------------------------------------------------------------
    public static void load(String path) throws Exception {
        Map<String, String> map = parseConfigFile(path);

        if (map.containsKey("host")) {
            host = map.get("host");
        }
        if (map.containsKey("port")) {
            port = Integer.parseInt(map.get("port"));
        }
        if (map.containsKey("user")) {
            user = map.get("user");
        }
        if (map.containsKey("password")) {
            password = map.get("password");
        }
        if (map.containsKey("database")) {
            database = map.get("database");
        }

        System.out.println("DB config loaded: " + host + ":" + port + "/" + database);
    }

    // ------------------------------------------------------------
    // Parse simple key=value config file
    // ------------------------------------------------------------
    private static Map<String, String> parseConfigFile(String path) throws Exception {
        Map<String, String> map = new HashMap<>();

        try (BufferedReader br = new BufferedReader(new FileReader(path))) {
            String line;

            while ((line = br.readLine()) != null) {
                line = line.trim();

                // Skip blank lines and comments
                if (line.isEmpty() || line.startsWith("#")) {
                    continue;
                }

                int eq = line.indexOf('=');
                if (eq <= 0) {
                    continue;
                }

                String key = line.substring(0, eq).trim();
                String val = line.substring(eq + 1).trim();

                map.put(key, val);
            }
        }

        return map;
    }
}
