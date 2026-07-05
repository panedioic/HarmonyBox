#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_env.h"
#include "../shell_jobs.h"
#include "../shell_process.h"
#include "../../process_manager.h"

#include <ctime>
#include <sys/stat.h>

namespace shell {

namespace {

std::string LogPath(ShellEngine& e) {
    std::string dir = e.Env().Get("FILES_DIR") + "/shell-logs";
    time_t t = time(nullptr);
    struct tm tm; localtime_r(&t, &tm);
    char ts[32];
    snprintf(ts, sizeof(ts), "%04d%02d%02d-%02d%02d%02d",
             tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec);
    return dir + "/bg-wineserver-" + ts + ".log";
}

} // anonymous namespace

int CmdWineserverStart(ShellEngine& e, const std::vector<std::string>& args) {
    // 已经有活的直接返回
    auto pids = e.Jobs().FindByLabel("wineserver");
    for (pid_t p : pids) {
        if (kill(p, 0) == 0) {
            e.Writeln("\x1b[33mwineserver already running pid=" +
                      std::to_string(p) + "\x1b[0m");
            return 0;
        }
    }
    std::string ws = e.Env().Get("HBOX_WINESERVER_BIN");
    if (ws.empty()) {
        e.WriteErr("wineserver.start: HBOX_WINESERVER_BIN not set");
        return 1;
    }
    std::vector<std::string> box64_args = { ws, "-f", "-p" };
    for (const auto& a : args) box64_args.push_back(a);

    pid_t pid = SpawnBox64Background(e, box64_args, "wineserver", LogPath(e));
    if (pid <= 0) return 1;
    e.Writeln("\x1b[32m[wineserver]\x1b[0m pid=" + std::to_string(pid) +
              " (foreground -f -p mode)");
    return 0;
}

int CmdWineserverStop(ShellEngine& e, const std::vector<std::string>& /*args*/) {
    auto pids = e.Jobs().FindByLabel("wineserver");
    int alive_count = 0;
    for (pid_t p : pids) {
        if (kill(p, 0) == 0) {
            procmgr::Terminate(p);
            e.Writeln("sent SIGTERM to wineserver pid=" + std::to_string(p));
            alive_count++;
        }
    }
    if (alive_count == 0) {
        e.Writeln("\x1b[90mno running wineserver started by this shell\x1b[0m");
    }
    return 0;
}

int CmdWineserverStatus(ShellEngine& e, const std::vector<std::string>& /*args*/) {
    auto pids = e.Jobs().FindByLabel("wineserver");
    bool any = false;
    for (pid_t p : pids) {
        bool alive = (kill(p, 0) == 0);
        e.Writeln(std::string("  pid=") + std::to_string(p) +
                  (alive ? "  \x1b[32mrunning\x1b[0m" : "  \x1b[90mexited\x1b[0m"));
        if (alive) any = true;
    }
    if (!any) {
        e.Writeln("\x1b[90mno wineserver tracked by this shell\x1b[0m");
    }
    // 顺便检查 socket 文件
    std::string prefix = e.Env().Get("WINEPREFIX");
    std::string cache = e.Env().Get("CACHE_DIR");
    std::string tmp = cache + "/box64-tmp";
    struct stat st;
    if (stat(tmp.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
        e.Writeln("\x1b[90mtmp dir: " + tmp + " exists\x1b[0m");
    }
    return 0;
}

} // namespace shell