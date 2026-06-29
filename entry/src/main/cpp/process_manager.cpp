#include "process_manager.h"

#include "fs_utils.h"
#include "napi_utils.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sys/uio.h>      // struct iovec, recvmsg/sendmsg 用

#undef LOG_TAG
#define LOG_TAG "HBox_NAPI_ProcMgr"
#include <hilog/log.h>

extern "C" char** environ;

namespace procmgr {

// ============================================================
//  内部 Registry 单例
// ============================================================
namespace {

class Manager {
public:
    static Manager& Instance() {
        static Manager s;
        return s;
    }

    void Register(const ProcessInfo& info) {
        std::lock_guard<std::mutex> lk(mu_);
        table_[info.pid] = info;
    }
    
    std::optional<ProcessInfo> Lookup(pid_t pid) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = table_.find(pid);
        if (it == table_.end()) return std::nullopt;
        return it->second;
    }

    void MarkExited(pid_t pid, int exit_code) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = table_.find(pid);
        if (it != table_.end()) {
            it->second.alive = false;
            it->second.exit_code = exit_code;
            // 释放本节点对 sink 的引用. 若链上还有活进程持有,
            // shared_ptr 不会真析构. 全死光才触发 deleter 里的
            // napi_release_threadsafe_function.
            it->second.shared_stream.reset();
            it->second.shared_capture.reset();
        }
    }

    std::vector<ProcessInfo> Snapshot() {
        std::lock_guard<std::mutex> lk(mu_);
        std::vector<ProcessInfo> out;
        out.reserve(table_.size());
        for (auto& kv : table_) out.push_back(kv.second);
        return out;
    }

private:
    std::mutex mu_;
    std::unordered_map<pid_t, ProcessInfo> table_;
};

int64_t NowMillis() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(
        system_clock::now().time_since_epoch()).count();
}

// ============================================================
//  通用辅助
// ============================================================

// 与 box64 一致, 读 BOX64_LOG 环境变量, 缓存到进程级.
// 0 = 静默, 1 = INFO, 2 = DEBUG.
// HAP 主进程读 self environ; sock-spawned 子进程会从父进程继承.
int GetBox64LogLevel() {
    static int cached = -1;
    if (cached >= 0) return cached;
    const char* v = getenv("BOX64_LOG");
    cached = (v && *v) ? atoi(v) : 0;
    if (cached < 0) cached = 0;
    return cached;
}
#define BOX64_LOG_INFO(...)  \
    do { if (GetBox64LogLevel() >= 1) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)
#define BOX64_LOG_DEBUG(...) \
    do { if (GetBox64LogLevel() >= 2) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)

bool EndsWithBox64(const std::string& path) {
    // 比较 basename,不是简单 endswith("box64"),避免误判 "winebox64" 这种
    auto slash = path.find_last_of('/');
    std::string base = (slash == std::string::npos)
                        ? path
                        : path.substr(slash + 1);
    return base == "box64";
}

LaunchKind ResolveKind(const SpawnRequest& req) {
    switch (req.kind_hint) {
        case KindHint::kForceNative: return LaunchKind::kNative;
        case KindHint::kForceBox64:  return LaunchKind::kBox64;
        case KindHint::kAuto:        break;
    }
    return EndsWithBox64(req.exe_path) ? LaunchKind::kBox64
                                       : LaunchKind::kNative;
}

const char* KindCStr(LaunchKind k) {
    return k == LaunchKind::kBox64 ? "box64" : "native";
}

void CloseInheritedFdsExcept(int keep1, int keep2) {
    DIR* d = opendir("/proc/self/fd");
    if (!d) return;
    int dfd = dirfd(d);
    struct dirent* e;
    while ((e = readdir(d))) {
        int fd = atoi(e->d_name);
        if (fd > 2 && fd != dfd && fd != keep1 && fd != keep2) close(fd);
    }
    closedir(d);
}

void CloseInheritedFdsExceptList(int keep1, int keep2,
                                 const std::vector<int>& extra_keep) {
    DIR* d = opendir("/proc/self/fd");
    if (!d) return;
    int dfd = dirfd(d);
    struct dirent* e;
    while ((e = readdir(d))) {
        int fd = atoi(e->d_name);
        if (fd <= 2) continue;
        if (fd == dfd || fd == keep1 || fd == keep2) continue;
        bool keep = false;
        for (int k : extra_keep) { if (fd == k) { keep = true; break; } }
        if (keep) continue;
        close(fd);
    }
    closedir(d);
}

pid_t GetPPid(pid_t pid) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/status", (int)pid);
    FILE* f = fopen(path, "r");
    if (!f) return -1;
    char line[256];
    pid_t ppid = -1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "PPid:", 5) == 0) {
            ppid = (pid_t)atoi(line + 5);
            break;
        }
    }
    fclose(f);
    return ppid;
}

// ============================================================
//  子进程内: box64 装载
// ============================================================

// 释放从父进程继承下来的低 4GB anon/ark VM 区域,给 ET_EXEC link base 让位。
void UnmapLowAnonRegions() {
    FILE* f = fopen("/proc/self/maps", "r");
    if (!f) {
        fprintf(stderr, "[procmgr] open /proc/self/maps failed\n");
        return;
    }

    struct Region { unsigned long start, end; };
    std::vector<Region> targets;

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        unsigned long start = 0, end = 0;
        char prot[8] = {0};
        char tag[256] = {0};
        int n = sscanf(line, "%lx-%lx %7s %*s %*s %*s %255[^\n]",
                       &start, &end, prot, tag);
        if (n < 3) continue;
        if (start >= 0x100000000UL) continue;
        bool is_ark      = strstr(tag, "[anon:ark") != nullptr;
        bool is_pure_anon = (n < 4) || (tag[0] == 0);
        if (is_ark || is_pure_anon) targets.push_back({start, end});
    }
    fclose(f);

    int ok = 0, fail = 0;
    unsigned long total = 0;
    for (auto& r : targets) {
        size_t len = r.end - r.start;
        if (munmap((void*)r.start, len) == 0) {
            ok++;
            total += len;
        } else {
            fail++;
        }
    }
    BOX64_LOG_DEBUG("[procmgr] freed %d regions, total=%lu MB, failures=%d\n",
                ok, total / 1024 / 1024, fail);
    fflush(stderr);
}

