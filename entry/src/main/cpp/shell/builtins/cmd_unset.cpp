#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"

namespace shell {

int CmdUnset(ShellEngine& e, const std::vector<std::string>& args) {
    if (args.empty()) {
        e.WriteErr("unset: missing KEY");
        return 2;
    }
    bool persistent = false;
    size_t i = 0;
    if (args[0] == "--save" || args[0] == "-p") {
        persistent = true;
        i = 1;
    }
    if (i >= args.size()) {
        e.WriteErr("unset: missing KEY");
        return 2;
    }
    int rc = 0;
    for (; i < args.size(); ++i) {
        int r = e.Env().Unset(args[i], persistent);
        if (r == 1) {
            e.WriteErr("unset: readonly: " + args[i]);
            rc = 1;
        } else if (r == 2) {
            e.WriteErr("unset: persist save failed for " + args[i]);
            rc = 1;
        }
    }
    return rc;
}

} // namespace shell