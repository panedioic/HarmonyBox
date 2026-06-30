#include "builtins.h"
#include "../shell_engine.h"

namespace shell {

int CmdClear(ShellEngine& e, const std::vector<std::string>& /*args*/) {
    e.Write("\x1b[2J\x1b[H");
    return 0;
}

} // namespace shell