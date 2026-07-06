#include "builtins.h"
#include "../shell_engine.h"
#include "../../process_manager.h"

#include <cstdio>
#include <ctime>
#include <signal.h>

namespace shell {

int CmdPs(ShellEngine& e, const std::vector<std::string>& args) {
    bool show_dead = false;
    for (const auto& a : args) {
        if (a == "-a" || a == "--all") show_dead = true;
    }

    auto list = procmgr::ListProcesses();
    if (list.empty()) {
        e.Writeln("\x1b[90m(no processes in registry)\x1b[0m");
        return 0;
    }

    e.Writeln("\x1b[1;33m  PID    PPID  KIND    STATE     AGE   EXE\x1b[0m");
    int64_t now_ms = (int64_t)time(nullptr) * 1000;

    for (auto& p : list) {
        if (!show_dead && !p.alive) continue;
        int age_s = (int)((now_ms - p.start_time_ms) / 1000);
        const char* kind = (p.kind == procmgr::LaunchKind::kBox64)
                           ? "box64 " : "native";
        const char* state;
        if (p.alive) {
            // 进一步用 kill(0) 验一下 (registry 可能滞后)
            state = (kill(p.pid, 0) == 0) ? "\x1b[32mrunning\x1b[0m"
                                          : "\x1b[33mgone   \x1b[0m";
        } else {
            state = "\x1b[90mexited \x1b[0m";
        }
        char buf[512];
        snprintf(buf, sizeof(buf), "  %-6d %-5d %s  %s  %4ds  %s",
                 p.pid, p.parent_pid, kind, state, age_s, p.exe_path.c_str());
        e.Writeln(buf);
    }
    return 0;
}

} // namespace shell