using Box64RunFn = int (*)(int argc, const char** argv, const char** env);

Box64RunFn LoadBox64RunInChild(void** out_handle) {
    std::vector<std::string> candidates;
    candidates.emplace_back("libbox64.so");
    if (const char* ld = getenv("LD_LIBRARY_PATH")) {
        std::string s = ld;
        size_t start = 0;
        while (start <= s.size()) {
            size_t end = s.find(':', start);
            if (end == std::string::npos) end = s.size();
            std::string dir = s.substr(start, end - start);
            if (!dir.empty()) candidates.push_back(dir + "/libbox64.so");
            if (end == s.size()) break;
            start = end + 1;
        }
    }
    candidates.emplace_back("/data/storage/el1/bundle/libs/arm64/libbox64.so");
    candidates.emplace_back("/data/storage/el1/bundle/entry/libs/arm64/libbox64.so");

    void* h = nullptr;
    for (const auto& path : candidates) {
        h = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            BOX64_LOG_INFO("[procmgr] dlopen ok: %s\n", path.c_str());
            break;
        }
        fprintf(stderr, "[procmgr] dlopen %s -> %s\n",
                path.c_str(), dlerror());
    }
    if (!h) {
        fprintf(stderr, "[procmgr] FATAL: child cannot dlopen libbox64.so\n");
        return nullptr;
    }

    auto fn = (Box64RunFn)dlsym(h, "box64_run");
    if (!fn) {
        fprintf(stderr, "[procmgr] FATAL: dlsym(box64_run) failed: %s\n",
                dlerror());
        dlclose(h);
        return nullptr;
    }
    BOX64_LOG_DEBUG("[procmgr] box64_run = %p\n", (void*)fn);
    fflush(stderr);
    *out_handle = h;
    return fn;
}

void ApplyEnvToEnviron(const std::vector<std::string>& env) {
    for (const auto& kv : env) {
        if (kv.empty()) continue;
        auto eq = kv.find('=');
        if (eq == std::string::npos) continue;
        setenv(kv.substr(0, eq).c_str(),
               kv.substr(eq + 1).c_str(), 1);
    }
}

// ============================================================
//  Reader / Waiter 线程
// ============================================================

void StreamReaderMain(int fd, pid_t pid, StreamSink sink) {
    char buf[2048];
    std::string pending;
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            pending.append(buf, n);
            size_t pos;
            while ((pos = pending.find('\n')) != std::string::npos) {
                if (sink.on_line) sink.on_line(pid, pending.substr(0, pos));
                pending.erase(0, pos + 1);
            }
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            break;
        }
    }
    if (!pending.empty() && sink.on_line) sink.on_line(pid, pending);
    close(fd);

    int status = 0;
    int code = -1;
    if (waitpid(pid, &status, 0) > 0) {
        code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    // 顺序: 先 on_exit (sink.on_exit 内的 tsfn 还有效),
    // 再 MarkExited (可能触发 shared_ptr deleter 释放 tsfn).
    if (sink.on_exit) sink.on_exit(pid, code);
    Manager::Instance().MarkExited(pid, code);
}

void CaptureReaderMain(int fd, pid_t pid, CaptureSink sink) {
    std::string out;
    char buf[1024];
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            out.append(buf, n);
            if (out.size() > sink.max_bytes) break;
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            break;
        }
    }
    close(fd);

    int status = 0;
    int code = -1;
    if (waitpid(pid, &status, 0) > 0) {
        code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    if (sink.on_done) sink.on_done(code, std::move(out));
    Manager::Instance().MarkExited(pid, code);
}

// 没有 sink 的进程也要回收,避免僵尸 + Registry 状态滞后
void WaiterOnlyMain(pid_t pid) {
    int status = 0;
    int code = -1;
    if (waitpid(pid, &status, 0) > 0) {
        code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    Manager::Instance().MarkExited(pid, code);
}

// 同步等子进程退出, 更新 Registry, 返回 exit code (signal kill -> 128+sig).
int WaitChildSync(pid_t pid) {
    int status = 0;
    int code = -1;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) { code = -1; break; }
    }
    if      (WIFEXITED(status))   code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    Manager::Instance().MarkExited(pid, code);
    return code;
}

// 同步路径专用 reader. 只读 pipe + 喂 sink.on_line,
// 不做 waitpid (由主线程 WaitChildSync 负责),
// 不调 sink.on_exit (避免 sock 链上每代 child 都给 ArkTS 发 'exit').
//
// 顶层 NAPI 直调那条进程的 reader 仍走 StreamReaderMain, 它在最终
// pipe EOF 时触发唯一一次 on_exit, 把 'exit' 事件交给 ArkTS.
void StreamReaderNoWaitMain(int fd, pid_t pid, StreamSink sink) {
    char buf[2048];
    std::string pending;
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            pending.append(buf, n);
            size_t pos;
            while ((pos = pending.find('\n')) != std::string::npos) {
                if (sink.on_line) sink.on_line(pid, pending.substr(0, pos));
                pending.erase(0, pos + 1);
            }
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            break;
        }
    }
    if (!pending.empty() && sink.on_line) sink.on_line(pid, pending);
    close(fd);
    // 故意不做 waitpid / MarkExited / on_exit
}

void CaptureReaderNoWaitMain(int fd, pid_t pid, CaptureSink sink) {
    std::string out;
    char buf[1024];
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            out.append(buf, n);
            if (out.size() > sink.max_bytes) break;
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            break;
        }
    }
    close(fd);
    (void)pid; (void)out;   // sync_wait 路径不调 on_done
}

// ============================================================
//  fork 通用前置
// ============================================================

