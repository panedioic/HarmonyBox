#include "builtins.h"
#include "../shell_engine.h"

namespace shell {

int CmdHelp(ShellEngine& e, const std::vector<std::string>& args) {
    if (!args.empty()) {
        const CommandEntry* c = e.Dispatcher().Find(args[0]);
        if (!c) {
            e.WriteErr("help: no such command: " + args[0]);
            return 1;
        }
        e.Writeln("\x1b[1m" + c->name + "\x1b[0m  -  " + c->desc);
        if (!c->usage.empty()) e.Writeln("  usage: " + c->usage);
        return 0;
    }
    e.Writeln("\x1b[1;33mAvailable commands:\x1b[0m");
    for (const CommandEntry* c : e.Dispatcher().All()) {
        std::string line = "  \x1b[36m";
        line += c->name;
        line += "\x1b[0m";
        // 对齐
        int pad = 14 - (int)c->name.size();
        if (pad < 1) pad = 1;
        line += std::string(pad, ' ');
        line += c->desc;
        e.Writeln(line);
    }
    e.Writeln("");
    e.Writeln("\x1b[1;33mShortcuts:\x1b[0m");
    e.Writeln("  Ctrl+C   cancel current input");
    e.Writeln("  Ctrl+L   clear screen");
    e.Writeln("  Ctrl+A/E start / end of line");
    e.Writeln("  Ctrl+U/K delete to start / end");
    e.Writeln("  Up/Down  history");
    return 0;
}

} // namespace shell