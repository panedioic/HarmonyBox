#include "process_runner.h"
#include "fs_utils.h"

#include <dlfcn.h>
#include <unistd.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <dirent.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <thread>

#undef LOG_TAG
#define LOG_TAG "WL_HBox"
#include <hilog/log.h>

extern "C" char** environ;

namespace {

// ============ 通用 helpers ============

void close_inherited_fds_except(int k1, int k2) {
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

void StreamReaderMain(int fd, pid_t pid, proc::StreamSink sink) {
    char buf[2048];
    std::string pending;
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = 0;
            pending.append(buf, n);
            size_t pos;
            while ((pos = pending.find('\n')) != std::string::npos) {
                if (sink.onLine) sink.onLine(pid, pending.substr(0, pos));
                pending.erase(0, pos + 1);
            }
        } else if (n == 0) {
            break;
        } else {
            if (errno == EINTR) continue;
            break;
        }
    }
    if (!pending.empty() && sink.onLine) sink.onLine(pid, pending);
    close(fd);

    // 注: SIGCHLD=SIG_IGN 下 waitpid 拿不到真实退出码,行为与原版一致
    int status = 0;
    waitpid(pid, &status, 0);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (sink.onExit) sink.onExit(pid, code);
}

void CaptureReaderMain(int fd, pid_t pid, proc::CaptureSink sink) {
    std::string out;
    char buf[1024];
    while (true) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            out.append(buf, n);
            if (out.size() > sink.maxBytes) break;
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
    if (sink.onDone) sink.onDone(code, std::move(out));
}

// 通用前置: pipe + fork + dup2 + closefds + signals + chdir
// 父侧返回 child pid; child 内返回 0; 失败返回 -1。
// needPipe=true 时,父侧成功会把读端写到 *outReadFd。
pid_t fork_with_io(bool needPipe, const std::string& cwd, const char* procName,
                   int* outReadFd) {
    int pipefd[2] = {-1, -1};
    if (needPipe) {
        if (pipe(pipefd) != 0) {
            OH_LOG_ERROR(LOG_APP, "pipe failed: %{public}s", strerror(errno));
            return -1;
        }
        fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    }

    signal(SIGCHLD, SIG_IGN); // 已知 bug,后续单独修

    pid_t pid = fork();
    if (pid < 0) {
        if (needPipe) { close(pipefd[0]); close(pipefd[1]); }
        OH_LOG_ERROR(LOG_APP, "fork failed: %{public}s", strerror(errno));
        return -1;
    }

    if (pid == 0) {
        // ---- child ----
        if (needPipe) {
            close(pipefd[0]);
            dup2(pipefd[1], STDOUT_FILENO);
            dup2(pipefd[1], STDERR_FILENO);
            if (pipefd[1] > 2) close(pipefd[1]);
        } else {
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, STDOUT_FILENO);
                dup2(devnull, STDERR_FILENO);
                if (devnull > 2) close(devnull);
            }
        }

        if (procName) prctl(PR_SET_NAME, procName, 0, 0, 0);
        close_inherited_fds_except(STDOUT_FILENO, STDERR_FILENO);
        for (int s = 1; s < 32; ++s) signal(s, SIG_DFL);

        if (!cwd.empty() && chdir(cwd.c_str()) != 0) {
            fprintf(stderr, "chdir(%s) failed: %s\n",
                    cwd.c_str(), strerror(errno));
        }
        return 0;
    }

    // ---- parent ----
    if (needPipe) {
        close(pipefd[1]);
        if (outReadFd) *outReadFd = pipefd[0];
    }
    return pid;
}

void start_reader(int fd, pid_t pid,
                  proc::StreamSink* stream, proc::CaptureSink* capture) {
    if (stream) {
        std::thread(StreamReaderMain, fd, pid, *stream).detach();
    } else if (capture) {
        std::thread(CaptureReaderMain, fd, pid, *capture).detach();
    } else {
        close(fd);
    }
}

// ============ child-only: box64 装载 ============

