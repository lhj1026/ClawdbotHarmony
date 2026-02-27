# CMakeLists.txt for feedback_learner module
cmake_minimum_required(VERSION 3.5.0)

add_library(feedback_learner SHARED
    feedback_learner_napi.cpp
)

target_include_directories(feedback_learner PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${NATIVERENDER_ROOT_PATH}
)

target_link_libraries(feedback_learner PUBLIC libace_napi.z.so)
