# CMakeLists.txt for exec native module
cmake_minimum_required(VERSION 3.5.0)
project(exec)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

add_library(exec SHARED napi_exec.cpp)
target_link_libraries(exec PUBLIC libace_napi.z.so)
