# CMakeLists.txt for native modules
cmake_minimum_required(VERSION 3.5.0)
project(native_modules)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# exec module - shell command execution
add_library(exec SHARED napi_exec.cpp)
target_link_libraries(exec PUBLIC libace_napi.z.so)

# context_engine module - rule engine + MAB + LinUCB
add_subdirectory(context_engine)

# voiceprint module - stub implementation for UI testing
add_subdirectory(voiceprint)

# data_tray module - sensor data caching with TTL
add_subdirectory(data_tray)

# geo_utils module - geographic distance calculations
add_subdirectory(geo_utils)

# dbscan_cluster module - DBSCAN clustering algorithm
add_subdirectory(dbscan_cluster)

# location_fusion module - multi-source location fusion
add_subdirectory(location_fusion)

# motion_detector module - motion state detection + sampling strategy
add_subdirectory(motion_detector)

# place_learner module - place signal learning
add_subdirectory(place_learner)

# sleep_pattern module - sleep time learning
add_subdirectory(sleep_pattern)

# feedback_learner module - user feedback learning
add_subdirectory(feedback_learner)

# training_sync module - training data synchronization
add_subdirectory(training_sync)

# federated_sync module - federated learning sync (anonymization + model exchange)
add_subdirectory(federated_sync)
