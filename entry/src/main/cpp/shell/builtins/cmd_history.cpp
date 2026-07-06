#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_readline.h"

namespace shell {

// 由于 ShellEngine 持有 readline_, 加个访问器给我们用
// 见下面 shell_engine.h 修改

int CmdHistory(ShellEngine& e, const std::vector<std::string>& args) {
    if (!args.empty() && (args[0] == "-c" || args[0] == "--clear")) {
        e.ClearHistory();
        e.Writeln("history cleared");
        return 0;
    }
    const auto& h = e.HistoryRef();
    int n = (int)h.size();
    int show = n;
    if (!args.empty()) {
        show = atoi(args[0].c_str());
        if (show <= 0) show = n;
    }
    int start = std::max(0, n - show);
    for (int i = start; i < n; ++i) {
        char buf[16];
        snprintf(buf, sizeof(buf), "  %4d  ", i + 1);
        e.Writeln(std::string(buf) + h[i]);
    }
    return 0;
}

} // namespace shell