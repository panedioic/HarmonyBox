#include "builtins.h"
#include "../shell_engine.h"

namespace shell {

int CmdPwd(ShellEngine& e, const std::vector<std::string>& /*args*/) {
    e.Writeln(e.Cwd());
    return 0;
}

} // namespace shell