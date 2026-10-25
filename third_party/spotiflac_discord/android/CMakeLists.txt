cmake_minimum_required(VERSION 3.22.1)
project(spotiflac_discord LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
option(SPOTIFLAC_DISCORD_SDK "Include the staged Discord Social SDK" ON)
add_library(spotiflac_discord SHARED src/main/cpp/presence.cpp)
target_compile_options(spotiflac_discord PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
# Keep every JNI entry point while hiding the wrapper's static C++ runtime.
target_link_options(spotiflac_discord PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,--version-script,${CMAKE_CURRENT_SOURCE_DIR}/presence.map"
    "-Wl,--icf=safe"
    "-Wl,--pack-dyn-relocs=android")
set_property(TARGET spotiflac_discord APPEND PROPERTY LINK_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/presence.map")
set(SDK "${CMAKE_CURRENT_SOURCE_DIR}/../sdk/android")
if(SPOTIFLAC_DISCORD_SDK AND EXISTS "${SDK}/jni/${ANDROID_ABI}/libdiscord_partner_sdk.so")
    add_library(discord_partner_sdk SHARED IMPORTED)
    set_target_properties(discord_partner_sdk PROPERTIES IMPORTED_LOCATION
        "${SDK}/jni/${ANDROID_ABI}/libdiscord_partner_sdk.so")
    target_include_directories(spotiflac_discord PRIVATE "${SDK}/prefab/modules/discord_partner_sdk/include")
    target_compile_definitions(spotiflac_discord PRIVATE SPOTIFLAC_DISCORD_SDK=1)
    target_link_libraries(spotiflac_discord PRIVATE discord_partner_sdk)
endif()
