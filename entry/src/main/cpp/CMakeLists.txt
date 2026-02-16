# CMakeLists.txt for native modules
cmake_minimum_required(VERSION 3.5.0)
project(native_modules)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# exec module - shell command execution
add_library(exec SHARED napi_exec.cpp)
target_link_libraries(exec PUBLIC libace_napi.z.so)

# voiceprint module - disabled, using sherpa_onnx har package instead
# add_subdirectory(voiceprint)
