package taf.backend.parser;
/******************************************************************************
 * Db.java
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
 *     Provide a simple and deterministic JDBC connection factory for the TAF
 *     backend. This module constructs a MariaDB JDBC URL from DbConfig fields
 *     and returns a new connection for each request.
 *
 * SCOPE OF THIS MODULE:
 *     - Build a JDBC connection string using DbConfig settings.
 *     - Establish a new MariaDB connection via DriverManager.
 *     - Emit sanitized connection debug output.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not manage connection pooling or reuse.
 *     - Does not validate DbConfig contents beyond null checks.
 *     - Does not perform SQL operations or schema management.
 *
 * CONTRACT:
 *     Input:
 *         - DbConfig must be loaded prior to use.
 *     Output:
 *         - A live JDBC Connection instance.
 *     Requirements:
 *         - Throws SQLException on configuration or connection failure.
 *
 * NOTES:
 *     Db.java defines the backend’s minimal connection layer. Any change to
 *     connection parameters or URL semantics must be reflected in this header
 *     and in the TAF manual.
 ******************************************************************************/

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;

public class Db {

    public static Connection getConnection() throws SQLException {

        if (DbConfig.host == null || DbConfig.user == null) {
            throw new SQLException("DbConfig not initialized. Call DbConfig.load(path) first.");
        }

        String url = "jdbc:mariadb://"
            + DbConfig.host + ":"
            + DbConfig.port + "/"
            + DbConfig.database
            + "?useUnicode=true&characterEncoding=UTF-8&useSSL=false&serverTimezone=UTC";

        System.out.println("Connecting to: " + url.replace(DbConfig.password, "****"));

        return DriverManager.getConnection(url, DbConfig.user, DbConfig.password);
    }
}

