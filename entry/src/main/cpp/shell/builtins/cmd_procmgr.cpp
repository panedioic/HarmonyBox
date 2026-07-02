#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"
#include "../../process_manager.h"

namespace shell {

int CmdProcMgrStart(ShellEngine& e, const std::vector<std::string>& args) {
    std::string sock;
    if (!args.empty()) {
        sock = args[0];
    } else {
        sock = e.Env().Get("HBOX_PROCMGR_SOCK");
    }
    if (sock.empty()) {
        e.WriteErr("procmgr.start: no sock path (set HBOX_PROCMGR_SOCK or pass arg)");
        return 1;
    }
    if (procmgr::StartControlSocket(sock)) {
        e.Writeln("procmgr: listening at \x1b[36m" + sock + "\x1b[0m");
        return 0;
    }
    e.WriteErr("procmgr.start: failed (see hilog)");
    return 1;
}

int CmdProcMgrStop(ShellEngine& e, const std::vector<std::string>& /*args*/) {
    procmgr::StopControlSocket();
    e.Writeln("procmgr: stopped");
    return 0;
}

} // namespace shell