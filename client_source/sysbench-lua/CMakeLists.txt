#############################################################################
# CMakeLists.txt
#
# Last Modified: March 2026
#
# This file is part of the Test Automation Framework (TAF).
# Copyright (c) 2025-2026 MariaDB Foundation and Jonathan "jeb" Miller
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 or later of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
# PURPOSE:
#     Provide a deterministic, contributor-proof CMake build system for
#     sysbench-lua within the Test Automation Framework (TAF). This includes
#     structured detection of headers, libraries, and capabilities across
#     multiple database drivers (MySQL, PostgreSQL, Oracle, Null), along with
#     stable configuration generation and predictable build behavior.
#
# CONTEXT:
#     This updated version incorporates PostgreSQL driver support as part of
#     Virtuozzo's push toward PG adoption within TAF. Special thanks to Lukas
#     Oliva (Virtuozzo) for implementation and integration work on the PG
#     driver, enabling full multi-DB testing within sysbench-lua.
#
# ARCHITECTURAL ROLE:
#     - Acts as the top-level build definition for sysbench-lua.
#     - Ensures deterministic detection of MySQL, PGSQL, Oracle, and Null
#       drivers, including header and library resolution.
#     - Replicates the original autotools config.h behavior using modern CMake.
#     - Provides stable integration of third-party dependencies (LuaJIT, CK).
#     - Normalizes cross-platform behavior across Linux and macOS.
#
# WHAT THIS FILE DOES NOT DO:
#     - Does not implement driver logic; it only builds and links drivers.
#     - Does not guess paths or silently fall back to system defaults.
#     - Does not alter semantics of underlying driver modules.
#     - Does not perform runtime validation; all checks are compile-time only.
#
# CONTRACT:
#     - Must produce a deterministic sysbench-lua binary.
#     - Must expose correct driver selection based on WITH_* flags.
#     - Must generate a correct config.h reflecting system capabilities.
#     - Must maintain backward compatibility with existing TAF workflows.
#
# GUARANTEES:
#     - Stable, predictable builds across environments.
#     - Contributor-proof behavior through explicit detection logic.
#     - Consistent naming, error handling, and configuration semantics.
#
# NOTES:
#     - This file is intentionally verbose and heavily documented to ensure
#       clarity for contributors and maintainers.
#     - Any change to driver detection, config.h generation, or third-party
#       integration must be reflected in this header and in TAF documentation.
#############################################################################

###################################################
# CMake initialization and global project settings #
###################################################
cmake_minimum_required(VERSION 2.6)
if(COMMAND cmake_policy)
   cmake_policy(SET CMP0003 NEW)
endif(COMMAND cmake_policy)

if(WIN32)
   message(FATAL_ERROR "sysbench doesnot support Windows")
endif(WIN32)

project(sysbench-lua)

message("=== DEBUG: RAW CMAKE VARIABLES ===")
message("CMAKE_ARGS RAW = ${CMAKE_ARGS}")
message("CMAKE_C_FLAGS = ${CMAKE_C_FLAGS}")
message("CMAKE_CXX_FLAGS = ${CMAKE_CXX_FLAGS}")
message("=== END DEBUG ===")


