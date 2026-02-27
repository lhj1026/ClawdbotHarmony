# CMakeLists.txt for motion_detector module
cmake_minimum_required(VERSION 3.5.0)

add_library(motion_detector SHARED
    motion_detector_napi.cpp
    sampling_strategy_napi.cpp
)

target_include_directories(motion_detector PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${NATIVERENDER_ROOT_PATH}
)

target_link_libraries(motion_detector PUBLIC libace_napi.z.so)