// 返回值: 父侧返回 child pid (>0); child 侧返回 0; 失败 -1。
// need_pipe=true 时,父侧成功后 *out_read_fd 是 pipe 读端。
pid_t ForkWithIo(bool need_pipe,
                 const std::string& cwd,
                 const char* proc_name,
                 const std::vector<SpawnRequest::InheritedFd>& inherited_fds,
                 int* out_read_fd) {
    int pipefd[2] = {-1, -1};
    if (need_pipe) {
        if (pipe(pipefd) != 0) {
            OH_LOG_ERROR(LOG_APP, "pipe failed: %{public}s", strerror(errno));
            return -1;
        }
        fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    }
    
    pid_t pid = fork();
    if (pid < 0) {
        if (need_pipe) { close(pipefd[0]); close(pipefd[1]); }
        OH_LOG_ERROR(LOG_APP, "fork failed: %{public}s", strerror(errno));
        return -1;
    }

    if (pid == 0) {
        // ---- child ----
        if (need_pipe) {
            close(pipefd[0]);
            dup2(pipefd[1], STDOUT_FILENO);
            dup2(pipefd[1], STDERR_FILENO);
            if (pipefd[1] > 2) close(pipefd[1]);
            // pipe 不是 tty, glibc 默认 stdout 全缓冲。
            // 强制 stdout 行缓冲、stderr 无缓冲,短输出也能即时流到 reader。
            setvbuf(stdout, nullptr, _IOLBF, 0);
            setvbuf(stderr, nullptr, _IONBF, 0);
        } else {
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, STDOUT_FILENO);
                dup2(devnull, STDERR_FILENO);
                if (devnull > 2) close(devnull);
            }
        }

        if (proc_name && proc_name[0]) {
            prctl(PR_SET_NAME, proc_name, 0, 0, 0);
        }
        
        // 先把 inherited fd 放到 target 位置, 再 close 其余, 顺序很重要.
        std::vector<int> keep_target_fds;
        keep_target_fds.reserve(inherited_fds.size());
        for (const auto& f : inherited_fds) {
            if (f.source_fd == f.target_fd) {
                // 已经在目标位置, 清掉 CLOEXEC 即可
                int fl = fcntl(f.target_fd, F_GETFD);
                if (fl >= 0) fcntl(f.target_fd, F_SETFD, fl & ~FD_CLOEXEC);
            } else {
                if (dup2(f.source_fd, f.target_fd) < 0) {
                    fprintf(stderr,
                        "[procmgr child] dup2(%d -> %d) failed: %s\n",
                        f.source_fd, f.target_fd, strerror(errno));
                    _exit(124);
                }
                close(f.source_fd);
                int fl = fcntl(f.target_fd, F_GETFD);
                if (fl >= 0) fcntl(f.target_fd, F_SETFD, fl & ~FD_CLOEXEC);
            }
            keep_target_fds.push_back(f.target_fd);
            fprintf(stderr, "[procmgr child] inherited fd ready: %d\n",
                    f.target_fd);
        }
        CloseInheritedFdsExceptList(STDOUT_FILENO, STDERR_FILENO, keep_target_fds);
        for (int s = 1; s < 32; ++s) signal(s, SIG_DFL);
        if (!cwd.empty() && chdir(cwd.c_str()) != 0) {
            fprintf(stderr, "chdir(%s) failed: %s\n",
                    cwd.c_str(), strerror(errno));
        }
        return 0;
    }

    // ---- parent ----
    if (need_pipe) {
        close(pipefd[1]);
        if (out_read_fd) *out_read_fd = pipefd[0];
    }
    return pid;
}

void StartReader(int fd, pid_t pid,
                 StreamSink* stream, CaptureSink* capture) {
    if (stream) {
        std::thread(StreamReaderMain, fd, pid, *stream).detach();
    } else if (capture) {
        std::thread(CaptureReaderMain, fd, pid, *capture).detach();
    } else {
        close(fd);
        std::thread(WaiterOnlyMain, pid).detach();
    }
}

// ============================================================
//  两种 spawn 路径
// ============================================================

pid_t SpawnNative(const SpawnRequest& req) {
    bool need_pipe = (req.stream || req.capture);
    int read_fd = -1;
    pid_t pid = ForkWithIo(need_pipe, req.cwd,
                       req.proc_name.empty() ? "..." : req.proc_name.c_str(),
                       req.inherited_fds,
                       &read_fd);
    if (pid < 0) return -1;

    if (pid == 0) {
        // ---- child ----
        std::vector<char*> envp;
        envp.reserve(req.env.size() + 1);
        for (auto& s : const_cast<std::vector<std::string>&>(req.env)) {
            envp.push_back(const_cast<char*>(s.c_str()));
        }
        envp.push_back(nullptr);

        // argv 兜底
        std::vector<std::string> argv_storage = req.argv;
        if (argv_storage.empty()) argv_storage.push_back(req.exe_path);

        std::vector<char*> cargv;
        cargv.reserve(argv_storage.size() + 1);
        for (auto& s : argv_storage) {
            cargv.push_back(const_cast<char*>(s.c_str()));
        }
        cargv.push_back(nullptr);

        execve(req.exe_path.c_str(), cargv.data(), envp.data());
        fprintf(stderr, "execve(%s) failed: %s\n",
                req.exe_path.c_str(), strerror(errno));
        fflush(NULL);
        _exit(127);
    }

    // ---- parent ----
    if (req.sync_wait) {
        // 同步模式 + sink: 起 NoWait reader 喂 sink.on_line, 但 waitpid
        // 由 Spawn() 主线程的 WaitChildSync 做. 同步模式无 sink: read_fd
        // 就是 -1 (need_pipe=false), 不起任何线程.
        if (req.stream && read_fd >= 0) {
            std::thread(StreamReaderNoWaitMain, read_fd, pid, *req.stream).detach();
        } else if (req.capture && read_fd >= 0) {
            std::thread(CaptureReaderNoWaitMain, read_fd, pid, *req.capture).detach();
        } else if (read_fd >= 0) {
            close(read_fd);
        }
    } else {
        StartReader(read_fd, pid, req.stream, req.capture);
    }
    return pid;
}

