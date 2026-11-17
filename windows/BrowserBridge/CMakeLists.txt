cmake_minimum_required(VERSION 3.14)
project(browser_bridge LANGUAGES CXX)

# The native messaging host beside its app and generated manifest. A relative
# manifest "path" finds the host beside it; the edition's installer registers
# that manifest, never the other product's.
configure_file("identity.h.in" "generated_identity.h" @ONLY)
configure_file("manifest.json.in" "${APP_BROWSER_MANIFEST}" @ONLY)
set(BROWSER_BRIDGE_MANIFEST "${CMAKE_CURRENT_BINARY_DIR}/${APP_BROWSER_MANIFEST}"
  PARENT_SCOPE)

add_executable(${APP_BROWSER_HOST_TARGET} "host.cpp")
apply_standard_settings(${APP_BROWSER_HOST_TARGET})
target_compile_options(${APP_BROWSER_HOST_TARGET} PRIVATE /utf-8)
target_compile_definitions(${APP_BROWSER_HOST_TARGET} PRIVATE
  "NOMINMAX" "WIN32_LEAN_AND_MEAN")
target_include_directories(${APP_BROWSER_HOST_TARGET} PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(${APP_BROWSER_HOST_TARGET} PRIVATE
  "ws2_32.lib" "advapi32.lib")
