#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"
#include "../../wineprefix_setup.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <errno.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

namespace shell {

namespace {
int64_t NowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}
}

int CmdWineSetup(ShellEngine& e, const std::vector<std::string>& args) {
    if (e.IsBusy()) {
        e.WriteErr("wine.setup: shell is busy");
        return 1;
    }
    std::string prefix    = e.Env().Get("WINEPREFIX");
    std::string wine_root = e.Env().Get("HBOX_WINE_ROOT");
    if (prefix.empty()) {
        e.WriteErr("wine.setup: WINEPREFIX not set");
        return 1;
    }
    if (wine_root.empty()) {
        e.WriteErr("wine.setup: HBOX_WINE_ROOT not set");
        return 1;
    }
    struct stat st;
    if (stat(wine_root.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
        e.WriteErr("wine.setup: wine root not found: " + wine_root);
        return 1;
    }

    bool force = false;
    for (const auto& a : args) {
        if (a == "-f" || a == "--force") force = true;
    }
    if (force) {
        std::string marker = prefix + "/.box64_setup_done";
        if (unlink(marker.c_str()) == 0) {
            e.Writeln("\x1b[90mremoved existing marker\x1b[0m");
        } else if (errno != ENOENT) {
            e.Writeln(std::string("\x1b[33munlink marker: ") +
                      strerror(errno) + "\x1b[0m");
        }
    }

    e.Writeln("prefix    = \x1b[36m" + prefix + "\x1b[0m");
    e.Writeln("wineRoot  = \x1b[36m" + wine_root + "\x1b[0m");
    e.Writeln("\x1b[90m[running SetupWinePrefix, this may take a while...]\x1b[0m");

    e.BeginBusy((pid_t)(-2), "wine.setup");
    ShellEngine* eng = &e;
    std::thread([eng, prefix, wine_root]() {
        int64_t start = NowMs();
        bool ok = false;
        std::string err;
        try {
            ok = wineprefix::SetupWinePrefix(prefix, wine_root);
        } catch (const std::exception& ex) { err = ex.what(); }
          catch (...)                       { err = "unknown c++ exception"; }
        int64_t cost = NowMs() - start;

        char buf[256];
        if (ok) {
            snprintf(buf, sizeof(buf),
                "\x1b[32m[SetupWinePrefix ok in %lldms]\x1b[0m\r\n",
                (long long)cost);
        } else if (!err.empty()) {
            snprintf(buf, sizeof(buf),
                "\x1b[31m[SetupWinePrefix error: %s]\x1b[0m\r\n", err.c_str());
        } else {
            snprintf(buf, sizeof(buf),
                "\x1b[31m[SetupWinePrefix FAILED in %lldms]\x1b[0m\r\n",
                (long long)cost);
        }
        eng->PostAsyncOutput(buf);
        eng->PostAsyncExit(ok ? 0 : 1);
    }).detach();

    return 0;
}

} // namespace shell