pid_t SpawnBox64(const SpawnRequest& req) {
    bool need_pipe = (req.stream || req.capture);
    int read_fd = -1;
    pid_t pid = ForkWithIo(need_pipe, req.cwd,
                       req.proc_name.empty() ? "..." : req.proc_name.c_str(),
                       req.inherited_fds,
                       &read_fd);
    if (pid < 0) return -1;

    if (pid == 0) {
        // ---- child ----
        ApplyEnvToEnviron(req.env);
        UnmapLowAnonRegions();

        // argv 兜底: 至少要有 [box64, ...] 才能让 box64_run 正常解析
        std::vector<std::string> argv_storage = req.argv;
        if (argv_storage.empty()) {
            argv_storage.push_back(req.exe_path);  // "box64"
        }

        const int total_argc = (int)argv_storage.size();
        std::vector<char> blob;
        std::vector<size_t> offs(total_argc);
        for (int i = 0; i < total_argc; i++) {
            offs[i] = blob.size();
            blob.insert(blob.end(),
                        argv_storage[i].begin(), argv_storage[i].end());
            blob.push_back('\0');
        }
        blob.resize(blob.size() + 64, 0);
        std::vector<const char*> argv2(total_argc + 1, nullptr);
        for (int i = 0; i < total_argc; i++) {
            argv2[i] = blob.data() + offs[i];
        }

        // SpawnBox64 child 分支里的 argv dump:
        if (GetBox64LogLevel() >= 1) {
            fprintf(stderr, "[procmgr] box64 argv (argc=%d):\n", total_argc);
            for (int i = 0; i < total_argc; i++) {
                fprintf(stderr, "  argv[%d] = %s\n", i, argv2[i]);
            }
            fflush(stderr);
        }

        void* handle = nullptr;
        Box64RunFn fn = LoadBox64RunInChild(&handle);
        if (!fn) {
            fprintf(stderr, "[procmgr] cannot resolve box64_run, exit 125\n");
            fflush(stderr);
            _exit(125);
        }

        int rc = fn(total_argc, argv2.data(), (const char**)environ);
        fprintf(stderr,
            "[procmgr] box64_run returned %d (0x%x), exit with %d\n",
            rc, rc, rc & 0xFF);
        fflush(NULL);
        _exit(rc & 0xFF);
    }

    // ---- parent ----
    if (req.sync_wait) {
        if (req.stream && read_fd >= 0) {
            std::thread(StreamReaderNoWaitMain, read_fd, pid, *req.stream).detach();
        } else if (req.capture && read_fd >= 0) {
            std::thread(CaptureReaderNoWaitMain, read_fd, pid, *req.capture).detach();
        } else if (read_fd >= 0) {
            close(read_fd);
        }
    } else {
        StartReader(read_fd, pid, req.stream, req.capture);
    }
    return pid;
}

} // anonymous namespace

// ============================================================
//  对外 API 实现
// ============================================================

SpawnResult Spawn(const SpawnRequest& req_in) {
    SpawnRequest req = req_in;   // 拷贝以便回填 raw 指针
    
    // shared_ptr -> raw 转发 (raw 指针仍然由 ForkWithIo / reader 用)
    if (req.shared_stream  && !req.stream)  req.stream  = req.shared_stream.get();
    if (req.shared_capture && !req.capture) req.capture = req.shared_capture.get();
    
    SpawnResult res;
    res.kind = ResolveKind(req);

    // ---- validation ----
    if (req.stream && req.capture) {
        res.error = "stream and capture are mutually exclusive";
        OH_LOG_ERROR(LOG_APP, "%{public}s", res.error.c_str());
        return res;
    }
    // deleted this validcation
    // if (req.sync_wait && (req.stream || req.capture)) {
    //     res.error = "sync_wait excludes stream/capture";
    //     OH_LOG_ERROR(LOG_APP, "%{public}s", res.error.c_str());
    //     return res;
    // }
    if (req.exe_path.empty()) {
        res.error = "exe_path is empty";
        return res;
    }

    // Box64 模式下 exe_path 实际不被 execve,仅用于 chmod / log
    if (res.kind == LaunchKind::kNative) {
        fsutil::EnsureExecutable(req.exe_path.c_str());
    } else {
        // 多见情形: argv[1] 是 guest ELF,顺手 chmod 一下
        if (req.argv.size() >= 2 &&
            !req.argv[1].empty() && req.argv[1][0] == '/') {
            fsutil::EnsureExecutable(req.argv[1].c_str());
        }
    }

    // ---- fork+exec ----
    pid_t pid = (res.kind == LaunchKind::kBox64) ? SpawnBox64(req)
                                                 : SpawnNative(req);
    if (pid <= 0) {
        res.pid = -1;
        res.error = "fork/exec failed";
        return res;
    }

    ProcessInfo info;
    info.pid           = pid;
    info.parent_pid    = req.caller_pid > 0 ? req.caller_pid : getpid();
    // caller_pid 字段: 见 Step 3, 加到 SpawnRequest. 如果嫌字段多,
    // 也可以从全局 thread_local "current_peer_pid" 取, 但显式字段更干净.
    info.kind          = res.kind;
    info.exe_path      = req.exe_path;
    info.start_time_ms = NowMillis();
    info.alive         = true;
    info.shared_stream  = req.shared_stream;
    info.shared_capture = req.shared_capture;
    Manager::Instance().Register(info);

    OH_LOG_INFO(LOG_APP,
        "spawn ok pid=%{public}d kind=%{public}s exe=%{public}s argc=%{public}u",
        pid, KindCStr(res.kind), req.exe_path.c_str(),
        (uint32_t)req.argv.size());

    res.pid = pid;
    
    // ---- sync wait or async return ----
    if (req.sync_wait) {
        res.exit_code = WaitChildSync(pid);
        OH_LOG_INFO(LOG_APP,
            "sync spawn done pid=%{public}d kind=%{public}s exit=%{public}d",
            pid, KindCStr(res.kind), res.exit_code);
    } else {
        OH_LOG_INFO(LOG_APP,
            "spawn ok pid=%{public}d kind=%{public}s exe=%{public}s argc=%{public}u",
            pid, KindCStr(res.kind), req.exe_path.c_str(),
            (uint32_t)req.argv.size());
    }
    
    return res;
}

void Terminate(pid_t pid) {
    if (pid <= 0) return;
    kill(pid, SIGTERM);
    OH_LOG_INFO(LOG_APP, "sent SIGTERM to pid=%{public}d", pid);
    std::thread([pid]() {
        usleep(800 * 1000);
        if (kill(pid, 0) == 0) {
            kill(pid, SIGKILL);
            OH_LOG_WARN(LOG_APP,
                "pid=%{public}d not exited in 800ms, SIGKILL", pid);
        }
    }).detach();
}

std::vector<ProcessInfo> ListProcesses() {
    return Manager::Instance().Snapshot();
}

