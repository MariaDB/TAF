package taf.backend.parser;
/******************************************************************************
 * RubyHashConverter.java
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
 *     Convert raw Ruby and Perl hybrid data structures into Java collections
 *     suitable for TAF backend processing. This module cleans inconsistent
 *     Ruby-style output, removes Perl dereference artifacts, normalizes hash
 *     syntax, and parses the result into nested Map and List structures.
 *
 * SCOPE OF THIS MODULE:
 *     - Strip headers, assignment wrappers, and Perl $VAR dereference noise.
 *     - Normalize Ruby hash rockets and remove trailing commas.
 *     - Provide a minimal recursive descent parser for Ruby-like hashes,
 *       lists, strings, numbers, and barewords.
 *     - Expose a public API that returns List<Map<String,Object>> for use by
 *       RawResultParser and ingest components.
 *
 * WHAT THIS MODULE DOES NOT DO:
 *     - Does not interpret semantics or validate field correctness.
 *     - Does not perform workload detection or metric extraction.
 *     - Does not handle reporting, ingest, or database operations.
 *
 * CONTRACT:
 *     Input:
 *         - Raw Ruby/Perl hybrid text from test clients.
 *     Output:
 *         - List<Map<String,Object>> representing normalized structured data.
 *     Requirements:
 *         - Input may contain arbitrary formatting; converter must degrade
 *           safely and throw explicit errors only on unrecoverable structure.
 *
 * NOTES:
 *     This converter is a foundational component for parsing HammerDB and
 *     Sysbench-Lua raw output. Any change to normalization rules or parser
 *     behavior must be reflected in this header and in the TAF manual.
 ******************************************************************************/
import java.util.*;

public class RubyHashConverter {

    // ------------------------------------------------------------
    // Public API: convert raw Ruby/Perl hybrid into List<Map>
    // ------------------------------------------------------------
    public static List<Map<String,Object>> convertToList(String raw) throws Exception {
        String cleaned = clean(raw);

        Parser p = new Parser(cleaned);
        Object root = p.parseValue();

        if (root instanceof List) {
            @SuppressWarnings("unchecked")
            List<Object> list = (List<Object>) root;

            List<Map<String,Object>> out = new ArrayList<>();
            for (Object o : list) {
                if (o instanceof Map) {
                    @SuppressWarnings("unchecked")
                    Map<String,Object> m = (Map<String,Object>) o;
                    out.add(m);
                }
            }
            return out;
        }

        if (root instanceof Map) {
            List<Map<String,Object>> out = new ArrayList<>();
            @SuppressWarnings("unchecked")
            Map<String,Object> m = (Map<String,Object>) root;
            out.add(m);
            return out;
        }

        throw new IllegalArgumentException("Top-level Ruby structure is not a list or map");
    }

    // ------------------------------------------------------------
    // Clean Ruby/Perl hybrid into a consistent structure
    // ------------------------------------------------------------
    private static String clean(String raw) {
        if (raw == null) return "";

        raw = raw.replace("\r", "");

        // 1) Skip header lines until first '[' or '{'
        String[] lines = raw.split("\n");
        StringBuilder sb = new StringBuilder();
        boolean started = false;

        for (String line : lines) {
            String t = line.trim();

            if (!started) {
                if (t.startsWith("[") || t.startsWith("{")) {
                    started = true;
                    sb.append(t).append("\n");
                }
                continue;
            }

            sb.append(line).append("\n");
        }

        raw = sb.toString();

        // 2) Remove Perl deref garbage like $VAR1->[0]{"metrics"}[0],
        raw = raw.replaceAll("\\$VAR1[^,\\n]*,?", "");

        // 3) Strip assignment wrappers WITHOUT REGEX ESCAPES
        // Examples:
        //   $VAR1 = [
        //   runs = {
        String trimmed = raw.trim();
        int eq = trimmed.indexOf('=');
        if (eq > 0) {
            String left = trimmed.substring(0, eq).trim();
            String right = trimmed.substring(eq + 1).trim();
            if ((right.startsWith("[") || right.startsWith("{")) &&
                left.matches("[A-Za-z0-9_\\$]+")) {
                raw = right;
            }
        }

        // 4) Replace Ruby hash rocket with colon
        raw = raw.replace("=>", ":");

        // 5) Remove trailing commas before } or ]
        raw = raw.replaceAll(",\\s*([}\\]])", "$1");

        return raw.trim();
    }

