# CMakeLists.txt for federated_sync module (联邦学习同步)
cmake_minimum_required(VERSION 3.5.0)

add_library(federated_sync SHARED
    federated_sync.cpp
    federated_sync_napi.cpp
)

target_include_directories(federated_sync PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${NATIVERENDER_ROOT_PATH}
)

target_link_libraries(federated_sync PUBLIC libace_napi.z.so)

# C++17 for structured bindings
target_compile_features(federated_sync PRIVATE cxx_std_17)
