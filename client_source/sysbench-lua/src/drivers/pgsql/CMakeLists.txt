INCLUDE_DIRECTORIES(${CMAKE_SOURCE_DIR})
add_library(sbpgsql STATIC drv_pgsql.c)
target_link_libraries(sbpgsql ${LIBPGSQL_LIB})
