#include "napi/native_api.h"
#include "wayland_server.h"
#include "plugin_manager.h"

#include <unistd.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <string>
#include <thread>
#include <atomic>
#include <vector>

extern char** environ;

#undef LOG_TAG
#define LOG_TAG "WL_HBox"
#include <hilog/log.h>

static pid_t g_clientPid = -1;
static std::atomic<bool> g_readerRunning{false};
static napi_threadsafe_function g_stateTsfn = nullptr;

static void close_inherited_fds_except(int k1, int k2) {
    DIR* d = opendir("/proc/self/fd");
    if (!d) return;
    int dfd = dirfd(d);
    struct dirent* e;
    while ((e = readdir(d))) {
        int fd = atoi(e->d_name);
        if (fd > 2 && fd != dfd && fd != k1 && fd != k2) close(fd);
    }
    closedir(d);
}

static void ReaderThreadMain(int fd) {
    char buf[2048];
    std::string pending;
    auto emit = [](const std::string& line) {
        OH_LOG_INFO(LOG_APP, "[client] %{public}s", line.c_str());
    };
    while (g_readerRunning) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            pending.append(buf, n);
            size_t pos;
            while ((pos = pending.find('\n')) != std::string::npos) {
                emit(pending.substr(0, pos));
                pending.erase(0, pos + 1);
            }
        } else if (n == 0) {
            break;
        } else {
            if (errno == EINTR) continue;
            OH_LOG_ERROR(LOG_APP, "read pipe: %{public}s", strerror(errno));
            break;
        }
    }
    if (!pending.empty()) emit(pending);
    close(fd);
}

static void StateTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    char* msg = static_cast<char*>(data);
    if (env && jsCb && msg) {
        napi_value undef, arg;
        napi_get_undefined(env, &undef);
        napi_create_string_utf8(env, msg, NAPI_AUTO_LENGTH, &arg);
        napi_call_function(env, undef, jsCb, 1, &arg, nullptr);
    }
    free(msg);
}

