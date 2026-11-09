-- =====================================================================
-- MDEV-39497 : Enable Performance Schema instruments and consumers
-- Author: Jonathan (Jeb) Miller
-- Purpose:
--   This script enables all PFS instruments, consumers, and objects
--   so that PFS overhead can be measured cleanly during MDEV-39497 runs.
--
-- Usage:
--   Use with:
--     --exec-sql-file-before-test-setup=<path/to/this/file>
--
-- Notes:
--   Output will be written to the first sub-results directory.
--   Default state for PFS varies by distro; this script ensures
--   deterministic behavior for all test cases.
-- =====================================================================

UPDATE performance_schema.setup_instruments
   SET ENABLED = 'YES',
       TIMED   = 'YES';

UPDATE performance_schema.setup_consumers
   SET ENABLED = 'YES';

UPDATE performance_schema.setup_objects
   SET ENABLED = 'YES',
       TIMED   = 'YES';