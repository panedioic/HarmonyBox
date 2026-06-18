#include "client_napi.h"
#include "napi_utils.h"
#include "process_runner.h"
#include "wayland_server.h"

#include <signal.h>
#include <sys/types.h>

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <cstdlib>
#include <cstring>

#undef LOG_TAG
#define LOG_TAG "WL_HBox"
#include <hilog/log.h>

namespace {

// ====== single GUI client tracking ======
std::atomic<pid_t> g_clientPid{-1};
napi_threadsafe_function g_stateTsfn = nullptr;

void StateTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    char* msg = static_cast<char*>(data);
    if (env && jsCb && msg) {
        napi_value undef, arg;
        napi_get_undefined(env, &undef);
        napi_create_string_utf8(env, msg, NAPI_AUTO_LENGTH, &arg);
        napi_call_function(env, undef, jsCb, 1, &arg, nullptr);
    }
    free(msg);
}

void EmitState(const char* s) {
    if (!g_stateTsfn) return;
    char* dup = strdup(s);
    napi_call_threadsafe_function(g_stateTsfn, dup, napi_tsfn_blocking);
}

// ====== env builders (保留原默认值,只是从 LaunchImpl/LaunchCli/ExecCapture 各自搬出来) ======
std::vector<std::string> BuildBox64Env(const std::string& sockPath,
                                       const std::string& libPath,
                                       const std::vector<std::string>& extraEnv) {
    auto pos  = sockPath.find_last_of('/');
    std::string dir  = (pos == std::string::npos) ? std::string("/tmp") : sockPath.substr(0, pos);
    std::string name = (pos == std::string::npos) ? sockPath : sockPath.substr(pos + 1);

    std::vector<std::string> env = {
        "XDG_RUNTIME_DIR=" + dir,
        "WAYLAND_DISPLAY=" + name,
        "LD_LIBRARY_PATH=" + libPath,
        "HOME=" + dir,
        "BOX64_LOG=1",
        "BOX64_NOBANNER=0",
    };
    for (const auto& e : extraEnv) {
        if (!e.empty()) env.push_back(e);
    }
    return env;
}

std::vector<std::string> BuildCliEnv(const std::string& libPath,
                                     const std::vector<std::string>& extraEnv) {
    std::vector<std::string> env = {
        std::string("LD_LIBRARY_PATH=") + libPath,
        std::string("HOME=/data/storage/el2/base"),
        std::string("BOX64_LOG=1"),
        std::string("BOX64_NOBANNER=0"),
        std::string("TERM=xterm-256color"),
    };
    for (const auto& e : extraEnv) {
        if (!e.empty()) env.push_back(e);
    }
    return env;
}

std::vector<std::string> BuildExecEnv(const std::string& libPath,
                                      const std::vector<std::string>& extraEnv) {
    std::vector<std::string> env = {
        "LD_LIBRARY_PATH=" + libPath,
        "HOME=/data/storage/el2/base",
    };
    for (const auto& e : extraEnv) {
        if (!e.empty()) env.push_back(e);
    }
    return env;
}

// ====== multi CLI tracking ======
struct CliEvent {
    int32_t pid;
    std::string event; // "out" | "exit"
    std::string data;
};

struct CliProc {
    pid_t pid = -1;
};

std::mutex g_cliMutex;
std::map<pid_t, std::shared_ptr<CliProc>> g_cliProcs;
napi_threadsafe_function g_cliTsfn = nullptr;

void CliTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    CliEvent* ev = static_cast<CliEvent*>(data);
    if (env && jsCb && ev) {
        napi_value undef, args[3];
        napi_get_undefined(env, &undef);
        napi_create_int32(env, ev->pid, &args[0]);
        napi_create_string_utf8(env, ev->event.c_str(), NAPI_AUTO_LENGTH, &args[1]);
        napi_create_string_utf8(env, ev->data.c_str(),  NAPI_AUTO_LENGTH, &args[2]);
        napi_call_function(env, undef, jsCb, 3, args, nullptr);
    }
    delete ev;
}

void EmitCli(int32_t pid, const char* event, const std::string& data) {
    if (!g_cliTsfn) return;
    auto* ev = new CliEvent{pid, event, data};
    napi_call_threadsafe_function(g_cliTsfn, ev, napi_tsfn_blocking);
}

// ====== ExecCapture promise glue ======
struct ExecCaptureCtx {
    napi_deferred deferred = nullptr;
    napi_threadsafe_function tsfn = nullptr;
    int code = -1;
    std::string out;
};

void ExecCaptureTsfnCallJs(napi_env env, napi_value /*jsCb*/, void*, void* dataRaw) {
    ExecCaptureCtx* ctx = static_cast<ExecCaptureCtx*>(dataRaw);
    if (env && ctx) {
        napi_value result, codeVal, outVal;
        napi_create_object(env, &result);
        napi_create_int32(env, ctx->code, &codeVal);
        napi_create_string_utf8(env, ctx->out.c_str(), ctx->out.size(), &outVal);
        napi_set_named_property(env, result, "code",   codeVal);
        napi_set_named_property(env, result, "stdout", outVal);
        napi_resolve_deferred(env, ctx->deferred, result);
    }
    if (ctx && ctx->tsfn) {
        napi_release_threadsafe_function(ctx->tsfn, napi_tsfn_release);
    }
    delete ctx;
}

} // anonymous namespace

