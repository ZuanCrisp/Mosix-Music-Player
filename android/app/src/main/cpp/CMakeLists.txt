cmake_minimum_required(VERSION 3.22.1)
project(spotiflac_audio LANGUAGES C CXX)

include(FetchContent)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OBOE_DISABLE_CONVERSION ON CACHE BOOL "" FORCE)
set(WAVPACK_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_DSD ON CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_THREADS OFF CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_ASM OFF CACHE BOOL "" FORCE)

# Immutable releases plus checksums keep local and CI builds identical.
FetchContent_Declare(oboe
    URL https://github.com/google/oboe/archive/refs/tags/1.11.0.tar.gz
    URL_HASH SHA256=0ccf2110640a2b4489f1c93a404f2978656b434d8c5dc9cb6258f9cc95c79b15)
FetchContent_Declare(wavpack
    URL https://github.com/dbry/WavPack/archive/refs/tags/5.9.0.tar.gz
    URL_HASH SHA256=2a53e50aefd8c9f04a0828a0e1ef77b6f4c17b0ef6964ad234ab295f313b7d6d)
FetchContent_MakeAvailable(oboe wavpack)

add_library(spotiflac_audio SHARED native_audio.cpp)
target_compile_features(spotiflac_audio PRIVATE cxx_std_17)
target_compile_options(spotiflac_audio PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
target_link_libraries(spotiflac_audio PRIVATE oboe WavPack::WavPack log)
# Only JNI is public; static Oboe/WavPack/C++ implementation symbols must not
# keep otherwise unused code alive. APS2 is supported by our minimum API 24.
target_link_options(spotiflac_audio PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,--version-script,${CMAKE_CURRENT_SOURCE_DIR}/native_audio.map"
    "-Wl,--icf=safe"
    "-Wl,--pack-dyn-relocs=android")
set_property(TARGET spotiflac_audio APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/native_audio.map")
