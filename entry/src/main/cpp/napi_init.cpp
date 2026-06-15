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
#include <map>
#include <mutex>
#include <memory>

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

    // ★ 客户端进程已退出(pipe EOF 或被主动 kill 后 fd 关闭)
    g_readerRunning = false;
    g_clientPid = -1;
    if (g_stateTsfn) {
        char* dup = strdup("exited");
        napi_call_threadsafe_function(g_stateTsfn, dup, napi_tsfn_blocking);
    }
    OH_LOG_INFO(LOG_APP, "client reader exited, fired state=exited");
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
                      const char* libPath,
                      const std::vector<std::string>& extraEnv) {
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
        
        std::vector<std::string> envHolder = {
            "XDG_RUNTIME_DIR=" + dir,
            "WAYLAND_DISPLAY=" + name,
            "LD_LIBRARY_PATH=" + std::string(libPath),
            "HOME=" + dir,
            "BOX64_LOG=1",
            "BOX64_NOBANNER=0",
        };
        for (const auto& e : extraEnv) {
            if (!e.empty()) envHolder.push_back(e);
        }
        std::vector<char*> envp;
        envp.reserve(envHolder.size() + 1);
        for (auto& s : envHolder) envp.push_back(const_cast<char*>(s.c_str()));
        envp.push_back(nullptr);

        std::vector<char*> cargv;
        cargv.reserve(argvStrs.size() + 1);
        for (const auto& s : argvStrs) cargv.push_back(const_cast<char*>(s.c_str()));
        cargv.push_back(nullptr);
        execve(exePath, cargv.data(), envp.data());
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
    size_t argc = 5; napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char exePath[1024]={0}, sockPath[512]={0}, libPath[1024]={0}; size_t len;
    napi_get_value_string_utf8(env, args[0], exePath, sizeof(exePath), &len);

    uint32_t n = 0;
    napi_get_array_length(env, args[1], &n);
    std::vector<std::string> argvStrs;
    for (uint32_t i = 0; i < n; ++i) {
        napi_value el; napi_get_element(env, args[1], i, &el);
        char b[1024]={0}; napi_get_value_string_utf8(env, el, b, sizeof(b), &len);
        argvStrs.emplace_back(b);
    }
    if (argvStrs.empty()) argvStrs.emplace_back(exePath);

    napi_get_value_string_utf8(env, args[2], sockPath, sizeof(sockPath), &len);
    napi_get_value_string_utf8(env, args[3], libPath, sizeof(libPath), &len);

    // 第 5 个参数:extraEnv string[]
    std::vector<std::string> extraEnv;
    bool hasArr = false;
    napi_is_array(env, args[4], &hasArr);
    if (hasArr) {
        uint32_t en = 0;
        napi_get_array_length(env, args[4], &en);
        for (uint32_t i = 0; i < en; ++i) {
            napi_value el; napi_get_element(env, args[4], i, &el);
            char b[2048]={0};
            napi_get_value_string_utf8(env, el, b, sizeof(b), &len);
            extraEnv.emplace_back(b);
        }
    }

    int pid = LaunchImpl(exePath, argvStrs, sockPath, libPath, extraEnv);
    napi_value r; napi_create_int32(env, pid, &r);
    return r;
}

struct ExecCtx {
    std::string exe;
    std::vector<std::string> argv;
    std::string libPath;
    int code = -1;
    std::string out;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

static void ExecExecuteCB(napi_env, void* data) {
    ExecCtx* c = static_cast<ExecCtx*>(data);
    int pipefd[2];
    if (pipe(pipefd) != 0) { c->code = -1; return; }
    fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        if (pipefd[1] > 2) close(pipefd[1]);
        for (int s = 1; s < 32; ++s) signal(s, SIG_DFL);

        std::string envLdp = "LD_LIBRARY_PATH=" + c->libPath;
        std::string envHome = "HOME=/data/storage/el2/base";
        char* envp[] = {
            (char*)envLdp.c_str(),
            (char*)envHome.c_str(),
            nullptr
        };

        std::vector<char*> cargv;
        cargv.reserve(c->argv.size() + 1);
        for (auto& s : c->argv) cargv.push_back(const_cast<char*>(s.c_str()));
        cargv.push_back(nullptr);
        execve(c->exe.c_str(), cargv.data(), envp);
        _exit(127);
    }
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        c->code = -1;
        return;
    }
    close(pipefd[1]);

    char buf[1024];
    while (true) {
        ssize_t n = read(pipefd[0], buf, sizeof(buf));
        if (n > 0) {
            c->out.append(buf, n);
            if (c->out.size() > 8192) break; // 防止某些工具 -v 输出过多
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            break;
        }
    }
    close(pipefd[0]);

    int status = 0;
    if (waitpid(pid, &status, 0) > 0) {
        c->code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
}