static napi_value SetStateCallback(napi_env env, napi_callback_info info) {
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
        if (g_stateTsfn) {
            char* dup = strdup(s);
            napi_call_threadsafe_function(g_stateTsfn, dup, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

static napi_value StartWaylandServer(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char path[512] = {0}; size_t len;
    napi_get_value_string_utf8(env, args[0], path, sizeof(path), &len);

    bool ok = WaylandServer::GetInstance()->Start(path);
    napi_value r; napi_get_boolean(env, ok, &r);
    return r;
}

static int LaunchImpl(const char* exePath,
                      const std::vector<std::string>& argvStrs,
                      const char* sockPath,
                      const char* libPath) {
    if (access(exePath, X_OK) != 0) chmod(exePath, 0755);
    if (argvStrs.size() >= 2) {
        const std::string& target = argvStrs[1];
        if (!target.empty() && target[0] == '/') {
            if (access(target.c_str(), X_OK) != 0) {
                chmod(target.c_str(), 0755);
            }
        }
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        OH_LOG_ERROR(LOG_APP, "pipe failed: %{public}s", strerror(errno));
        return -1;
    }
    fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    signal(SIGCHLD, SIG_IGN);

    pid_t pid = fork();
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        if (pipefd[1] > 2) close(pipefd[1]);
        prctl(PR_SET_NAME, "wl-client", 0, 0, 0);
        close_inherited_fds_except(STDOUT_FILENO, STDERR_FILENO);
        for (int s = 1; s < 32; ++s) signal(s, SIG_DFL);

        std::string p(sockPath);
        auto pos  = p.find_last_of('/');
        std::string dir  = (pos == std::string::npos) ? std::string("/tmp") : p.substr(0, pos);
        std::string name = (pos == std::string::npos) ? p : p.substr(pos + 1);
        std::string envXdg  = "XDG_RUNTIME_DIR=" + dir;
        std::string envWld  = "WAYLAND_DISPLAY="  + name;
        std::string envLdp  = "LD_LIBRARY_PATH=" + std::string(libPath);
        std::string envHome = "HOME=" + dir;
        std::string envBoxLog       = "BOX64_LOG=1";
        std::string envBoxNoBanner  = "BOX64_NOBANNER=0";
        char* envp[] = {
            (char*)envXdg.c_str(),
            (char*)envWld.c_str(),
            (char*)envLdp.c_str(),
            (char*)envHome.c_str(),
            (char*)envBoxLog.c_str(),
            (char*)envBoxNoBanner.c_str(),
            nullptr,
        };

        std::vector<char*> cargv;
        cargv.reserve(argvStrs.size() + 1);
        for (const auto& s : argvStrs) cargv.push_back(const_cast<char*>(s.c_str()));
        cargv.push_back(nullptr);
        execve(exePath, cargv.data(), envp);
        fprintf(stderr, "execve(%s) failed: %s\n", exePath, strerror(errno));
        _exit(127);
    }
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        return -1;
    }
    close(pipefd[1]);
    g_clientPid = pid;
    g_readerRunning = true;
    std::thread(ReaderThreadMain, pipefd[0]).detach();
    OH_LOG_INFO(LOG_APP, "client pid=%{public}d exe=%{public}s argc=%{public}u",
                pid, exePath, (uint32_t)argvStrs.size());
    return (int)pid;
}

// 唯一的启动接口:argv 由 ArkTS 传入。如果 argv 为空数组,自动用 [exePath]
static napi_value LaunchClient(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char exePath[1024]={0}, sockPath[512]={0}, libPath[1024]={0}; size_t len;
    napi_get_value_string_utf8(env, args[0], exePath, sizeof(exePath), &len);

    uint32_t n = 0;
    napi_get_array_length(env, args[1], &n);
    std::vector<std::string> argvStrs;
    argvStrs.reserve(n > 0 ? n : 1);
    for (uint32_t i = 0; i < n; ++i) {
        napi_value el;
        napi_get_element(env, args[1], i, &el);
        char buf[1024] = {0};
        napi_get_value_string_utf8(env, el, buf, sizeof(buf), &len);
        argvStrs.emplace_back(buf);
    }
    if (argvStrs.empty()) argvStrs.emplace_back(exePath);

    napi_get_value_string_utf8(env, args[2], sockPath, sizeof(sockPath), &len);
    napi_get_value_string_utf8(env, args[3], libPath, sizeof(libPath), &len);

    int pid = LaunchImpl(exePath, argvStrs, sockPath, libPath);
    napi_value r; napi_create_int32(env, pid, &r);
    return r;
}

static void KillClientLocked() {
    g_readerRunning = false;
    if (g_clientPid > 0) {
        kill(g_clientPid, SIGTERM);
        g_clientPid = -1;
    }
}

static napi_value StopClient(napi_env env, napi_callback_info) {
    (void)env;
    KillClientLocked();
    WaylandServer::GetInstance()->ResetFirstCommit();
    OH_LOG_INFO(LOG_APP, "client stopped, server kept");
    return nullptr;
}

static napi_value StopAll(napi_env env, napi_callback_info) {
    (void)env;
    KillClientLocked();
    WaylandServer::GetInstance()->Stop();
    return nullptr;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"startWaylandServer", nullptr, StartWaylandServer, nullptr,nullptr,nullptr, napi_default,nullptr},
        {"launchClient",       nullptr, LaunchClient,       nullptr,nullptr,nullptr, napi_default,nullptr},
        {"stopClient",         nullptr, StopClient,         nullptr,nullptr,nullptr, napi_default,nullptr},
        {"stopAll",            nullptr, StopAll,            nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setStateCallback",   nullptr, SetStateCallback,   nullptr,nullptr,nullptr, napi_default,nullptr},
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