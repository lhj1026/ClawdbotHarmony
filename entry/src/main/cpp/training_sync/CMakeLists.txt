# CMakeLists.txt for training_sync module
cmake_minimum_required(VERSION 3.5.0)

add_library(training_sync SHARED
    training_sync.cpp
    training_sync_napi.cpp
)

target_include_directories(training_sync PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${NATIVERENDER_ROOT_PATH}
)

target_link_libraries(training_sync PUBLIC libace_napi.z.so)