namespace clientnapi {

napi_value SetStateCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (g_stateTsfn) {
        napi_release_threadsafe_function(g_stateTsfn, napi_tsfn_release);
        g_stateTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WLState", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, StateTsfnCallJs, &g_stateTsfn);

    WaylandServer::GetInstance()->SetStateCallback([](const char* s) {
        EmitState(s);
    });
    return nullptr;
}

napi_value StartWaylandServer(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = napiutil::GetStringArg(env, args[0]);

    bool ok = WaylandServer::GetInstance()->Start(path.c_str());
    napi_value r; napi_get_boolean(env, ok, &r);
    return r;
}

napi_value LaunchClient(napi_env env, napi_callback_info info) {
    size_t argc = 5; napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string exe      = napiutil::GetStringArg(env, args[0]);
    auto        argvStrs = napiutil::GetStringArrayArg(env, args[1]);
    if (argvStrs.empty()) argvStrs.push_back(exe);
    std::string sockPath = napiutil::GetStringArg(env, args[2]);
    std::string libPath  = napiutil::GetStringArg(env, args[3]);
    auto        extraEnv = napiutil::GetStringArrayArg(env, args[4]);

    auto fullEnv = BuildBox64Env(sockPath, libPath, extraEnv);

    proc::StreamSink sink;
    sink.onLine = [](pid_t /*pid*/, const std::string& line) {
        OH_LOG_INFO(LOG_APP, "[client] %{public}s", line.c_str());
    };
    sink.onExit = [](pid_t /*pid*/, int /*code*/) {
        g_clientPid = -1;
        EmitState("exited");
        OH_LOG_INFO(LOG_APP, "client reader exited, fired state=exited");
    };

    int pid = proc::RunBox64(exe, argvStrs, fullEnv, /*cwd*/ "", &sink, nullptr);
    if (pid > 0) g_clientPid = pid;

    napi_value r; napi_create_int32(env, pid, &r);
    return r;
}

napi_value StopClient(napi_env env, napi_callback_info) {
    (void)env;
    pid_t pid = g_clientPid.exchange(-1);
    if (pid > 0) proc::TerminateProcess(pid);
    WaylandServer::GetInstance()->ResetFirstCommit();
    OH_LOG_INFO(LOG_APP, "client stopped, server kept");
    return nullptr;
}

napi_value StopAll(napi_env env, napi_callback_info) {
    (void)env;
    pid_t pid = g_clientPid.exchange(-1);
    if (pid > 0) proc::TerminateProcess(pid);
    WaylandServer::GetInstance()->Stop();
    return nullptr;
}

napi_value ExecCapture(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string exe      = napiutil::GetStringArg(env, args[0]);
    auto        argvStrs = napiutil::GetStringArrayArg(env, args[1]);
    if (argvStrs.empty()) argvStrs.push_back(exe);
    std::string libPath  = napiutil::GetStringArg(env, args[2]);
    std::vector<std::string> extraEnv;
    if (argc >= 4) extraEnv = napiutil::GetStringArrayArg(env, args[3]);

    auto fullEnv = BuildExecEnv(libPath, extraEnv);

    auto* ctx = new ExecCaptureCtx();
    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);

    napi_value resName;
    napi_create_string_utf8(env, "ExecCapture", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, nullptr, nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, ExecCaptureTsfnCallJs, &ctx->tsfn);

    proc::CaptureSink sink;
    sink.maxBytes = 8192;
    sink.onDone = [ctx](int code, std::string out) {
        ctx->code = code;
        ctx->out  = std::move(out);
        napi_call_threadsafe_function(ctx->tsfn, ctx, napi_tsfn_blocking);
    };

    int pid = proc::RunCommand(exe, argvStrs, fullEnv, /*cwd*/ "", nullptr, &sink);
    if (pid < 0) {
        // spawn 失败,直接以 code=-1 resolve
        ctx->code = -1;
        napi_call_threadsafe_function(ctx->tsfn, ctx, napi_tsfn_blocking);
    }
    return promise;
}

napi_value LaunchCli(napi_env env, napi_callback_info info) {
    size_t argc = 5; napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string exe      = napiutil::GetStringArg(env, args[0]);
    auto        argvStrs = napiutil::GetStringArrayArg(env, args[1]);
    if (argvStrs.empty()) argvStrs.push_back(exe);
    std::string libPath  = napiutil::GetStringArg(env, args[2]);
    std::string cwd      = napiutil::GetStringArg(env, args[3]);
    auto        extraEnv = napiutil::GetStringArrayArg(env, args[4]);

    auto fullEnv = BuildCliEnv(libPath, extraEnv);

    proc::StreamSink sink;
    sink.onLine = [](pid_t pid, const std::string& line) {
        EmitCli((int32_t)pid, "out", line);
    };
    sink.onExit = [](pid_t pid, int code) {
        EmitCli((int32_t)pid, "exit", std::to_string(code));
        std::lock_guard<std::mutex> lk(g_cliMutex);
        g_cliProcs.erase(pid);
    };

    int pid = proc::RunCommand(exe, argvStrs, fullEnv, cwd, &sink, nullptr);
    if (pid > 0) {
        auto p = std::make_shared<CliProc>();
        p->pid = pid;
        std::lock_guard<std::mutex> lk(g_cliMutex);
        g_cliProcs[pid] = p;
        OH_LOG_INFO(LOG_APP, "cli pid=%{public}d exe=%{public}s envc=%{public}u",
                    pid, exe.c_str(), (uint32_t)extraEnv.size());
    }
    napi_value r; napi_create_int32(env, pid, &r);
    return r;
}

napi_value StopCli(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t pid = 0;
    napi_get_value_int32(env, args[0], &pid);
    if (pid > 0) kill(pid, SIGTERM);
    return nullptr;
}

napi_value SetCliCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_cliTsfn) {
        napi_release_threadsafe_function(g_cliTsfn, napi_tsfn_release);
        g_cliTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "CliEvt", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, CliTsfnCallJs, &g_cliTsfn);
    return nullptr;
}

} // namespace clientnapi