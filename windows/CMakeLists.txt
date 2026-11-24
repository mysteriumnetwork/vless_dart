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
set(XRAY_CORE_TAG "xray-v26.3.27-9")
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
  "4c176033b2163826c19adfb70db9465ce93fef541f68262c05d5f5ccb5dde8c8")
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
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/release-1.11.0.zip
)
# Prevent overriding the parent project's compiler/linker settings.
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "Disable installation of googletest" FORCE)
FetchContent_MakeAvailable(googletest)

# Only the wire protocol: the rest of the plugin needs a Flutter engine and a
# live core process, which belong in the integration tests rather than here.
add_executable(${TEST_RUNNER}
  test/wire_test.cpp
  "wire.cpp"
)
apply_standard_settings(${TEST_RUNNER})
target_include_directories(${TEST_RUNNER} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)

include(GoogleTest)
gtest_discover_tests(${TEST_RUNNER})
endif()