// ============================================================
//  Control Socket
//  -----------------------------------------------------------
//  目的: 让 box64 子进程(因为已 dlopen libbox64.so,自己 fork 出来的
//       子进程会因 OHOS LSM 失去 PROT_EXEC)能反向请求主进程帮它 spawn。
//
//  线协议: 帧 = [4 字节大端长度] + [文本 payload]
//
//  Request:
//      CMD CREATE
//      REQ_ID <int>
//      EXE <path>
//      ARG <arg>           (可重复,顺序敏感)
//      ENV <KEY=VAL>       (可重复)
//      CWD <path>          (可选)
//      KIND auto|native|box64
//      END
//
//  Response:
//      RESULT
//      REQ_ID <int>
//      STATUS ok | error
//      PID <pid>           (仅 ok)
//      KIND <kind>         (仅 ok)
//      MSG <text>          (仅 error)
//      END
//
//  其它命令: PING -> PONG, LIST -> 多行 INFO ... END, TERMINATE <pid>
// ============================================================
namespace {

struct ControlState {
    std::atomic<bool> running{false};
    std::atomic<int>  active{0};
    int               listen_fd = -1;
    std::string       sock_path;
    std::thread       accept_thread;
};
ControlState g_ctrl;

constexpr int kMaxControlClients = 32; 

bool ReadExact(int fd, void* buf, size_t n) {
    auto* p = static_cast<uint8_t*>(buf);
    while (n) {
        ssize_t r = recv(fd, p, n, 0);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return false;
        }
        p += r; n -= r;
    }
    return true;
}

bool WriteExact(int fd, const void* buf, size_t n) {
    auto* p = static_cast<const uint8_t*>(buf);
    while (n) {
        ssize_t r = send(fd, p, n, MSG_NOSIGNAL);
        if (r <= 0) {
            if (r < 0 && errno == EINTR) continue;
            return false;
        }
        p += r; n -= r;
    }
    return true;
}

// 第一段用 recvmsg 拿头 + cmsg, 后续 payload 用 recv 续读.
// 单次 sendmsg 帧 = 4B 长度 + payload. cmsg 只附在第一段.
bool ReadFrameWithFds(int fd, std::string* out_payload,
                     std::vector<int>* out_fds) {
    out_payload->clear();
    out_fds->clear();

    char first_buf[4096];
    char cmsg_buf[CMSG_SPACE(sizeof(int) * 16)];

    struct iovec iov;
    iov.iov_base = first_buf;
    iov.iov_len  = sizeof(first_buf);

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov        = &iov;
    msg.msg_iovlen     = 1;
    msg.msg_control    = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);

    ssize_t n;
    do { n = recvmsg(fd, &msg, 0); }
    while (n < 0 && errno == EINTR);
    if (n < 4) return false;

    // 收割 cmsg fds (可能为 0)
    for (struct cmsghdr* cm = CMSG_FIRSTHDR(&msg); cm;
         cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS) {
            size_t n_fds = (cm->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            const int* fds = (const int*)CMSG_DATA(cm);
            for (size_t i = 0; i < n_fds; i++) {
                int got = fds[i];
                // 立刻 unset CLOEXEC, 否则 fork+execve 时会被 kernel 关掉
                int fl = fcntl(got, F_GETFD);
                if (fl >= 0) fcntl(got, F_SETFD, fl & ~FD_CLOEXEC);
                out_fds->push_back(got);
            }
        }
    }

    // 解析长度头 (大端)
    uint32_t total = ((uint32_t)(uint8_t)first_buf[0] << 24)
                   | ((uint32_t)(uint8_t)first_buf[1] << 16)
                   | ((uint32_t)(uint8_t)first_buf[2] << 8)
                   |  (uint32_t)(uint8_t)first_buf[3];
    if (total > 1024 * 1024) {
        OH_LOG_ERROR(LOG_APP, "[ctrl] frame too large: %{public}u", total);
        for (int f : *out_fds) close(f);
        out_fds->clear();
        return false;
    }

    size_t got_payload = (size_t)(n - 4);
    if (got_payload > total) got_payload = total;
    out_payload->assign(first_buf + 4, got_payload);

    if (got_payload < total) {
        size_t remaining = total - got_payload;
        size_t off = out_payload->size();
        out_payload->resize(total);
        uint8_t* p = (uint8_t*)&(*out_payload)[off];
        while (remaining) {
            ssize_t r = recv(fd, p, remaining, 0);
            if (r == 0) {
                for (int f : *out_fds) close(f);
                out_fds->clear();
                return false;
            }
            if (r < 0) {
                if (errno == EINTR) continue;
                for (int f : *out_fds) close(f);
                out_fds->clear();
                return false;
            }
            p += r;
            remaining -= (size_t)r;
        }
    }
    return true;
}

// 兼容老调用: 不要 fds. 任何 cmsg 附带的 fd 直接 close 掉避免泄漏.
bool ReadFrame(int fd, std::string* out) {
    std::vector<int> dummy;
    bool ok = ReadFrameWithFds(fd, out, &dummy);
    for (int f : dummy) close(f);
    return ok;
}

bool WriteFrame(int fd, const std::string& payload) {
    uint32_t len = (uint32_t)payload.size();
    uint8_t hdr[4] = {
        (uint8_t)(len >> 24), (uint8_t)(len >> 16),
        (uint8_t)(len >> 8),  (uint8_t) len,
    };
    if (!WriteExact(fd, hdr, 4)) return false;
    return WriteExact(fd, payload.data(), len);
}

// 把 "KEY VAL..." 这样的一行拆成 (key, rest);找不到空格则 rest = ""
std::pair<std::string, std::string> SplitKV(const std::string& line) {
    auto sp = line.find(' ');
    if (sp == std::string::npos) return {line, ""};
    return {line.substr(0, sp), line.substr(sp + 1)};
}

