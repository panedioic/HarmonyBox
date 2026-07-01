#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"

namespace shell {

int CmdEnv(ShellEngine& e, const std::vector<std::string>& args) {
    std::string prefix;
    if (!args.empty()) prefix = args[0];

    auto entries = e.Env().All();
    for (const auto& entry : entries) {
        if (!prefix.empty()) {
            if (entry.key.size() < prefix.size()) continue;
            if (entry.key.compare(0, prefix.size(), prefix) != 0) continue;
        }
        std::string tags;
        if (entry.readonly)   tags += " \x1b[90m(ro)\x1b[0m";
        if (entry.persistent) tags += " \x1b[33m(saved)\x1b[0m";

        e.Writeln("\x1b[36m" + entry.key + "\x1b[0m=" + entry.val + tags);
    }
    return 0;
}

} // namespace shell