#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"
#include "../shell_process.h"

#include <ctime>

namespace shell {

namespace {

std::string PickLabel(const std::vector<std::string>& args) {
    if (args.empty()) return "job";
    // 如果第一个 arg 是 wine/wineserver/box64, 用它
    const std::string& first = args[0];
    if (first == "wine" || first == "wineserver" || first == "box64") {
        return first;
    }
    // 否则用 basename
    size_t slash = first.rfind('/');
    return slash == std::string::npos ? first : first.substr(slash + 1);
}

std::string MakeLogPath(ShellEngine& e, const std::string& label) {
    std::string dir = e.Env().Get("FILES_DIR") + "/shell-logs";
    time_t t = time(nullptr);
    struct tm tm; localtime_r(&t, &tm);
    char ts[32];
    snprintf(ts, sizeof(ts), "%04d%02d%02d-%02d%02d%02d",
             tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec);
    return dir + "/bg-" + label + "-" + ts + ".log";
}

} // anonymous namespace

int CmdBg(ShellEngine& e, const std::vector<std::string>& args) {
    if (args.empty()) {
        e.WriteErr("bg: missing command (usage: bg <cmd> [args...])");
        return 2;
    }

    // 解析: bg [wine|wineserver|box64|<path>] <args...>
    std::vector<std::string> box64_args;
    const std::string& cmd = args[0];
    std::string label;
    std::string exe;

    if (cmd == "wine") {
        exe = e.Env().Get("HBOX_WINE_BIN");
        label = "wine";
    } else if (cmd == "wineserver") {
        exe = e.Env().Get("HBOX_WINESERVER_BIN");
        label = "wineserver";
    } else if (cmd == "box64") {
        // bg box64 <path> [args...]
        for (size_t i = 1; i < args.size(); ++i) box64_args.push_back(args[i]);
        label = "box64";
    } else {
        // 直接把 cmd 当 elf 路径, 交给 box64 跑
        exe = cmd;
        label = PickLabel(args);
    }

    if (cmd != "box64") {
        if (exe.empty()) {
            e.WriteErr("bg: could not resolve executable for '" + cmd + "'");
            return 1;
        }
        box64_args.push_back(exe);
        for (size_t i = 1; i < args.size(); ++i) box64_args.push_back(args[i]);
    }

    std::string log_path = MakeLogPath(e, label);
    pid_t pid = SpawnBox64Background(e, box64_args, label, log_path);
    if (pid <= 0) return 1;

    e.Writeln("\x1b[32m[" + label + "]\x1b[0m pid=" +
              std::to_string(pid) + " log=" + log_path);
    return 0;
}

} // namespace shell