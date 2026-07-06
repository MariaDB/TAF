package taf.backend.parser;
/******************************************************************************
 * JsonUtil.java
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
 *     Provide lightweight JSON conversion utilities for the TAF backend.
 *     This module converts between JSON strings and Java Map/List structures
 *     using org.json, and supports serialization of nested objects for ingest
 *     and configuration storage.
 *
 * SCOPE OF THIS MODULE:
 *     - Parse JSON arrays into List<Map<String,Object>>.
 *     - Parse JSON objects into Map<String,Object>.
 *     - Serialize Maps and Lists back into JSON strings.
 *     - Recursively convert nested JSONObject and JSONArray structures.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not validate schema or enforce field correctness.
 *     - Does not interpret semantics of configuration or metrics.
 *     - Does not perform parsing of raw test output.
 *
 * NOTES:
 *     JsonUtil is a helper for ingest and configuration handling. Any change
 *     to JSON structure expectations or serialization rules must be reflected
 *     in this header and in the TAF manual.
 ******************************************************************************/
import org.json.JSONArray;
import org.json.JSONObject;

import java.util.*;

public class JsonUtil {

    // ------------------------------------------------------------
    // Parse a JSON array string into List<Map<String,Object>>
    // ------------------------------------------------------------
    public static List<Map<String, Object>> parseArray(String json) {
        JSONArray arr = new JSONArray(json);
        List<Map<String, Object>> list = new ArrayList<>();

        for (int i = 0; i < arr.length(); i++) {
            Object o = arr.get(i);
            if (o instanceof JSONObject) {
                list.add(toMap((JSONObject) o));
            } else {
                throw new IllegalArgumentException("Expected JSON object inside array");
            }
        }

        return list;
    }

    // ------------------------------------------------------------
    // Parse a JSON object string into Map<String,Object>
    // ------------------------------------------------------------
    public static Map<String, Object> parseObject(String json) {
        JSONObject obj = new JSONObject(json);
        return toMap(obj);
    }

    // ------------------------------------------------------------
    // Convert Map/List primitives back to JSON
    // ------------------------------------------------------------
    public static String toJson(Object o) {
        if (o instanceof Map) {
            return new JSONObject((Map<?, ?>) o).toString();
        }
        if (o instanceof List) {
            return new JSONArray((List<?>) o).toString();
        }
        return String.valueOf(o);
    }

    // ------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------
    private static Map<String, Object> toMap(JSONObject obj) {
        Map<String, Object> map = new LinkedHashMap<>();

        for (String key : obj.keySet()) {
            Object val = obj.get(key);

            if (val instanceof JSONObject) {
                map.put(key, toMap((JSONObject) val));
            } else if (val instanceof JSONArray) {
                map.put(key, toList((JSONArray) val));
            } else {
                map.put(key, val);
            }
        }

        return map;
    }

    private static List<Object> toList(JSONArray arr) {
        List<Object> list = new ArrayList<>();

        for (int i = 0; i < arr.length(); i++) {
            Object val = arr.get(i);

            if (val instanceof JSONObject) {
                list.add(toMap((JSONObject) val));
            } else if (val instanceof JSONArray) {
                list.add(toList((JSONArray) val));
            } else {
                list.add(val);
            }
        }

        return list;
    }
}