// 解除继承自父进程的低 4GB anon / ark VM 映射,给 ET_EXEC 让出 link base 0x400000。
void unmap_low_anon_regions() {
    FILE* f = fopen("/proc/self/maps", "r");
    if (!f) {
        fprintf(stderr, "[unmap] open /proc/self/maps failed\n");
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

        bool is_ark = strstr(tag, "[anon:ark") != nullptr;
        bool is_pure_anon = (n < 4) || (tag[0] == 0);
        if (is_ark || is_pure_anon) {
            targets.push_back({start, end});
        }
    }
    fclose(f);

    int ok = 0, fail = 0;
    unsigned long total_bytes = 0;
    for (const auto& r : targets) {
        size_t len = r.end - r.start;
        if (munmap((void*)r.start, len) == 0) {
            ok++;
            total_bytes += len;
        } else {
            fail++;
        }
    }
    fprintf(stderr,
        "[unmap] freed %d regions, total=%lu MB, failures=%d\n",
        ok, total_bytes / 1024 / 1024, fail);
    fflush(stderr);
}

typedef int (*box64_run_fn)(int argc, const char** argv, const char** env);

// 子进程内加载 libbox64.so 并解析 box64_run。
// 候选路径: 短名(LD_LIBRARY_PATH 默认搜索) → LD_LIBRARY_PATH 各段 → 写死兜底。
box64_run_fn load_box64_run_in_child(void** out_handle) {
    std::vector<std::string> candidates;
    candidates.emplace_back("libbox64.so");

    if (const char* ld = getenv("LD_LIBRARY_PATH")) {
        std::string s = ld;
        size_t start = 0;
        while (start <= s.size()) {
            size_t end = s.find(':', start);
            if (end == std::string::npos) end = s.size();
            std::string dir = s.substr(start, end - start);
            if (!dir.empty()) {
                candidates.push_back(dir + "/libbox64.so");
            }
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
            fprintf(stderr, "[child] dlopen ok: %s\n", path.c_str());
            break;
        }
        fprintf(stderr, "[child] dlopen %s -> %s\n",
                path.c_str(), dlerror());
    }
    if (!h) {
        fprintf(stderr, "[child] FATAL: cannot dlopen libbox64.so\n");
        return nullptr;
    }

    auto fn = (box64_run_fn)dlsym(h, "box64_run");
    if (!fn) {
        fprintf(stderr, "[child] FATAL: dlsym(box64_run) failed: %s\n",
                dlerror());
        dlclose(h);
        return nullptr;
    }
    fprintf(stderr, "[child] box64_run = %p\n", (void*)fn);
    fflush(stderr);
    *out_handle = h;
    return fn;
}

// 把 KEY=VALUE 数组写进 environ,box64_run 通过 environ 读取。
void apply_env_to_environ(const std::vector<std::string>& env) {
    for (const auto& kv : env) {
        if (kv.empty()) continue;
        auto eq = kv.find('=');
        if (eq == std::string::npos) continue;
        std::string k = kv.substr(0, eq);
        std::string v = kv.substr(eq + 1);
        setenv(k.c_str(), v.c_str(), 1);
    }
}

// ============ 两种 spawn 实现 ============

int Spawn(const std::string& exe,
          const std::vector<std::string>& argv,
          const std::vector<std::string>& env,
          const std::string& cwd,
          const char* procName,
          proc::StreamSink* stream,
          proc::CaptureSink* capture) {
    if (stream && capture) {
        OH_LOG_ERROR(LOG_APP, "Spawn: stream and capture both set");
        return -1;
    }

    bool needPipe = (stream != nullptr) || (capture != nullptr);
    int readFd = -1;
    pid_t pid = fork_with_io(needPipe, cwd, procName, &readFd);
    if (pid < 0) return -1;

    if (pid == 0) {
        // ---- child: build envp, argv, execve ----
        std::vector<char*> envp;
        envp.reserve(env.size() + 1);
        for (auto& s : const_cast<std::vector<std::string>&>(env)) {
            envp.push_back(const_cast<char*>(s.c_str()));
        }
        envp.push_back(nullptr);

        std::vector<char*> cargv;
        cargv.reserve(argv.size() + 1);
        for (auto& s : const_cast<std::vector<std::string>&>(argv)) {
            cargv.push_back(const_cast<char*>(s.c_str()));
        }
        cargv.push_back(nullptr);

        execve(exe.c_str(), cargv.data(), envp.data());
        fprintf(stderr, "execve(%s) failed: %s\n",
                exe.c_str(), strerror(errno));
        _exit(127);
    }

    if (needPipe) start_reader(readFd, pid, stream, capture);
    return (int)pid;
}

