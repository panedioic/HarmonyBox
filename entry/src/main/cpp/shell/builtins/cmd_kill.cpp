#include "builtins.h"
#include "../shell_engine.h"
#include "../../process_manager.h"

#include <cstdlib>
#include <signal.h>

namespace shell {

int CmdKill(ShellEngine& e, const std::vector<std::string>& args) {
    if (args.empty()) {
        e.WriteErr("kill: missing pid");
        return 2;
    }
    int rc = 0;
    for (const auto& a : args) {
        pid_t pid = (pid_t)atoi(a.c_str());
        if (pid <= 0) {
            e.WriteErr("kill: invalid pid: " + a);
            rc = 1;
            continue;
        }
        if (kill(pid, 0) != 0) {
            e.WriteErr("kill: no such process: " + a);
            rc = 1;
            continue;
        }
        procmgr::Terminate(pid);
        e.Writeln("\x1b[90msent SIGTERM to " + a + "\x1b[0m");
    }
    return rc;
}

} // namespace shell