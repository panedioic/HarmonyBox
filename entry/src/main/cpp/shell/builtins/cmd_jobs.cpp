#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_jobs.h"
#include "../../process_manager.h"

#include <ctime>
#include <cstdio>
#include <signal.h>
#include <unordered_map>

namespace shell {

int CmdJobs(ShellEngine& e, const std::vector<std::string>& /*args*/) {
    auto jobs = e.Jobs().All();
    if (jobs.empty()) {
        e.Writeln("\x1b[90m(no background jobs in this session)\x1b[0m");
        return 0;
    }
    // procmgr 视角的 alive 状态
    std::unordered_map<pid_t, bool> alive;
    for (auto& p : procmgr::ListProcesses()) alive[p.pid] = p.alive;

    e.Writeln("\x1b[1;33m  PID   STATE    LABEL         LOG\x1b[0m");
    for (auto& j : jobs) {
        bool a = false;
        auto it = alive.find(j.pid);
        if (it != alive.end()) a = it->second;
        else                   a = (kill(j.pid, 0) == 0);  // 兜底

        std::string state = a ? "\x1b[32mrunning\x1b[0m" : "\x1b[90m exited\x1b[0m";
        char buf[512];
        snprintf(buf, sizeof(buf), "  %-5d %s  %-12s  %s",
                 j.pid, state.c_str(), j.label.c_str(), j.log_path.c_str());
        e.Writeln(buf);
    }
    return 0;
}

} // namespace shell