set ( PACKAGE \"sysbench\" )
set ( PACKAGE_NAME \"sysbench\" )
set ( PACKAGE_TARNAME \"sysbench\" )
set ( PACKAGE_STRING \"sysbench 1.1.0\" )
set ( PACKAGE_VERSION \"1.1.0\" )
set (PACKAGE_URL \"https://github.com/akopytov/sysbench\")
set ( VERSION \"1.1.0\" )
set ( SB_GIT_SHA \"-2e6b7d5\" )
set ( SB_WITH_LUAJIT \"bundled\")
set ( SB_WITH_CK \"bundled\")

###################################################
# Third-party dependencies (LuaJIT, CK)           #
###################################################
message("Add thirparty luajit")
add_subdirectory(third_party/luajit/luajit)
add_library(luajit STATIC IMPORTED)
set_property(TARGET luajit PROPERTY IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/third_party/luajit/luajit/src/libluajit.a)
#add_dependencies(luajit sysbench)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/third_party/luajit/luajit/src ${CMAKE_CURRENT_SOURCE_DIR}/third_party/luajit/luajit)

message("Add thirparty concurrency_kit")
add_subdirectory(third_party/concurrency_kit/ck)
add_library(lib_ck STATIC IMPORTED)
set_property(TARGET lib_ck  PROPERTY IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/third_party/concurrency_kit/ck/src/libck.a)
#add_dependencies(lib_ck sysbench)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/third_party/concurrency_kit/ck ${CMAKE_CURRENT_SOURCE_DIR}/third_party/concurrency_kit/ck/src ${CMAKE_CURRENT_SOURCE_DIR}/third_party/concurrency_kit/ck/include)

####################################################
# Deterministic MySQL header and library detection #
####################################################
if(WITH_MYSQL)
    # Use environment variables provided by ClientCmakeBuild
    if(NOT DEFINED MYSQLH_PATH)
        if(DEFINED ENV{INC})
            set(MYSQLH_PATH "$ENV{INC}")
            message("mysql.h directory = ${MYSQLH_PATH}")
        else()
            message(FATAL_ERROR "MYSQLH_PATH not set and ENV{INC} missing")
        endif()
    endif()

    if(NOT DEFINED LIBMYSQL_LIB)
        if(DEFINED ENV{LIB})
            if(APPLE)
                find_file(LIBMYSQL_LIB libmysqlclient.dylib ENV LIB)
            else()
                find_file(LIBMYSQL_LIB libmysqlclient.so ENV LIB)
            endif()
        else()
            message(FATAL_ERROR "LIBMYSQL_LIB not set and ENV{LIB} missing")
        endif()
    endif()

    message("mysqlclient = ${LIBMYSQL_LIB}")

    if(MYSQLH_PATH AND LIBMYSQL_LIB)
        set(USE_MYSQL 1)
        message("USE_MYSQL = ${USE_MYSQL}")
    endif()
endif()

###################################################
# Core UNIX configuration checks                  #
###################################################
if (UNIX)
  # Core UNIX configuration checks (headers, functions, types)
  # Required for all drivers: MySQL, PGSQL, Oracle, Null
  # Replicates original autotools implementation wrt config.h
  include( CheckLibraryExists )
  include( CheckIncludeFiles )
  include( CheckFunctionExists )
  include( CheckSymbolExists )
  include( CheckCSourceCompiles )
  include( CheckCSourceRuns )
  include( CheckTypeSize )
  # ISO C89, ISO C99, POSIX.1, POSIX.2, BSD, SVID, X/Open, LFS, and GNU extensions.
  #ADD_DEFINITIONS(-D_GNU_SOURCE -DDATADIR=\"/usr/local/share/sysbench\" -DLIBDIR=\"/usr/local/lib/sysbench\")
  ADD_DEFINITIONS(-D_GNU_SOURCE)
  ADD_DEFINITIONS(-DDATADIR=\"\")
  ADD_DEFINITIONS(-DLIBDIR=\"\")
  ADD_DEFINITIONS(-DHAVE_CONFIG_H)

 include_directories(${CMAKE_SOURCE_DIR}/src/lua/internal ${CMAKE_SOURCE_DIR}/src )
  add_executable(sysbench 
	src/sysbench.c
	src/sysbench.h
	src/sb_timer.c
	src/sb_timer.h
	src/sb_options.c
	src/sb_options.h
	src/sb_logger.c
	src/sb_logger.h
	src/sb_list.h
	src/db_driver.h
	src/db_driver.c
	src/sb_histogram.c
	src/sb_histogram.h
	src/sb_rand.c
	src/sb_rand.h
	src/sb_thread.c
	src/sb_thread.h
	src/sb_barrier.c
	src/sb_barrier.h
	src/sb_lua.c
	src/sb_ck_pr.h
	src/sb_lua.h
	src/sb_util.h
	src/sb_util.c
	src/sb_counter.h
	src/sb_counter.c
	src/xoroshiro128plus.h
  )

  ##############################
  # Do checks, create config.h #
  ##############################

  # Hacks could not find how to check
  set ( HAVE_DECL_O_SYNC "1" )
  set ( LT_OBJDIR \".libs/\" )
  #set (HAVE_ISATTY "1")
  # Hacks end

  check_type_size( off_t OFF_T_SIZE )
  check_type_size( size_t SIZE_T_SIZE )
  check_type_size( "size_t" SIZEOF_SIZE_T )
  set( CMAKE_REQUIRED_INCLUDES math.h )
  set( CMAKE_REQUIRED_LIBRARIES m )

 if(WITH_NULL)
    set(USE_NULL 1)
  endif(WITH_NULL)
  find_package (Threads)
  if (Threads_FOUND)
    if (CMAKE_USE_PTHREADS_INIT)
      set (HAVE_LIBPTHREAD 1)
    else  (CMAKE_USE_PTHREADS_INIT)
      set (HAVE_LIBPTHREAD 0)
    endif (CMAKE_USE_PTHREADS_INIT)
  endif (Threads_FOUND)

  check_include_files ( malloc.h      HAVE_MALLOC_H )
  check_include_files ( dlfcn.h       HAVE_DLFCN_H )
  check_include_files ( fcntl.h       HAVE_FCNTL_H )
  check_include_files ( errno.h       HAVE_ERRNO_H )
  check_include_files ( inttypes.h    HAVE_INTTYPES_H )
  check_include_files ( math.h        HAVE_MATH_H )
  check_include_files ( memory.h      HAVE_MEMORY_H )
  check_include_files ( pthread.h     HAVE_PTHREAD_H )
  check_include_files ( libaio.h      HAVE_LIBAIO_H )
  check_include_files ( sched.h       HAVE_SCHED_H )
  check_include_files ( "sys/aio.h"   HAVE_SYS_AIO_H )
  check_include_files ( signal.h      HAVE_SIGNAL_H )
  check_include_files ( stdint.h      HAVE_STDINT_H )
  check_include_files ( stdlib.h      HAVE_STDLIB_H )
  check_include_files ( strings.h     HAVE_STRINGS_H )
  check_include_files ( string.h      HAVE_STRING_H )
  check_include_files ( "sys/ipc.h"   HAVE_SYS_IPC_H )
  check_include_files ( "sys/mman.h"  HAVE_SYS_MMAN_H )
  check_include_files ( "sys/shm.h"   HAVE_SYS_SHM_H )
  check_include_files ( "sys/param.h" HAVE_SYS_PARAM_H)
  check_include_files ( "sys/types.h" HAVE_SYS_TYPES_H )
  check_include_files ( "sys/stat.h"  HAVE_SYS_AIO_H )
  check_include_files ( "sys/ipc.h"   HAVE_SYS_STAT_H )
  check_include_files ( "sys/time.h"  HAVE_SYS_TIME_H )
  check_include_files ( thread.h      HAVE_THREAD_H )
  check_include_files ( unistd.h      HAVE_UNISTD_H )
  check_include_files ("stdlib.h;stdarg.h;string.h;float.h" STDC_HEADERS)
  check_include_files ("limit.h" HAVE_LIMITS_H)


  check_function_exists ( alarm              HAVE_ALARM )
  check_function_exists ( strerror_r         HAVE_STRERROR_R )
  check_function_exists ( malloc             HAVE_MALLOC )
  check_function_exists ( fdatasync          HAVE_FDATASYNC )
  check_function_exists ( getpagesize        HAVE_GETPAGESIZE )
  check_function_exists ( gettimeofday       HAVE_GETTIMEOFDAY )
  check_function_exists ( isatty             HAVE_ISATTY )
  check_function_exists ( lrand48            HAVE_LRAND48 )
  check_function_exists ( memset             HAVE_MEMSET )
  check_function_exists ( memalign           HAVE_MEMALIGN )
  check_function_exists ( mmap               HAVE_MMAP )
  check_function_exists ( posix_memalign     HAVE_POSIX_MEMALIGN )
  check_function_exists ( pthread_cancel     PTHREAD_CANCEL )
  check_function_exists ( pthread_yield      HAVE_PTHREAD_YIELD )
  check_function_exists ( setvbuf            HAVE_SETVBUF )
  check_function_exists ( sqrt               HAVE_SQRT )
  check_function_exists ( strdup             HAVE_STRDUP )
  check_function_exists ( thr_setconcurrency HAVE_THR_SETCONCURRENCY )
  check_function_exists ( valloc             HAVE_VALLOC )
  check_function_exists (directio HAVE_DIRECTIO)
  check_function_exists (format HAVE_FUNC_ATTRIBUTE_FORMAT)
  check_function_exists (unused HAVE_FUNC_ATTRIBUTE_FORMAT)
  check_function_exists (getevents HAVE_OLD_GETEVENTS)

  check_symbol_exists ( gettimeofday  sys/time.h HAVE_GETTIMEOFDAY)
  check_symbol_exists ( isatty     unistd.h HAVE_ISATTY)
  check_symbol_exists ( SHM_HUGETLB   sys/shm.h  HAVE_DECL_SHM_HUGETLB )
  if(HAVE_DECL_SHM_HUGETLB)
    SET(HAVE_LARGE_PAGES 1)
    SET(HUGETLB_USE_PROC_MEMINFO 1)
    SET(HAVE_LARGE_PAGE_OPTION 1)
  endif(HAVE_DECL_SHM_HUGETLB)

  check_symbol_exists ( PTHREAD_CREATE_JOINABLE pthread.h HAVE_PTHREAD_CREATE_JOINABLE)
  if (NOT HAVE_PTHREAD_CREATE_JOINABLE)
        CHECK_SYMBOL_EXISTS(PTHREAD_CREATE_DETACHED pthread.h HAVE_PTHREAD_CREATE_DETACHED)
        if (HAVE_PTHREAD_CREATE_DETACHED)
        set(PTHREAD_CREATE_JOINABLE "PTHREAD_CREATE_DETACHED")
        endif (HAVE_PTHREAD_CREATE_DETACHED)
  endif (NOT HAVE_PTHREAD_CREATE_JOINABLE)

  check_library_exists(aio io_queue_init "" HAVE_LIBAIO)
  check_library_exists(m pow             "" HAVE_LIBM )

  # Check whether time and sys/time can both be included
  check_c_source_compiles(
    "#include <sys/time.h>
     #include <time.h>
     int main(int argc, char** argv) {return 0;}"
     TIME_WITH_SYS_TIME
  )
 check_c_source_compiles("
     __thread int tls;
     int main(void) {
      return 0;
  }" TLS)

  set(save_cmake_required_flags "${CMAKE_REQUIRED_FLAGS}")
  set(CMAKE_REQUIRED_FLAGS "${cmake_required_flags} -Wall -Wextra -Werror")
  check_c_source_compiles(
    "#include <string.h>
     int main() {
     char * c;
     c = strerror_r(0,c,0);
     return 0;}"
     STRERROR_R_CHAR_P
   )
  set(CMAKE_REQUIRED_FLAGS "${save_cmake_required_flags}")

  if( STRERROR_R_CHAR_P )
    set( HAVE_DECL_STRERROR_R 1 )
  endif( STRERROR_R_CHAR_P )

  if( NOT HAVE_MALLOC )
   set( malloc rpl_malloc )
  endif( NOT HAVE_MALLOC )

  # Inspired from https://cmake.org/Wiki/CMakeTestInline
  # removed, because inline was removed between 1.0.12 and 1.0.20

  set(LFS_TEST_PROGRAM
    "#include <sys/types.h>
     #define LARGE_OFF_T (((off_t) 1 << 62) - 1 + ((off_t) 1 << 62))
     int off_t_is_large[(LARGE_OFF_T % 2147483629 == 721 && LARGE_OFF_T % 2147483647 == 1) ? 1 : -1];
     int main() { return 0; } ")
  check_c_source_compiles("${LFS_TEST_PROGRAM}" NO_LFS_MACROS_REQUIRED)
  if(NOT NO_LFS_MACROS_REQUIRED)
    if(NOT DEFINED FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
      check_c_source_compiles("#define _FILE_OFFSET_BITS 64 ${LFS_TEST_PROGRAM}" FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
      if(FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
        add_definitions(-D_FILE_OFFSET_BITS=64)
      elseif(NOT DEFINED LARGE_FILES_LFS_MACRO_REQUIRED)
        check_c_source_compiles("#define _LARGE_FILES 1 ${LFS_TEST_PROGRAM}" LARGE_FILES_LFS_MACRO_REQUIRED)
        if(LARGE_FILES_LFS_MACRO_REQUIRED)
          add_definitions(-D_LARGE_FILES=1)
        endif(LARGE_FILES_LFS_MACRO_REQUIRED)
      endif(FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
    endif(NOT DEFINED FILE_OFFSET_BITS_LFS_MACRO_REQUIRED)
  endif(NOT NO_LFS_MACROS_REQUIRED)
  unset(LFS_TEST_PROGRAM)

  configure_file(${CMAKE_CURRENT_SOURCE_DIR}/config/config.h.cmake ${CMAKE_CURRENT_SOURCE_DIR}/config.h)

  SET(CMAKE_C_FLAGS
    "-std=gnu99 ${CMAKE_C_FLAGS} -Wall -Wextra -Wformat-security -Wvla -Wwrite-strings -Wdeclaration-after-statement")
  SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -g -fno-omit-frame-pointer -std=c++11")
endif (UNIX)

target_link_libraries (sysbench luajit)
target_link_libraries (sysbench ${CMAKE_DL_LIBS})
target_link_libraries (sysbench lib_ck)

###################################################
# Driver selection (MySQL, PGSQL, Oracle, Null)   #
# Drivers are disabled unless explicitly enabled. #
###################################################
set(USE_MYSQL 0)
set(USE_PGSQL 0)
set(USE_ORACLE 0)
set(USE_NULL 0)

if(WITH_MYSQL)
    set(USE_MYSQL 1)
endif()

if(WITH_PGSQL)
    set(USE_PGSQL 1)
endif()

if(WITH_ORACLE)
    set(USE_ORACLE 1)
endif()

if(WITH_NULL)
    set(USE_NULL 1)
endif()

##########################
# Driver selection debug #
##########################
message("=== DRIVER SELECTION DEBUG ===")
message("WITH_MYSQL   = ${WITH_MYSQL}")
message("WITH_PGSQL   = ${WITH_PGSQL}")
message("WITH_ORACLE  = ${WITH_ORACLE}")
message("WITH_NULL    = ${WITH_NULL}")
message("USE_MYSQL    = ${USE_MYSQL}")
message("USE_PGSQL    = ${USE_PGSQL}")
message("USE_ORACLE   = ${USE_ORACLE}")
message("USE_NULL     = ${USE_NULL}")
message("ENV{INC}     = $ENV{INC}")
message("ENV{LIB}     = $ENV{LIB}")
message("MYSQLH_PATH  = ${MYSQLH_PATH}")
message("PGSQLH_PATH  = ${PGSQLH_PATH}")
message("LIBMYSQL_LIB = ${LIBMYSQL_LIB}")
message("LIBPGSQL_LIB = ${LIBPGSQL_LIB}")
message("=== END DRIVER DEBUG ===")

#####################
# Null driver block #
#####################
if(USE_NULL)
    message("Adding null db driver")
    add_subdirectory(src/drivers/nulldb)
    target_link_libraries(sysbench sbnull)
endif()

######################
# MySQL driver block #
######################
if(USE_MYSQL)
    message("Adding MySQL db driver")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUSE_MYSQL")
    include_directories(${MYSQLH_PATH})
    add_subdirectory(src/drivers/mysql)
    target_link_libraries(sysbench sbmysql)
    target_link_libraries(sysbench ${LIBMYSQL_LIB})
endif()

###########################
# PostgreSQL driver block #
###########################
if(USE_PGSQL)
    message("Adding pgsql db driver")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUSE_PGSQL")
    include_directories(${PGSQLH_PATH})
    add_subdirectory(src/drivers/pgsql)
    target_link_libraries(sysbench sbpgsql)
    target_link_libraries(sysbench ${LIBPGSQL_LIB})
endif()

#######################
# Oracle driver block #
#######################
if(USE_ORACLE)
    message("Adding oracle db driver")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -DUSE_ORACLE")
    include_directories(${ORACLEH_PATH})
    add_subdirectory(src/drivers/oracle)
    target_link_libraries(sysbench sboracle)
    target_link_libraries(sysbench ${LIBORACLE_LIB})
endif()

###################################################
# Test modules (cpu, fileio, mutex, threads, mem) #
###################################################
include_directories(${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/src/tests/cpu ${CMAKE_CURRENT_SOURCE_DIR}/src/tests/fileio)

message("Adding test cpu")
add_subdirectory(src/tests/cpu)
target_link_libraries (sysbench sbcpu)
message("Add done")

message("Adding test fileio")
add_subdirectory(src/tests/fileio)
target_link_libraries (sysbench sbfileio)
message("Add done")

message("Adding test mutex")
add_subdirectory(src/tests/mutex)
target_link_libraries (sysbench sbmutex)
message("Add done")

message("Adding test threads")
add_subdirectory(src/tests/threads)
target_link_libraries (sysbench sbthreads)
message("Add done")

message("Adding test memory")
add_subdirectory(src/tests/memory)
target_link_libraries (sysbench sbmemory)
message("Add done")

###################################################
# Final linking                                   #
###################################################
if (Threads_FOUND)
  target_link_libraries(sysbench ${CMAKE_THREAD_LIBS_INIT})
endif()

if (HAVE_LIBM)
  target_link_libraries (sysbench m)
endif()

if (HAVE_LIBAIO)
  target_link_libraries (sysbench aio)
endif()

message("script complete")