#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"
#include "../shell_process.h"

namespace shell {

int CmdWine(ShellEngine& e, const std::vector<std::string>& args) {
    std::string wine_bin = e.Env().Get("HBOX_WINE_BIN");
    if (wine_bin.empty()) {
        e.WriteErr("wine: HBOX_WINE_BIN not set (check ArkTS injects wine env)");
        return 1;
    }
    std::vector<std::string> box64_args;
    box64_args.push_back(wine_bin);
    for (const auto& a : args) box64_args.push_back(a);
    return SpawnBox64FromShell(e, box64_args, "wine");
}

} // namespace shell