void HandleCreate(const std::vector<std::string>& lines,
                  std::vector<int>& cmsg_fds,    // 注意: 引用, 我们会接管 fd 所有权
                  pid_t peer_pid,
                  std::string* resp) {
    SpawnRequest req;
    int req_id = 0;
    bool sync_wait = false;
    int proto_ver = 1;
    std::vector<int> fdref_targets;

    for (const auto& ln : lines) {
        auto kv = SplitKV(ln);
        if      (kv.first == "PROTO_VER") proto_ver = atoi(kv.second.c_str());
        else if (kv.first == "REQ_ID")    req_id    = atoi(kv.second.c_str());
        else if (kv.first == "EXE")       req.exe_path = kv.second;
        else if (kv.first == "ARG")       req.argv.push_back(kv.second);
        else if (kv.first == "ENV")       req.env.push_back(kv.second);
        else if (kv.first == "CWD")       req.cwd = kv.second;
        else if (kv.first == "WAIT")      sync_wait = (kv.second == "1");
        else if (kv.first == "FDREF") {
            fdref_targets.push_back(atoi(kv.second.c_str()));
        }
        else if (kv.first == "KIND") {
            if      (kv.second == "native") req.kind_hint = KindHint::kForceNative;
            else if (kv.second == "box64")  req.kind_hint = KindHint::kForceBox64;
            else                            req.kind_hint = KindHint::kAuto;
        }
    }

    req.sync_wait = sync_wait;

    // ---- FDREF / cmsg pairing ----
    auto fail_resp = [&](const char* msg) {
        for (int f : cmsg_fds) close(f);
        cmsg_fds.clear();
        std::string& s = *resp;
        s  = "RESULT\nREQ_ID " + std::to_string(req_id) + "\n";
        s += "STATUS error\nMSG " + std::string(msg) + "\nEND";
    };

    if (proto_ver >= 2) {
        if (fdref_targets.size() != cmsg_fds.size()) {
            OH_LOG_ERROR(LOG_APP,
                "[ctrl] FDREF/SCM_RIGHTS mismatch: fdref=%{public}zu cmsg=%{public}zu",
                fdref_targets.size(), cmsg_fds.size());
            fail_resp("fdref_count_mismatch");
            return;
        }
        for (size_t i = 0; i < cmsg_fds.size(); i++) {
            int tgt = fdref_targets[i];
            if (tgt <= 2) {
                OH_LOG_ERROR(LOG_APP,
                    "[ctrl] refuse FDREF target=%{public}d (<=2)", tgt);
                fail_resp("fdref_bad_target");
                return;
            }
            SpawnRequest::InheritedFd f;
            f.target_fd = tgt;
            f.source_fd = cmsg_fds[i];
            req.inherited_fds.push_back(f);
            OH_LOG_INFO(LOG_APP,
                "[ctrl] FDREF accepted: source=%{public}d -> target=%{public}d",
                f.source_fd, f.target_fd);
        }
    } else if (!cmsg_fds.empty()) {
        // 老协议但带了 fd, 一律 close
        OH_LOG_WARN(LOG_APP,
            "[ctrl] proto v1 but got %{public}zu cmsg fds, discarding",
            cmsg_fds.size());
        for (int f : cmsg_fds) close(f);
        cmsg_fds.clear();
    }
    // cmsg_fds 的所有权已经移交给 req.inherited_fds (或被 close 掉)
    cmsg_fds.clear();
    
    // 反查 peer 的 ProcessInfo, 继承 sink + 记录逻辑父
    if (peer_pid > 0) {
        auto parent = Manager::Instance().Lookup(peer_pid);
        pid_t walk = peer_pid;
        int hops = 0;
        while (!parent && walk > 1 && hops < 16) {
            pid_t pp = GetPPid(walk);
            if (pp <= 0 || pp == walk) break;
            walk = pp;
            parent = Manager::Instance().Lookup(walk);
            hops++;
        }
        if (parent) {
            req.shared_stream  = parent->shared_stream;
            req.shared_capture = parent->shared_capture;
            req.caller_pid     = peer_pid;
            OH_LOG_INFO(LOG_APP,
                "[ctrl] inherit from peer=%{public}d (via ancestor=%{public}d, hops=%{public}d) has_stream=%{public}d",
                (int)peer_pid, (int)walk, hops,
                req.shared_stream ? 1 : 0);
        } else {
            OH_LOG_WARN(LOG_APP,
                "[ctrl] peer pid=%{public}d and ancestors not in Manager, no sink",
                (int)peer_pid);
        }
    }

    SpawnResult r = Spawn(req);

    // ---- 不管 spawn 成功失败, procmgr 这一侧的 source_fd 都要关 ----
    // (成功: child 已经 dup2 + close 自己的拷贝; 父进程的拷贝必须关)
    // (失败: fork 没发生, source_fd 还在 procmgr 这边, 必须关)
    for (const auto& f : req.inherited_fds) {
        close(f.source_fd);
    }

    std::string& s = *resp;
    s  = "RESULT\nREQ_ID " + std::to_string(req_id) + "\n";
    if (r.pid > 0) {
        s += "STATUS ok\nPID " + std::to_string(r.pid) + "\n";
        s += std::string("KIND ") + KindCStr(r.kind) + "\n";
        if (sync_wait) {
            s += "EXIT_CODE " + std::to_string(r.exit_code) + "\n";
        }
    } else {
        s += "STATUS error\nMSG " + (r.error.empty() ? "unknown" : r.error) + "\n";
    }
    s += "END";
}

