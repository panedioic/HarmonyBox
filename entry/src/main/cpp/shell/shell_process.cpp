#include <ctime>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cstring>
#include <errno.h>
#include <memory>

#include "shell_process.h"
#include "shell_engine.h"
#include "shell_env.h"
#include "../process_manager.h"


namespace shell {

int SpawnBox64FromShell(ShellEngine& e,
                        const std::vector<std::string>& box64_args,
                        const std::string& label) {
    if (e.IsBusy()) {
        e.WriteErr("shell: already running a foreground process (pid=" +
                   std::to_string(e.BusyPid()) + ")");
        return 1;
    }

    procmgr::SpawnRequest req;
    req.exe_path = "box64";
    req.argv.push_back("box64");
    for (const auto& a : box64_args) req.argv.push_back(a);
    req.env = e.Env().BuildEnvArray();
    req.cwd = e.Cwd();
    req.kind_hint = procmgr::KindHint::kForceBox64;
    req.proc_name = label.empty() ? "hbsh-box64" : label;

    // stream sink: reader 线程 -> shell async channel
    auto sink = std::make_shared<procmgr::StreamSink>();
    ShellEngine* eng = &e;
    sink->on_line = [eng](pid_t, const std::string& line) {
        eng->PostAsyncOutput(line + "\r\n");
    };
    sink->on_exit = [eng](pid_t, int code) {
        eng->PostAsyncExit(code);
    };
    req.shared_stream = sink;

    procmgr::SpawnResult r = procmgr::Spawn(req);
    if (r.pid <= 0) {
        e.WriteErr("spawn failed: " + (r.error.empty() ? "unknown" : r.error));
        return 1;
    }

    e.BeginBusy(r.pid, label);
    // 首行提示, 让用户知道跑起来了
    e.Writeln("\x1b[90m[" + label + " pid=" + std::to_string(r.pid) +
              ", Ctrl+C to stop]\x1b[0m");
    return 0;
}

pid_t SpawnBox64Background(ShellEngine& e,
                           const std::vector<std::string>& box64_args,
                           const std::string& label,
                           const std::string& log_path) {
    // 打开 log 文件
    int fd = open(log_path.c_str(),
                  O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
                  0600);
    if (fd < 0) {
        e.WriteErr(std::string("bg: open log failed: ") + strerror(errno));
        return -1;
    }

    // 写个 header
    time_t t = time(nullptr);
    char hdr[128];
    snprintf(hdr, sizeof(hdr),
             "=== bg %s started at %ld ===\n", label.c_str(), (long)t);
    (void)write(fd, hdr, strlen(hdr));

    procmgr::SpawnRequest req;
    req.exe_path = "box64";
    req.argv.push_back("box64");
    for (const auto& a : box64_args) req.argv.push_back(a);
    req.env = e.Env().BuildEnvArray();
    req.cwd = e.Cwd();
    req.kind_hint = procmgr::KindHint::kForceBox64;
    req.proc_name = "hbsh-bg-" + label;

    auto sink = std::make_shared<procmgr::StreamSink>();
    ShellEngine* eng = &e;
    // 注意: 只 capture fd, 不 capture engine 到 on_line
    sink->on_line = [fd](pid_t, const std::string& line) {
        std::string l = line + "\n";
        (void)write(fd, l.data(), l.size());
    };
    // exit 时通知 shell 更新 job 状态
    sink->on_exit = [eng](pid_t pid, int code) {
        eng->PostBgExit(pid, code);
    };
    req.shared_stream = sink;

    procmgr::SpawnResult r = procmgr::Spawn(req);
    if (r.pid <= 0) {
        close(fd);
        e.WriteErr("bg: spawn failed: " + (r.error.empty() ? "unknown" : r.error));
        return -1;
    }

    ShellJob job;
    job.pid = r.pid;
    job.label = label;
    job.log_path = log_path;
    job.log_fd = fd;
    job.start_ms = (int64_t)t * 1000;
    e.Jobs().Add(job);

    return r.pid;
}

} // namespace shell