static void ExecCompleteCB(napi_env env, napi_status, void* data) {
    ExecCtx* c = static_cast<ExecCtx*>(data);
    napi_value result, codeVal, outVal;
    napi_create_object(env, &result);
    napi_create_int32(env, c->code, &codeVal);
    napi_create_string_utf8(env, c->out.c_str(), c->out.size(), &outVal);
    napi_set_named_property(env, result, "code", codeVal);
    napi_set_named_property(env, result, "stdout", outVal);
    napi_resolve_deferred(env, c->deferred, result);
    napi_delete_async_work(env, c->work);
    delete c;
}

static napi_value ExecCapture(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    ExecCtx* c = new ExecCtx();
    char buf[1024] = {0}; size_t len;
    napi_get_value_string_utf8(env, args[0], buf, sizeof(buf), &len);
    c->exe = buf;

    uint32_t n = 0;
    napi_get_array_length(env, args[1], &n);
    for (uint32_t i = 0; i < n; ++i) {
        napi_value el;
        napi_get_element(env, args[1], i, &el);
        char b2[1024] = {0};
        napi_get_value_string_utf8(env, el, b2, sizeof(b2), &len);
        c->argv.emplace_back(b2);
    }
    if (c->argv.empty()) c->argv.push_back(c->exe);

    napi_get_value_string_utf8(env, args[2], buf, sizeof(buf), &len);
    c->libPath = buf;

    napi_value promise;
    napi_create_promise(env, &c->deferred, &promise);

    napi_value resName;
    napi_create_string_utf8(env, "ExecCapture", NAPI_AUTO_LENGTH, &resName);
    napi_create_async_work(env, nullptr, resName,
        ExecExecuteCB, ExecCompleteCB, c, &c->work);
    napi_queue_async_work(env, c->work);

    return promise;
}

struct CliEvent {
    int32_t pid;
    std::string event;   // "out" | "exit"
    std::string data;
};

struct CliProc {
    pid_t pid = -1;
    int outFd = -1;
    std::atomic<bool> running{false};
};

static std::mutex g_cliMutex;
static std::map<pid_t, std::shared_ptr<CliProc>> g_cliProcs;
static napi_threadsafe_function g_cliTsfn = nullptr;

static void CliTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    CliEvent* ev = static_cast<CliEvent*>(data);
    if (env && jsCb && ev) {
        napi_value undef, args[3];
        napi_get_undefined(env, &undef);
        napi_create_int32(env, ev->pid, &args[0]);
        napi_create_string_utf8(env, ev->event.c_str(), NAPI_AUTO_LENGTH, &args[1]);
        napi_create_string_utf8(env, ev->data.c_str(), NAPI_AUTO_LENGTH, &args[2]);
        napi_call_function(env, undef, jsCb, 3, args, nullptr);
    }
    delete ev;
}

static void EmitCli(int32_t pid, const char* event, const std::string& data) {
    if (!g_cliTsfn) return;
    CliEvent* ev = new CliEvent();
    ev->pid = pid;
    ev->event = event;
    ev->data = data;
    napi_call_threadsafe_function(g_cliTsfn, ev, napi_tsfn_blocking);
}

static void CliReaderMain(int32_t pid, int fd) {
    char buf[2048];
    std::string pending;
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            pending.append(buf, n);
            size_t pos;
            while ((pos = pending.find('\n')) != std::string::npos) {
                EmitCli(pid, "out", pending.substr(0, pos));
                pending.erase(0, pos + 1);
            }
        } else if (n == 0) {
            break;
        } else {
            if (errno == EINTR) continue;
            break;
        }
    }
    if (!pending.empty()) EmitCli(pid, "out", pending);
    close(fd);

    int status = 0;
    waitpid(pid, &status, 0);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    EmitCli(pid, "exit", std::to_string(code));

    std::lock_guard<std::mutex> lk(g_cliMutex);
    g_cliProcs.erase(pid);
}