void HandleClient(int fd) {
    int n_after = g_ctrl.active.fetch_add(1) + 1;
    if (n_after > kMaxControlClients) {
        WriteFrame(fd, "RESULT\nSTATUS error\nMSG too_many_clients\nEND");
        close(fd);
        g_ctrl.active.fetch_sub(1);
        OH_LOG_WARN(LOG_APP,
            "ctrl: rejected client, active=%{public}d max=%{public}d",
            n_after, kMaxControlClients);
        return;
    }
    
    // 拿 peer PID. AF_UNIX 原生支持, 无需协议传递.
    struct ucred peer{};
    socklen_t plen = sizeof(peer);
    pid_t peer_pid = -1;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &plen) == 0) {
        peer_pid = peer.pid;
        OH_LOG_INFO(LOG_APP, "[ctrl] new client peer_pid=%{public}d",
                    (int)peer_pid);
    } else {
        OH_LOG_WARN(LOG_APP, "[ctrl] SO_PEERCRED failed: %{public}s",
                    strerror(errno));
    }
    
    while (g_ctrl.running.load()) {
        std::string frame;
        std::vector<int> cmsg_fds;
        // if (!ReadFrame(fd, &frame)) break;
        if (!ReadFrameWithFds(fd, &frame, &cmsg_fds)) break;

        // 拆行
        std::vector<std::string> lines;
        size_t start = 0;
        while (start <= frame.size()) {
            size_t nl = frame.find('\n', start);
            if (nl == std::string::npos) {
                if (start < frame.size()) lines.push_back(frame.substr(start));
                break;
            }
            lines.push_back(frame.substr(start, nl - start));
            start = nl + 1;
        }
        if (lines.empty()) {
            for (int f : cmsg_fds) close(f);
            continue;
        }

        std::string resp;
        auto cmd = SplitKV(lines[0]);
        if (cmd.first == "CMD" && cmd.second == "CREATE") {
            HandleCreate(lines, cmsg_fds, peer_pid, &resp);
            // HandleCreate 已接管 cmsg_fds, 这里不再处理
        } else {
            // 非 CREATE 命令不该带 fd, 一律 close
            for (int f : cmsg_fds) close(f);
            if (cmd.first == "CMD" && cmd.second == "PING") {
                resp = "PONG\nEND";
            } else if (cmd.first == "CMD" && cmd.second == "TERMINATE") {
                int pid = 0;
                for (const auto& ln : lines) {
                    auto kv = SplitKV(ln);
                    if (kv.first == "PID") pid = atoi(kv.second.c_str());
                }
                Terminate(pid);
                resp = "RESULT\nSTATUS ok\nEND";
            } else if (cmd.first == "CMD" && cmd.second == "LIST") {
                resp = "LIST\n";
                for (auto& info : ListProcesses()) {
                    resp += "INFO pid=" + std::to_string(info.pid)
                         +  " kind=" + KindCStr(info.kind)
                         +  " alive=" + (info.alive ? "1" : "0")
                         +  " code=" + std::to_string(info.exit_code)
                         +  "\n";
                }
                resp += "END";
            } else {
                resp = "RESULT\nSTATUS error\nMSG unknown_command\nEND";
            }
        }
        if (!WriteFrame(fd, resp)) break;
    }
    close(fd);
    g_ctrl.active.fetch_sub(1);
}

void AcceptLoop() {
    while (g_ctrl.running.load()) {
        int cli = accept(g_ctrl.listen_fd, nullptr, nullptr);
        if (cli < 0) {
            if (errno == EINTR) continue;
            if (!g_ctrl.running.load()) break;
            OH_LOG_WARN(LOG_APP, "accept failed: %{public}s", strerror(errno));
            continue;
        }
        std::thread(HandleClient, cli).detach();
    }
}

} // anonymous namespace

bool StartControlSocket(const std::string& sock_path) {
    if (g_ctrl.running.load()) return true;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "ctrl socket() failed: %{public}s", strerror(errno));
        return false;
    }
    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path.c_str(), sizeof(addr.sun_path) - 1);
    unlink(sock_path.c_str());

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        OH_LOG_ERROR(LOG_APP, "ctrl bind(%{public}s) failed: %{public}s",
                     sock_path.c_str(), strerror(errno));
        close(fd);
        return false;
    }
    chmod(sock_path.c_str(), 0600);  // 仅本应用 UID 可访问

    if (listen(fd, 8) < 0) {
        OH_LOG_ERROR(LOG_APP, "ctrl listen failed: %{public}s", strerror(errno));
        close(fd);
        unlink(sock_path.c_str());
        return false;
    }

    g_ctrl.listen_fd = fd;
    g_ctrl.sock_path = sock_path;
    g_ctrl.running.store(true);
    g_ctrl.accept_thread = std::thread(AcceptLoop);

    OH_LOG_INFO(LOG_APP, "control socket listening at %{public}s",
                sock_path.c_str());
    return true;
}

void StopControlSocket() {
    if (!g_ctrl.running.exchange(false)) return;
    if (g_ctrl.listen_fd >= 0) {
        shutdown(g_ctrl.listen_fd, SHUT_RDWR);
        close(g_ctrl.listen_fd);
        g_ctrl.listen_fd = -1;
    }
    if (!g_ctrl.sock_path.empty()) {
        unlink(g_ctrl.sock_path.c_str());
    }
    if (g_ctrl.accept_thread.joinable()) g_ctrl.accept_thread.join();
}

// ============================================================
//  NAPI 包装
// ============================================================
namespace {

struct RunEvent {
    std::string event;   // "out" | "exit"
    std::string data;
};

void RunCallbackTsfnCallJs(napi_env env, napi_value js_cb,
                           void*, void* data) {
    auto* ev = static_cast<RunEvent*>(data);
    if (ev) {
        if (env && js_cb) {
            napi_value undef, args[2];
            napi_get_undefined(env, &undef);
            napi_create_string_utf8(env, ev->event.c_str(),
                                    NAPI_AUTO_LENGTH, &args[0]);
            napi_create_string_utf8(env, ev->data.c_str(),
                                    NAPI_AUTO_LENGTH, &args[1]);
            napi_call_function(env, undef, js_cb, 2, args, nullptr);
        }
        delete ev;
    }
}

napi_threadsafe_function MaybeCreateRunTsfn(napi_env env,
                                            napi_value arg,
                                            const char* name) {
    if (!arg) return nullptr;
    napi_valuetype t = napi_undefined;
    napi_typeof(env, arg, &t);
    if (t != napi_function) return nullptr;
    napi_threadsafe_function tsfn = nullptr;
    napi_value res_name;
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &res_name);
    napi_create_threadsafe_function(env, arg, nullptr, res_name,
        0, 1, nullptr, nullptr, nullptr, RunCallbackTsfnCallJs, &tsfn);
    return tsfn;
}

void ConfigureStreamSink(StreamSink& sink,
                         napi_threadsafe_function tsfn,
                         const char* hilog_tag) {
    if (tsfn) {
        sink.on_line = [tsfn](pid_t, const std::string& line) {
            auto* ev = new RunEvent{"out", line};
            napi_call_threadsafe_function(tsfn, ev, napi_tsfn_blocking);
        };
        sink.on_exit = [tsfn](pid_t, int code) {
            auto* ev = new RunEvent{"exit", std::to_string(code)};
            napi_call_threadsafe_function(tsfn, ev, napi_tsfn_blocking);
            // 注意: 不再调 napi_release_threadsafe_function.
            // release 由 shared_ptr 自定义 deleter 在引用计数归零时做.
        };
    } else {
        std::string tag = hilog_tag;
        sink.on_line = [tag](pid_t pid, const std::string& line) {
            OH_LOG_INFO(LOG_APP, "[%{public}s:%{public}d] %{public}s",
                        tag.c_str(), (int)pid, line.c_str());
        };
    }
}

