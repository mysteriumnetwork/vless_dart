# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

project(vless_dart LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "vless_dart_plugin")

# The core ships as vless_core.exe beside XRay.aar and XRay.xcframework, so one
# release pins every platform to the same Xray-core build. Keep in lockstep
# with xrayCoreTag in android/build.gradle and the url in vless-core's
# Package.swift.
set(XRAY_CORE_TAG "xray-v26.3.27-10")
set(XRAY_CORE_BASE
  "https://github.com/mysteriumnetwork/vless-core/releases/download/${XRAY_CORE_TAG}")

# Named for the tag: a bump must not be satisfied by the previously cached
# download sitting under the same filename.
set(CORE_CACHE "${CMAKE_CURRENT_BINARY_DIR}/xray/${XRAY_CORE_TAG}")

# SHA-256 of each published asset, bumped with XRAY_CORE_TAG.
#
# A release asset can be replaced under an existing tag, and the cache key is
# only the tag, so without this a swapped file is fetched once and shipped
# forever. The app links with /MANIFESTUAC:level='requireAdministrator' and
# spawns vless_core.exe as a child, so that file runs with an elevated token:
# it is the last thing that should be taken on trust from a URL.
set(XRAY_CORE_SHA256_vless_core.exe
  "ad5e377e68989170d0505056b2db72c0bf31c9bf6820cb1cea9a4f34100dc4b9")
set(XRAY_CORE_SHA256_wintun.dll
  "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce")

# A local build wins, so the core can be iterated on without publishing a
# release. Mirrors VLESS_LOCAL_CORE in android/build.gradle.
set(LOCAL_CORE_DIRS
  "$ENV{VLESS_LOCAL_CORE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../vless-core/Artifacts"
)

# Fetches one release asset into the tag-named cache, unless a local build
# supplies it. Sets ${out_var} to the path to use.
function(resolve_core_asset name out_var)
  foreach(dir ${LOCAL_CORE_DIRS})
    if(dir AND EXISTS "${dir}/${name}")
      message(STATUS "vless_dart: using local ${name} from ${dir}")
      set(${out_var} "${dir}/${name}" PARENT_SCOPE)
      return()
    endif()
  endforeach()

  set(cached "${CORE_CACHE}/${name}")
  if(NOT EXISTS "${cached}")
    message(STATUS "vless_dart: fetching ${XRAY_CORE_BASE}/${name}")
    # Downloaded beside the cache entry and moved in only once the transfer
    # succeeds: a half-written file still satisfies EXISTS, so a dropped
    # connection would leave every later build shipping a truncated core.
    set(expected "${XRAY_CORE_SHA256_${name}}")
    if(NOT expected)
      message(FATAL_ERROR
        "vless_dart: no SHA-256 recorded for ${name}; add XRAY_CORE_SHA256_${name}")
    endif()
    file(DOWNLOAD "${XRAY_CORE_BASE}/${name}" "${cached}.part"
      STATUS download_status
      EXPECTED_HASH "SHA256=${expected}"
      SHOW_PROGRESS
      TLS_VERIFY ON)
    list(GET download_status 0 download_code)
    if(NOT download_code EQUAL 0)
      list(GET download_status 1 download_error)
      file(REMOVE "${cached}.part")
      message(FATAL_ERROR
        "vless_dart: failed to fetch ${name} from ${XRAY_CORE_BASE}: ${download_error}")
    endif()
    file(RENAME "${cached}.part" "${cached}")
  endif()
  set(${out_var} "${cached}" PARENT_SCOPE)
endfunction()

file(MAKE_DIRECTORY "${CORE_CACHE}")
resolve_core_asset("vless_core.exe" VLESS_CORE_EXE)
# Loaded by LoadLibraryEx with LOAD_LIBRARY_SEARCH_APPLICATION_DIR, so it has
# to land next to vless_core.exe — which, since both are bundled, is the
# runner's directory.
resolve_core_asset("wintun.dll" WINTUN_DLL)

list(APPEND PLUGIN_SOURCES
  "vless_dart_plugin.cpp"
  "vless_dart_plugin.h"
  "core_process.cpp"
  "core_process.h"
  "dns_policy.cpp"
  "dns_policy.h"
  "session_end.cpp"
  "session_end.h"
  "wire.cpp"
  "wire.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/vless_dart/vless_dart_plugin_c_api.h"
  "vless_dart_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of absolute paths to libraries that should be bundled with the plugin.
set(vless_dart_bundled_libraries
  "${VLESS_CORE_EXE}"
  "${WINTUN_DLL}"
  PARENT_SCOPE
)

# === Tests ===
# Only enable test builds when building the example, so that plugin clients
# aren't building the tests.
if(${include_${PROJECT_NAME}_tests})
set(TEST_RUNNER "${PROJECT_NAME}_test")
enable_testing()

include(FetchContent)
# Newer than the Flutter plugin template's release-1.11.0, which declares a
# pre-3.5 cmake_minimum_required. CMake 4 refuses that outright; the CMake
# bundled with Visual Studio only warns, so a local build passes and CI does
# not. Hashed because FetchContent will otherwise take whatever the URL
# serves.
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/refs/tags/v1.15.2.zip
  URL_HASH SHA256=f179ec217f9b3b3f3c6e8b02d3e7eda997b49e4ce26d6b235c9053bec9c0bf9f
)
# Prevent overriding the parent project's compiler/linker settings.
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
FetchContent_MakeAvailable(googletest)

# The wire protocol, the process handling around the core, the cleanup after
# one, and noticing the session end. The plugin class itself needs a Flutter
# engine, which belongs in integration tests.
add_executable(${TEST_RUNNER}
  test/wire_test.cpp
  test/core_process_test.cpp
  test/dns_policy_test.cpp
  test/session_end_test.cpp
  "wire.cpp"
  "core_process.cpp"
  "dns_policy.cpp"
  "session_end.cpp"
)
apply_standard_settings(${TEST_RUNNER})
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)

# What core_process_test.cpp launches in place of vless_core.exe. The real one
# needs an elevated session and a network to do anything at all. Built into
# the runner's directory, which is where the test looks for it.
set(TEST_HELPER "${PROJECT_NAME}_test_helper")
add_executable(${TEST_HELPER} test/core_process_test_helper.cpp)
apply_standard_settings(${TEST_HELPER})
add_dependencies(${TEST_RUNNER} ${TEST_HELPER})

include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})
endif()
