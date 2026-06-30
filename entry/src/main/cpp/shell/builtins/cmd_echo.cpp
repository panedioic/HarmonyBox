#include "builtins.h"
#include "../shell_engine.h"

namespace shell {

int CmdEcho(ShellEngine& e, const std::vector<std::string>& args) {
    bool no_newline = false;
    size_t start = 0;
    if (!args.empty() && args[0] == "-n") {
        no_newline = true;
        start = 1;
    }
    std::string out;
    for (size_t i = start; i < args.size(); ++i) {
        if (i > start) out.push_back(' ');
        out += args[i];
    }
    if (no_newline) e.Write(out);
    else            e.Writeln(out);
    return 0;
}

} // namespace shell