static napi_value SetCliCallback(napi_env env, napi_callback_info info) {
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

static napi_value LaunchCli(napi_env env, napi_callback_info info) {
    size_t argc = 5; napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char exePath[1024]={0}, libPath[1024]={0}, cwd[1024]={0}; size_t len;
    napi_get_value_string_utf8(env, args[0], exePath, sizeof(exePath), &len);

    // argv
    uint32_t n = 0;
    napi_get_array_length(env, args[1], &n);
    std::vector<std::string> argvStrs;
    for (uint32_t i = 0; i < n; ++i) {
        napi_value el; napi_get_element(env, args[1], i, &el);
        char b[1024]={0};
        napi_get_value_string_utf8(env, el, b, sizeof(b), &len);
        argvStrs.emplace_back(b);
    }
    if (argvStrs.empty()) argvStrs.emplace_back(exePath);

    napi_get_value_string_utf8(env, args[2], libPath, sizeof(libPath), &len);
    napi_get_value_string_utf8(env, args[3], cwd, sizeof(cwd), &len);

    // extraEnv: string[]
    std::vector<std::string> extraEnv;
    bool isArr = false;
    napi_is_array(env, args[4], &isArr);
    if (isArr) {
        uint32_t en = 0;
        napi_get_array_length(env, args[4], &en);
        for (uint32_t i = 0; i < en; ++i) {
            napi_value el; napi_get_element(env, args[4], i, &el);
            char b[2048]={0};
            napi_get_value_string_utf8(env, el, b, sizeof(b), &len);
            extraEnv.emplace_back(b);
        }
    }

    if (access(exePath, X_OK) != 0) chmod(exePath, 0755);
    if (argvStrs.size() >= 2 && !argvStrs[1].empty() && argvStrs[1][0] == '/') {
        if (access(argvStrs[1].c_str(), X_OK) != 0) {
            chmod(argvStrs[1].c_str(), 0755);
        }
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        napi_value r; napi_create_int32(env, -1, &r); return r;
    }
    fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    signal(SIGCHLD, SIG_IGN);

    pid_t pid = fork();
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        if (pipefd[1] > 2) close(pipefd[1]);
        prctl(PR_SET_NAME, "cli-app", 0, 0, 0);
        close_inherited_fds_except(STDOUT_FILENO, STDERR_FILENO);
        for (int s = 1; s < 32; ++s) signal(s, SIG_DFL);

        if (cwd[0]) {
            if (chdir(cwd) != 0) {
                fprintf(stderr, "chdir(%s) failed: %s\n", cwd, strerror(errno));
            }
        }

        // 默认 env + 调用方 extraEnv
        std::vector<std::string> envHolder = {
            std::string("LD_LIBRARY_PATH=") + libPath,
            std::string("HOME=/data/storage/el2/base"),
            std::string("BOX64_LOG=1"),
            std::string("BOX64_NOBANNER=0"),
            std::string("TERM=xterm-256color"),
        };
        for (const auto& e : extraEnv) {
            if (!e.empty()) envHolder.push_back(e);
        }
        std::vector<char*> envp;
        envp.reserve(envHolder.size() + 1);
        for (auto& s : envHolder) envp.push_back(const_cast<char*>(s.c_str()));
        envp.push_back(nullptr);

        std::vector<char*> cargv;
        cargv.reserve(argvStrs.size() + 1);
        for (auto& s : argvStrs) cargv.push_back(const_cast<char*>(s.c_str()));
        cargv.push_back(nullptr);

        execve(exePath, cargv.data(), envp.data());
        fprintf(stderr, "execve(%s) failed: %s\n", exePath, strerror(errno));
        _exit(127);
    }
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        napi_value r; napi_create_int32(env, -1, &r); return r;
    }
    close(pipefd[1]);

    auto proc = std::make_shared<CliProc>();
    proc->pid = pid;
    proc->outFd = pipefd[0];
    proc->running = true;
    {
        std::lock_guard<std::mutex> lk(g_cliMutex);
        g_cliProcs[pid] = proc;
    }
    std::thread(CliReaderMain, (int32_t)pid, pipefd[0]).detach();

    OH_LOG_INFO(LOG_APP, "cli pid=%{public}d exe=%{public}s envc=%{public}u",
                pid, exePath, (uint32_t)extraEnv.size());
    napi_value r; napi_create_int32(env, pid, &r);
    return r;
}

