#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_process.h"

namespace shell {

int CmdBox64(ShellEngine& e, const std::vector<std::string>& args) {
    if (args.empty()) {
        e.WriteErr("box64: missing argument");
        return 2;
    }
    return SpawnBox64FromShell(e, args, "box64");
}

} // namespace shell