#include "process_runner.h"
#include "fs_utils.h"

#include <unistd.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <thread>

#undef LOG_TAG
#define LOG_TAG "WL_HBox"
#include <hilog/log.h>

namespace {

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

    // 注:SIGCHLD=SIG_IGN 下 waitpid 会失败,code 实际拿不到真实退出值。
    // 行为与原 CliReaderMain 一致,先保留。
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
    int pipefd[2] = {-1, -1};

    if (needPipe) {
        if (pipe(pipefd) != 0) {
            OH_LOG_ERROR(LOG_APP, "pipe failed: %{public}s", strerror(errno));
            return -1;
        }
        fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    }

    signal(SIGCHLD, SIG_IGN); // 行为保留(已知 bug,后续单独修)

    pid_t pid = fork();
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

        if (!cwd.empty()) {
            if (chdir(cwd.c_str()) != 0) {
                fprintf(stderr, "chdir(%s) failed: %s\n", cwd.c_str(), strerror(errno));
            }
        }

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
        fprintf(stderr, "execve(%s) failed: %s\n", exe.c_str(), strerror(errno));
        _exit(127);
    }

    // ---- parent ----
    if (pid < 0) {
        if (needPipe) {
            close(pipefd[0]);
            close(pipefd[1]);
        }
        OH_LOG_ERROR(LOG_APP, "fork failed: %{public}s", strerror(errno));
        return -1;
    }

    if (needPipe) {
        close(pipefd[1]);
        if (stream) {
            std::thread(StreamReaderMain, pipefd[0], pid, *stream).detach();
        } else if (capture) {
            std::thread(CaptureReaderMain, pipefd[0], pid, *capture).detach();
        }
    }

    return (int)pid;
}

} // anonymous namespace

namespace proc {

int RunBox64(const std::string& exe,
             const std::vector<std::string>& argv,
             const std::vector<std::string>& env,
             const std::string& cwd,
             StreamSink* stream,
             CaptureSink* capture) {
    fsutil::EnsureExecutable(exe.c_str());
    if (argv.size() >= 2 && !argv[1].empty() && argv[1][0] == '/') {
        fsutil::EnsureExecutable(argv[1].c_str());
    }
    int pid = Spawn(exe, argv, env, cwd, "wl-client", stream, capture);
    if (pid > 0) {
        OH_LOG_INFO(LOG_APP, "box64 pid=%{public}d exe=%{public}s argc=%{public}u",
                    pid, exe.c_str(), (uint32_t)argv.size());
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
        OH_LOG_INFO(LOG_APP, "cmd pid=%{public}d exe=%{public}s argc=%{public}u",
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
            OH_LOG_WARN(LOG_APP, "pid=%{public}d not exited in 800ms, SIGKILL", pid);
        }
    }).detach();
}

} // namespace proc