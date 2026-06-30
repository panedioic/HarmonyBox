#include "napi/native_api.h"
#include "plugin_manager.h"

#include "client_napi.h"
#include "input_window_napi.h"
#include "fs_utils.h"
#include "process_manager.h"
#include "wineprefix_setup.h"
#include "shell/shell_napi.h"

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        // ---- wayland server / client lifecycle ----
        {"startWaylandServer",  nullptr, clientnapi::StartWaylandServer, nullptr,nullptr,nullptr, napi_default,nullptr},
        {"launchClient",        nullptr, clientnapi::LaunchClient,       nullptr,nullptr,nullptr, napi_default,nullptr},
        {"stopClient",          nullptr, clientnapi::StopClient,         nullptr,nullptr,nullptr, napi_default,nullptr},
        {"stopAll",             nullptr, clientnapi::StopAll,            nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setStateCallback",    nullptr, clientnapi::SetStateCallback,   nullptr,nullptr,nullptr, napi_default,nullptr},

        // ---- exec / cli ----
        {"execCapture",         nullptr, clientnapi::ExecCapture,        nullptr,nullptr,nullptr, napi_default,nullptr},
        {"launchCli",           nullptr, clientnapi::LaunchCli,          nullptr,nullptr,nullptr, napi_default,nullptr},
        {"stopCli",             nullptr, clientnapi::StopCli,            nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setCliCallback",      nullptr, clientnapi::SetCliCallback,     nullptr,nullptr,nullptr, napi_default,nullptr},
        
        // ---- 新统一进程接口 ----
        // {"runBox64",            nullptr, proc::RunBox64Napi,             nullptr,nullptr,nullptr, napi_default,nullptr},
        // {"runCommand",          nullptr, proc::RunCommandNapi,           nullptr,nullptr,nullptr, napi_default,nullptr},
        // {"terminate",           nullptr, proc::TerminateNapi,            nullptr,nullptr,nullptr, napi_default,nullptr},
        // ---- 新统一进程接口 ----
        {"runCommand",          nullptr, procmgr::RunCommandNapi,        nullptr,nullptr,nullptr, napi_default,nullptr},
        {"terminate",           nullptr, procmgr::TerminateNapi,         nullptr,nullptr,nullptr, napi_default,nullptr},
        {"listProcesses",       nullptr, procmgr::ListProcessesNapi,     nullptr,nullptr,nullptr, napi_default,nullptr},
        // ---- 反向 spawn 通道 ----
        {"startProcMgr",        nullptr, procmgr::StartControlSocketNapi,nullptr,nullptr,nullptr, napi_default,nullptr},
        {"stopProcMgr",         nullptr, procmgr::StopControlSocketNapi, nullptr,nullptr,nullptr, napi_default,nullptr},
        // ---- 兼容旧接口 (DEPRECATED) ----
        {"runBox64",            nullptr, procmgr::RunBox64NapiCompat,    nullptr,nullptr,nullptr, napi_default,nullptr},

        // ---- input ----
        {"sendKey",             nullptr, iwnapi::SendKey,                nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendModifiers",       nullptr, iwnapi::SendModifiers,          nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendMouseMove",       nullptr, iwnapi::SendMouseMove,          nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendMouseButton",     nullptr, iwnapi::SendMouseButton,        nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendMouseAxis",       nullptr, iwnapi::SendMouseAxis,          nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendMouseHover",      nullptr, iwnapi::SendMouseHover,         nullptr,nullptr,nullptr, napi_default,nullptr},

        // ---- window ----
        {"setSizeCallback",       nullptr, iwnapi::SetSizeCallback,        nullptr,nullptr,nullptr, napi_default,nullptr},
        {"getLatestSize",         nullptr, iwnapi::GetLatestSize,          nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setMoveCallback",       nullptr, iwnapi::SetMoveCallback,        nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setMaximizeCallback",   nullptr, iwnapi::SetMaximizeCallback,    nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setUnmaximizeCallback", nullptr, iwnapi::SetUnmaximizeCallback,  nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setResizeCallback",     nullptr, iwnapi::SetResizeCallback,      nullptr,nullptr,nullptr, napi_default,nullptr},
        {"requestClientResize",   nullptr, iwnapi::RequestClientResize,    nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setMinimizeCallback",   nullptr, iwnapi::SetMinimizeCallback,    nullptr,nullptr,nullptr, napi_default,nullptr},

        // ---- fs ----
        {"chmodDirFiles",         nullptr, fsutil::ChmodDirFilesNapi,      nullptr,nullptr,nullptr, napi_default,nullptr},
        {"ensureBox64TmpDir",     nullptr, fsutil::EnsureBox64TmpDirNapi,  nullptr,nullptr,nullptr, napi_default,nullptr},
        
        // ---- wineprefix prebuild ----
        {"setupWinePrefix",       nullptr, wineprefix::SetupWinePrefixNapi, nullptr,nullptr,nullptr, napi_default,nullptr},
        
        // ---- shell ----
        {"shellInit",           nullptr, shell::ShellInitNapi,            nullptr,nullptr,nullptr, napi_default,nullptr},
        {"shellInput",          nullptr, shell::ShellInputNapi,           nullptr,nullptr,nullptr, napi_default,nullptr},
        {"shellResize",         nullptr, shell::ShellResizeNapi,          nullptr,nullptr,nullptr, napi_default,nullptr},
        {"shellShutdown",       nullptr, shell::ShellShutdownNapi,        nullptr,nullptr,nullptr, napi_default,nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc)/sizeof(desc[0]), desc);
    PluginManager::GetInstance()->Export(env, exports);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1, .nm_flags = 0, .nm_filename = nullptr,
    .nm_register_func = Init, .nm_modname = "entry",
    .nm_priv = nullptr, .reserved = {0},
};
extern "C" __attribute__((constructor)) void RegisterEntryModule() {
    napi_module_register(&demoModule);
}