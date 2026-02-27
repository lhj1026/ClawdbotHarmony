# CMakeLists.txt for sleep_pattern module
cmake_minimum_required(VERSION 3.5.0)

add_library(sleep_pattern SHARED
    sleep_pattern_napi.cpp
)

target_include_directories(sleep_pattern PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${NATIVERENDER_ROOT_PATH}
)

target_link_libraries(sleep_pattern PUBLIC libace_napi.z.so)
