# CMakeLists.txt for context_engine (情景智能规则引擎)
# C++ NAPI module: decision tree + soft matching + MAB
cmake_minimum_required(VERSION 3.5.0)
project(context_engine)

add_library(context_engine SHARED
    context_engine_napi.cpp
    rule_engine.cpp
    decision_tree.cpp
    soft_match.cpp
    mab.cpp
)

target_include_directories(context_engine PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(context_engine PUBLIC libace_napi.z.so)

# C++17 for std::optional, structured bindings
target_compile_features(context_engine PRIVATE cxx_std_17)