KindHint ParseKindHint(const std::string& s) {
    if (s == "native") return KindHint::kForceNative;
    if (s == "box64")  return KindHint::kForceBox64;
    return KindHint::kAuto;
}

std::shared_ptr<StreamSink> MakeSharedStreamSink(napi_threadsafe_function tsfn,
                                                 const char* hilog_tag) {
    auto* raw = new StreamSink();
    ConfigureStreamSink(*raw, tsfn, hilog_tag);
    return std::shared_ptr<StreamSink>(raw, [tsfn](StreamSink* p) {
        // 整条逻辑链上所有进程都退出后才到这里. 一次性释放 tsfn.
        if (tsfn) napi_release_threadsafe_function(tsfn, napi_tsfn_release);
        delete p;
    });
}

} // anonymous namespace

napi_value RunCommandNapi(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    SpawnRequest req;
    req.exe_path  = napiutil::GetStringArg(env, args[0]);
    req.argv      = napiutil::GetStringArrayArg(env, args[1]);
    req.env       = napiutil::GetStringArrayArg(env, args[2]);
    req.cwd       = (argc >= 4) ? napiutil::GetStringArg(env, args[3]) : "";

    napi_threadsafe_function tsfn = (argc >= 5)
        ? MaybeCreateRunTsfn(env, args[4], "RunCmdCb")
        : nullptr;

    if (argc >= 6) {
        req.kind_hint = ParseKindHint(napiutil::GetStringArg(env, args[5]));
    }

    // 用 shared_ptr 取代栈上 StreamSink
    LaunchKind kind = ResolveKind(req);
    req.shared_stream = MakeSharedStreamSink(tsfn,
        kind == LaunchKind::kBox64 ? "box64" : "cmd");

    SpawnResult r = Spawn(req);
    if (r.pid <= 0 && tsfn) {
        // Spawn 失败: shared_stream RAII 析构会触发 deleter 自动 release tsfn.
        // 不需要手动 release.
        // napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    }

    napi_value out;
    napi_create_int32(env, r.pid, &out);
    return out;
}

napi_value TerminateNapi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t pid = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &pid);
    Terminate((pid_t)pid);
    return nullptr;
}

napi_value ListProcessesNapi(napi_env env, napi_callback_info info) {
    auto list = ListProcesses();
    napi_value arr;
    napi_create_array_with_length(env, list.size(), &arr);
    for (size_t i = 0; i < list.size(); ++i) {
        const auto& p = list[i];
        napi_value obj;
        napi_create_object(env, &obj);

        napi_value v;
        napi_create_int32(env, p.pid, &v);
        napi_set_named_property(env, obj, "pid", v);
        napi_create_int32(env, p.parent_pid, &v);
        napi_set_named_property(env, obj, "parentPid", v);
        napi_create_string_utf8(env, KindCStr(p.kind),
                                NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, obj, "kind", v);
        napi_create_string_utf8(env, p.exe_path.c_str(),
                                NAPI_AUTO_LENGTH, &v);
        napi_set_named_property(env, obj, "exePath", v);
        napi_create_int64(env, p.start_time_ms, &v);
        napi_set_named_property(env, obj, "startTimeMs", v);
        napi_create_int32(env, p.exit_code, &v);
        napi_set_named_property(env, obj, "exitCode", v);
        napi_get_boolean(env, p.alive, &v);
        napi_set_named_property(env, obj, "alive", v);

        napi_set_element(env, arr, i, obj);
    }
    return arr;
}

// ============================================================
//  Control Socket NAPI
// ============================================================

napi_value StartControlSocketNapi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path = (argc >= 1)
        ? napiutil::GetStringArg(env, args[0])
        : "";
    if (path.empty()) {
        OH_LOG_ERROR(LOG_APP, "startProcMgr: sockPath is empty");
        napi_value r;
        napi_get_boolean(env, false, &r);
        return r;
    }

    bool ok = StartControlSocket(path);
    napi_value r;
    napi_get_boolean(env, ok, &r);
    return r;
}

napi_value StopControlSocketNapi(napi_env env, napi_callback_info /*info*/) {
    StopControlSocket();
    return nullptr;
}

// ============================================================
//  兼容旧接口: runBox64
//  -----------------------------------------------------------
//  与旧版 proc::RunBox64Napi 等价的对外签名,内部强制走 kBox64 分支。
//  与新版 runCommand 的差异:
//    - 不接受 kindHint 参数 (固定 box64)
//    - argv 兜底逻辑沿用旧版: 空时填 ["box64", elfPath]
//  迁移完成后请废弃此接口。
// ============================================================

napi_value RunBox64NapiCompat(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    SpawnRequest req;
    req.exe_path  = napiutil::GetStringArg(env, args[0]);
    req.argv      = napiutil::GetStringArrayArg(env, args[1]);
    req.env       = napiutil::GetStringArrayArg(env, args[2]);
    req.cwd       = (argc >= 4) ? napiutil::GetStringArg(env, args[3]) : "";
    req.kind_hint = KindHint::kForceBox64;

    // 旧约定: argv 为空时补全 ["box64", elfPath]
    if (req.argv.empty()) {
        req.argv.push_back("box64");
        if (!req.exe_path.empty()) req.argv.push_back(req.exe_path);
    }

    // 参数 5 类型决定模式:
    //   napi_function          -> 创建 tsfn + stream sink, pipe 转发到 ArkTS
    //   null / undefined / 其他 -> 静默模式, 不创建 pipe,
    //                              子进程 stdout/stderr -> /dev/null
    //                              子进程退出仍由 WaiterOnlyMain reap,
    //                              但不向 ArkTS 发 'exit' 事件
    napi_threadsafe_function tsfn = nullptr;
    if (argc >= 5) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, args[4], &t);
        if (t == napi_function) {
            tsfn = MaybeCreateRunTsfn(env, args[4], "RunBox64CbCompat");
        }
    }
    if (tsfn) {
        req.shared_stream = MakeSharedStreamSink(tsfn, "box64");
    }

    SpawnResult r = Spawn(req);
    if (r.pid <= 0 && tsfn) {
        // Spawn 失败: shared_stream RAII 析构会触发 deleter 自动 release tsfn.
        // 不需要手动 release.
        // napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    }

    napi_value out;
    napi_create_int32(env, r.pid, &out);
    return out;
}

} // namespace procmgr