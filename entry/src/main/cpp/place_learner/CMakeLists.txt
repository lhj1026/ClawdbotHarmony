# CMakeLists.txt for place_learner module
cmake_minimum_required(VERSION 3.5.0)

add_library(place_learner SHARED
    place_signal_learner_napi.cpp
)

target_include_directories(place_learner PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${NATIVERENDER_ROOT_PATH}
)

target_link_libraries(place_learner PUBLIC libace_napi.z.so)
