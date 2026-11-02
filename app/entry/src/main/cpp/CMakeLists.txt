cmake_minimum_required(VERSION 3.5.0)
project(verge_entry)

add_library(entry SHARED napi_init.cpp)

find_library(hilog-lib hilog_ndk.z)
target_link_libraries(entry PUBLIC libace_napi.z.so ${hilog-lib} dl)
