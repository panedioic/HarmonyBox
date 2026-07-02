#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"
#include "../../process_manager.h"

#include <cstdio>

namespace shell {

int CmdStatus(ShellEngine& e, const std::vector<std::string>& /*args*/) {
    // shell state
    e.Writeln("\x1b[1;33mshell\x1b[0m");
    e.Writeln("  busy    : " + std::string(e.IsBusy() ? "yes" : "no"));
    if (e.IsBusy()) {
        e.Writeln("  fg pid  : " + std::to_string(e.BusyPid()));
    }
    e.Writeln("  cwd     : " + e.Cwd());

    // env quick view
    e.Writeln("");
    e.Writeln("\x1b[1;33mwine\x1b[0m");
    const char* keys[] = {
        "HBOX_WINE_BIN", "HBOX_WINESERVER_BIN", "HBOX_WINE_ROOT",
        "WINEPREFIX", "BOX64_LD_LIBRARY_PATH",
    };
    for (const char* k : keys) {
        std::string v = e.Env().Get(k);
        if (v.empty()) v = "\x1b[90m(unset)\x1b[0m";
        e.Writeln(std::string("  ") + k + " = " + v);
    }

    // procmgr sock
    e.Writeln("");
    e.Writeln("\x1b[1;33mprocmgr\x1b[0m");
    std::string sock = e.Env().Get("HBOX_PROCMGR_SOCK");
    if (sock.empty()) e.Writeln("  sock path: (env HBOX_PROCMGR_SOCK unset)");
    else               e.Writeln("  sock path: " + sock);

    // running procs
    auto procs = procmgr::ListProcesses();
    int alive = 0;
    for (auto& p : procs) if (p.alive) alive++;
    e.Writeln("");
    e.Writeln("\x1b[1;33mprocesses\x1b[0m (" + std::to_string(alive) + " alive)");
    for (auto& p : procs) {
        if (!p.alive) continue;
        char buf[512];
        snprintf(buf, sizeof(buf),
                 "  pid=%-6d kind=%-6s %s",
                 p.pid,
                 (int)p.kind == 1 ? "box64" : "native",  // 保守起见按 int 打
                 p.exe_path.c_str());
        e.Writeln(buf);
    }
    return 0;
}

} // namespace shell