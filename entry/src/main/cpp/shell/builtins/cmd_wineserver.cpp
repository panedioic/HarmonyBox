#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"
#include "../shell_process.h"

namespace shell {

int CmdWineserver(ShellEngine& e, const std::vector<std::string>& args) {
    std::string ws_bin = e.Env().Get("HBOX_WINESERVER_BIN");
    if (ws_bin.empty()) {
        e.WriteErr("wineserver: HBOX_WINESERVER_BIN not set");
        return 1;
    }
    std::vector<std::string> box64_args;
    box64_args.push_back(ws_bin);
    for (const auto& a : args) box64_args.push_back(a);
    return SpawnBox64FromShell(e, box64_args, "wineserver");
}

} // namespace shell