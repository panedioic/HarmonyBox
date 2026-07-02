#include "shell_process.h"
#include "shell_engine.h"
#include "shell_env.h"
#include "../process_manager.h"

#include <memory>

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

} // namespace shell