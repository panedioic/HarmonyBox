# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(HarmonyBox)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
)

# 预编译好的 libwayland
add_library(wayland_server_lib SHARED IMPORTED GLOBAL)
set_target_properties(wayland_server_lib PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libwayland-server.so)

add_library(wayland_client_lib SHARED IMPORTED GLOBAL)
set_target_properties(wayland_client_lib PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libwayland-client.so)

# ── 主 .so：只剩 server + UI bridge ──
add_library(entry SHARED
    napi_init.cpp
    plugin_manager.cpp
    egl_renderer.cpp
    wayland_server.cpp
    xdg_shell.cpp
    xdg-shell-protocol.c
)
target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libnative_window.so
    libEGL.so
    libGLESv3.so
    libhilog_ndk.z.so
    wayland_server_lib
)