static napi_value StopCli(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t pid = 0;
    napi_get_value_int32(env, args[0], &pid);
    if (pid > 0) {
        kill(pid, SIGTERM);
    }
    return nullptr;
}

static void KillClientLocked() {
    g_readerRunning = false;
    if (g_clientPid > 0) {
        pid_t pid = g_clientPid;
        g_clientPid = -1;
        kill(pid, SIGTERM);
        OH_LOG_INFO(LOG_APP, "sent SIGTERM to client pid=%{public}d", pid);
        // 异步兜底:800ms 后还活着就 SIGKILL
        std::thread([pid]() {
            usleep(800 * 1000);
            if (kill(pid, 0) == 0) {
                kill(pid, SIGKILL);
                OH_LOG_WARN(LOG_APP,
                    "client pid=%{public}d not exited in 800ms, SIGKILL", pid);
            }
        }).detach();
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

// ====== Keyboard and Mouse =====
static napi_value SendKey(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t code = 0; bool pressed = false;
    napi_get_value_int32(env, args[0], &code);
    napi_get_value_bool(env, args[1], &pressed);
    WaylandServer::GetInstance()->DispatchKey((uint32_t)code, pressed);
    return nullptr;
}

static napi_value SendModifiers(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t v[4] = {0,0,0,0};
    for (int i = 0; i < 4; i++) {
        int32_t t = 0; napi_get_value_int32(env, args[i], &t);
        v[i] = (uint32_t)t;
    }
    WaylandServer::GetInstance()->DispatchModifiers(v[0], v[1], v[2], v[3]);
    return nullptr;
}

static napi_value SendMouseMove(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double x = 0, y = 0;
    napi_get_value_double(env, args[0], &x);
    napi_get_value_double(env, args[1], &y);
    WaylandServer::GetInstance()->DispatchMouseMotion(x, y);
    return nullptr;
}

static napi_value SendMouseButton(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t btn = 0; bool pressed = false;
    napi_get_value_int32(env, args[0], &btn);
    napi_get_value_bool(env, args[1], &pressed);
    WaylandServer::GetInstance()->DispatchMouseButton((uint32_t)btn, pressed);
    return nullptr;
}

static napi_value SendMouseAxis(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double dx = 0, dy = 0;
    napi_get_value_double(env, args[0], &dx);
    napi_get_value_double(env, args[1], &dy);
    WaylandServer::GetInstance()->DispatchMouseAxis(dx, dy);
    return nullptr;
}

static napi_value SendMouseHover(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool inside = false;
    napi_get_value_bool(env, args[0], &inside);
    if (inside) WaylandServer::GetInstance()->DispatchMouseEnter(0, 0);
    else WaylandServer::GetInstance()->DispatchMouseLeave();
    return nullptr;
}

// fix window size
struct SizeEvent { int w; int h; };
static napi_threadsafe_function g_sizeTsfn = nullptr;

// for dragging
static napi_threadsafe_function g_moveTsfn = nullptr;

static void MoveTsfnCallJs(napi_env env, napi_value jsCb, void*, void* /*data*/) {
    if (env && jsCb) {
        napi_value undef;
        napi_get_undefined(env, &undef);
        napi_call_function(env, undef, jsCb, 0, nullptr, nullptr);
    }
}

static napi_value SetMoveCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_moveTsfn) {
        napi_release_threadsafe_function(g_moveTsfn, napi_tsfn_release);
        g_moveTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WLMove", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, MoveTsfnCallJs, &g_moveTsfn);

    WaylandServer::GetInstance()->SetMoveCallback([]() {
        if (g_moveTsfn) {
            napi_call_threadsafe_function(g_moveTsfn, nullptr, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

static void SizeTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    SizeEvent* ev = static_cast<SizeEvent*>(data);
    if (env && jsCb && ev) {
        napi_value undef, args[2];
        napi_get_undefined(env, &undef);
        napi_create_int32(env, ev->w, &args[0]);
        napi_create_int32(env, ev->h, &args[1]);
        napi_call_function(env, undef, jsCb, 2, args, nullptr);
    }
    delete ev;
}

static napi_value SetSizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_sizeTsfn) {
        napi_release_threadsafe_function(g_sizeTsfn, napi_tsfn_release);
        g_sizeTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WLSize", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, SizeTsfnCallJs, &g_sizeTsfn);

    WaylandServer::GetInstance()->SetSizeCallback([](int w, int h) {
        if (g_sizeTsfn) {
            SizeEvent* ev = new SizeEvent{w, h};
            napi_call_threadsafe_function(g_sizeTsfn, ev, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

static napi_value GetLatestSize(napi_env env, napi_callback_info /*info*/) {
    int w = 0, h = 0;
    WaylandServer::GetInstance()->GetLatestSize(w, h);
    napi_value result, vw, vh;
    napi_create_object(env, &result);
    napi_create_int32(env, w, &vw);
    napi_create_int32(env, h, &vh);
    napi_set_named_property(env, result, "w", vw);
    napi_set_named_property(env, result, "h", vh);
    return result;
}

// for maximize window
static napi_threadsafe_function g_maximizeTsfn = nullptr;
static napi_threadsafe_function g_unmaximizeTsfn = nullptr;
static napi_threadsafe_function g_resizeTsfn = nullptr;

static void MaximizeTsfnCallJs(napi_env env, napi_value jsCb, void*, void* /*data*/) {
    if (env && jsCb) {
        napi_value undef;
        napi_get_undefined(env, &undef);
        napi_call_function(env, undef, jsCb, 0, nullptr, nullptr);
    }
}

static void ResizeTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    uint32_t* edges = static_cast<uint32_t*>(data);
    if (env && jsCb && edges) {
        napi_value undef, arg;
        napi_get_undefined(env, &undef);
        napi_create_uint32(env, *edges, &arg);
        napi_call_function(env, undef, jsCb, 1, &arg, nullptr);
    }
    delete edges;
}

static napi_value SetMaximizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_maximizeTsfn) {
        napi_release_threadsafe_function(g_maximizeTsfn, napi_tsfn_release);
        g_maximizeTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WLMaximize", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, MaximizeTsfnCallJs, &g_maximizeTsfn);

    WaylandServer::GetInstance()->SetMaximizeCallback([]() {
        if (g_maximizeTsfn) {
            napi_call_threadsafe_function(g_maximizeTsfn, nullptr, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

static napi_value SetUnmaximizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_unmaximizeTsfn) {
        napi_release_threadsafe_function(g_unmaximizeTsfn, napi_tsfn_release);
        g_unmaximizeTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WLUnmaximize", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, MaximizeTsfnCallJs, &g_unmaximizeTsfn);

    WaylandServer::GetInstance()->SetUnmaximizeCallback([]() {
        if (g_unmaximizeTsfn) {
            napi_call_threadsafe_function(g_unmaximizeTsfn, nullptr, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

static napi_value SetResizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_resizeTsfn) {
        napi_release_threadsafe_function(g_resizeTsfn, napi_tsfn_release);
        g_resizeTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WLResize", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, ResizeTsfnCallJs, &g_resizeTsfn);

    WaylandServer::GetInstance()->SetResizeCallback([](uint32_t edges) {
        if (g_resizeTsfn) {
            uint32_t* e = new uint32_t(edges);
            napi_call_threadsafe_function(g_resizeTsfn, e, napi_tsfn_blocking);
        }
    });
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
        {"execCapture",        nullptr, ExecCapture,        nullptr,nullptr,nullptr, napi_default,nullptr},
        {"launchCli",          nullptr, LaunchCli,          nullptr,nullptr,nullptr, napi_default,nullptr},
        {"stopCli",            nullptr, StopCli,            nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setCliCallback",     nullptr, SetCliCallback,     nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendKey",         nullptr, SendKey,         nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendModifiers",   nullptr, SendModifiers,   nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendMouseMove",   nullptr, SendMouseMove,   nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendMouseButton", nullptr, SendMouseButton, nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendMouseAxis",   nullptr, SendMouseAxis,   nullptr,nullptr,nullptr, napi_default,nullptr},
        {"sendMouseHover",  nullptr, SendMouseHover,  nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setSizeCallback",    nullptr, SetSizeCallback,    nullptr,nullptr,nullptr, napi_default,nullptr},
        {"getLatestSize",      nullptr, GetLatestSize,      nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setMoveCallback",    nullptr, SetMoveCallback,    nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setMaximizeCallback",    nullptr, SetMaximizeCallback,    nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setUnmaximizeCallback",  nullptr, SetUnmaximizeCallback,  nullptr,nullptr,nullptr, napi_default,nullptr},
        {"setResizeCallback",      nullptr, SetResizeCallback,      nullptr,nullptr,nullptr, napi_default,nullptr},
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