int SpawnBox64(const std::string& elfPath,
               const std::vector<std::string>& guestArgs,
               const std::vector<std::string>& env,
               const std::string& cwd,
               proc::StreamSink* stream,
               proc::CaptureSink* capture) {
    if (stream && capture) {
        OH_LOG_ERROR(LOG_APP, "SpawnBox64: stream and capture both set");
        return -1;
    }

    bool needPipe = (stream != nullptr) || (capture != nullptr);
    int readFd = -1;
    pid_t pid = fork_with_io(needPipe, cwd, "wl-client", &readFd);
    if (pid < 0) return -1;

    if (pid == 0) {
        // ---- child ----
        apply_env_to_environ(env);

        // 释放低 4GB anon 映射,给 ET_EXEC 让出 link base
        unmap_low_anon_regions();

        // 构造 argv: [ "box64", elfPath, guestArgs... ]
        const int total_argc = 2 + (int)guestArgs.size();
        std::vector<const char*> srcs;
        srcs.reserve(total_argc);
        srcs.push_back("box64");
        srcs.push_back(elfPath.c_str());
        for (const auto& s : guestArgs) srcs.push_back(s.c_str());

        // 把所有字符串拷到一块连续 buffer,确保生命周期覆盖整个 box64_run
        std::vector<char> blob;
        std::vector<size_t> offs(total_argc);
        for (int i = 0; i < total_argc; i++) {
            offs[i] = blob.size();
            size_t n = strlen(srcs[i]);
            blob.insert(blob.end(), srcs[i], srcs[i] + n);
            blob.push_back('\0');
        }
        blob.resize(blob.size() + 64, 0);
        std::vector<const char*> argv2(total_argc + 1, nullptr);
        for (int i = 0; i < total_argc; i++) {
            argv2[i] = blob.data() + offs[i];
        }

        fprintf(stderr, "[child] box64 argv (argc=%d):\n", total_argc);
        for (int i = 0; i < total_argc; i++) {
            fprintf(stderr, "  argv[%d] = %s\n", i, argv2[i]);
        }
        fflush(stderr);

        // ★ 父进程绝不能 dlopen libbox64.so, 必须在子进程内加载
        void* handle = nullptr;
        box64_run_fn fn = load_box64_run_in_child(&handle);
        if (!fn) {
            fprintf(stderr, "[child] cannot resolve box64_run, exit 125\n");
            fflush(stderr);
            _exit(125);
        }

        int rc = fn(total_argc, argv2.data(), (const char**)environ);
        fprintf(stderr,
            "[child] box64_run returned %d (0x%x), exit with %d\n",
            rc, rc, rc & 0xFF);
        fflush(stderr);
        _exit(rc & 0xFF);
    }

    if (needPipe) start_reader(readFd, pid, stream, capture);
    return (int)pid;
}

} // anonymous namespace

namespace proc {

int RunBox64(const std::string& elfPath,
             const std::vector<std::string>& guestArgs,
             const std::vector<std::string>& env,
             const std::string& cwd,
             StreamSink* stream,
             CaptureSink* capture) {
    fsutil::EnsureExecutable(elfPath.c_str());
    int pid = SpawnBox64(elfPath, guestArgs, env, cwd, stream, capture);
    if (pid > 0) {
        OH_LOG_INFO(LOG_APP,
            "box64 pid=%{public}d elf=%{public}s argc=%{public}u",
            pid, elfPath.c_str(), (uint32_t)guestArgs.size());
    }
    return pid;
}

int RunCommand(const std::string& exe,
               const std::vector<std::string>& argv,
               const std::vector<std::string>& env,
               const std::string& cwd,
               StreamSink* stream,
               CaptureSink* capture) {
    fsutil::EnsureExecutable(exe.c_str());
    if (argv.size() >= 2 && !argv[1].empty() && argv[1][0] == '/') {
        fsutil::EnsureExecutable(argv[1].c_str());
    }
    int pid = Spawn(exe, argv, env, cwd, "cli-app", stream, capture);
    if (pid > 0) {
        OH_LOG_INFO(LOG_APP,
            "cmd pid=%{public}d exe=%{public}s argc=%{public}u",
            pid, exe.c_str(), (uint32_t)argv.size());
    }
    return pid;
}

void TerminateProcess(pid_t pid) {
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

} // namespace proc