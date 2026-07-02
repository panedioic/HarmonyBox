# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)

# ───────── 预置 prebuilt .so 检查 ─────────
# 如不需要请整段注释掉
set(HBOX_PREBUILT_LIBS_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}")

set(HBOX_REQUIRED_LIBS
    libexpat.so
    libffi.so
    libwayland-client.so
    libwayland-cursor.so
    libwayland-egl.so
    libwayland-server.so
    libbox64.so
)

set(HBOX_MISSING_LIBS "")
foreach(lib ${HBOX_REQUIRED_LIBS})
    if(NOT EXISTS "${HBOX_PREBUILT_LIBS_DIR}/${lib}")
        list(APPEND HBOX_MISSING_LIBS ${lib})
    endif()
endforeach()

if(HBOX_MISSING_LIBS)
    message(FATAL_ERROR
        "\n[HarmonyBox] Missing prebuilt dependency libraries. Please compile and place them in:\n"
        "  ${HBOX_PREBUILT_LIBS_DIR}\n"
        "Missing files:\n"
        "  ${HBOX_MISSING_LIBS}\n"
        "To skip this check, please comment out the [HBOX_PREBUILT_LIBS_DIR] section in CMakeLists.txt.\n"
    )
endif()

message(STATUS "[HarmonyBox] prebuilt libs ok at ${HBOX_PREBUILT_LIBS_DIR}")
# ─────────────────────────────────────────

project(HarmonyBox)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/shell
)

# 预编译好的 libwayland
add_library(wayland_server_lib SHARED IMPORTED GLOBAL)
set_target_properties(wayland_server_lib PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libwayland-server.so)

add_library(wayland_client_lib SHARED IMPORTED GLOBAL)
set_target_properties(wayland_client_lib PROPERTIES
    IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/../../../libs/${OHOS_ARCH}/libwayland-client.so)

add_library(entry SHARED
    napi_init.cpp
    plugin_manager.cpp
    egl_renderer.cpp
    wayland_server.cpp
    xdg_shell.cpp
    xdg-shell-protocol.c
    viewporter-protocol.c
    napi_utils.cpp
    fs_utils.cpp
#    process_runner.cpp
    process_manager.cpp
    client_napi.cpp
    input_window_napi.cpp
    wineprefix_setup.cpp
    shell/shell_engine.cpp
    shell/shell_output.cpp
    shell/shell_readline.cpp
    shell/shell_napi.cpp
    shell/shell_tokenizer.cpp
    shell/shell_path.cpp
    shell/shell_dispatcher.cpp
    shell/shell_session.cpp
    shell/builtins/cmd_help.cpp
    shell/builtins/cmd_clear.cpp
    shell/builtins/cmd_echo.cpp
    shell/builtins/cmd_pwd.cpp
    shell/builtins/cmd_cd.cpp
    shell/builtins/cmd_ls.cpp
    shell/builtins/cmd_cat.cpp
    shell/builtins/builtins_register.cpp
    shell/shell_env.cpp
    shell/builtins/cmd_env.cpp
    shell/builtins/cmd_export.cpp
    shell/builtins/cmd_unset.cpp
    shell/shell_process.cpp
    shell/builtins/cmd_box64.cpp
    shell/builtins/cmd_wine.cpp
    shell/builtins/cmd_wineserver.cpp
    shell/builtins/cmd_procmgr.cpp
    shell/builtins/cmd_status.cpp
)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libnative_window.so
    libEGL.so
    libGLESv3.so
    libuv.so
    libhilog_ndk.z.so
    wayland_server_lib
    dl
)