    // ------------------------------------------------------------
    // Tiny recursive descent parser for Ruby-like hashes
    // ------------------------------------------------------------
    private static class Parser {
        private final String s;
        private int pos = 0;

        Parser(String s) {
            this.s = s;
        }

        private void skipWS() {
            while (pos < s.length() && Character.isWhitespace(s.charAt(pos))) pos++;
        }

        Object parseValue() throws Exception {
            skipWS();
            if (pos >= s.length()) throw new Exception("Unexpected end of input");

            char c = s.charAt(pos);

            if (c == '{') return parseMap();
            if (c == '[') return parseList();
            if (c == '"') return parseString();
            if (c == '-' || Character.isDigit(c)) return parseNumber();

            return parseBareword();
        }

        Map<String,Object> parseMap() throws Exception {
            Map<String,Object> map = new LinkedHashMap<>();
            pos++; // skip '{'
            skipWS();

            while (pos < s.length() && s.charAt(pos) != '}') {
                skipWS();
                String key = parseKey();
                skipWS();

                if (pos >= s.length() || s.charAt(pos) != ':') {
                    int start = Math.max(0, pos - 40);
                    int end   = Math.min(s.length(), pos + 40);
                    String snippet = s.substring(start, end);

                    throw new Exception(
                        "Expected ':' after key at position " + pos +
                        "\n--- context ---\n" + snippet + "\n----------------"
                    );
                }
                pos++; // skip ':'

                Object val = parseValue();
                map.put(key, val);

                skipWS();
                if (pos < s.length() && s.charAt(pos) == ',') {
                    pos++;
                    skipWS();
                }
            }

            if (pos < s.length() && s.charAt(pos) == '}') pos++;
            return map;
        }

        List<Object> parseList() throws Exception {
            List<Object> list = new ArrayList<>();
            pos++; // skip '['
            skipWS();

            while (pos < s.length() && s.charAt(pos) != ']') {
                Object val = parseValue();
                list.add(val);

                skipWS();
                if (pos < s.length() && s.charAt(pos) == ',') {
                    pos++;
                    skipWS();
                }
            }

            if (pos < s.length() && s.charAt(pos) == ']') pos++;
            return list;
        }

        String parseString() throws Exception {
            pos++; // skip opening quote
            StringBuilder sb = new StringBuilder();

            while (pos < s.length()) {
                char c = s.charAt(pos);

                if (c == '\\') {
                    // handle escapes
                    pos++;
                    if (pos >= s.length()) break;
                    char e = s.charAt(pos);

                    if (e == '"' || e == '\\') {
                        sb.append(e);
                    } else {
                        // keep unknown escapes literally
                        sb.append('\\').append(e);
                    }
                    pos++;
                    continue;
                }

                if (c == '"') {
                    pos++;
                    break;
                }

                sb.append(c);
                pos++;
            }

            return sb.toString();
        }

        Object parseNumber() {
            int start = pos;
            while (pos < s.length() &&
                   (Character.isDigit(s.charAt(pos)) ||
                    s.charAt(pos) == '.' ||
                    s.charAt(pos) == '-')) {
                pos++;
            }
            String num = s.substring(start, pos);
            if (num.contains(".")) return Double.parseDouble(num);
            return Long.parseLong(num);
        }

        String parseBareword() {
            int start = pos;
            while (pos < s.length() &&
                   (Character.isLetterOrDigit(s.charAt(pos)) ||
                    s.charAt(pos) == '_' ||
                    s.charAt(pos) == '-')) {
                pos++;
            }
            return s.substring(start, pos);
        }

        String parseKey() throws Exception {
            skipWS();
            if (pos < s.length() && s.charAt(pos) == '"') return parseString();
            return parseBareword();
        }
    }
}
