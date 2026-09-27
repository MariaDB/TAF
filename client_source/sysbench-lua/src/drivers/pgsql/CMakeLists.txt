cmake_minimum_required(VERSION 2.6)

add_library(sbpgsql STATIC
    drv_pgsql.c
)

# Include sysbench core headers
target_include_directories(sbpgsql PRIVATE
    ${CMAKE_SOURCE_DIR}
)

target_include_directories(sbpgsql PRIVATE
    ${PGSQLH_PATH}
)

target_link_libraries(sbpgsql
    ${LIBPGSQL_LIB}
)