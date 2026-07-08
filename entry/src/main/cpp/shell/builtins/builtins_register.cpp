#include "builtins.h"

namespace shell {

void RegisterBuiltins(ShellDispatcher& d) {
    d.RegisterBuiltin("help",  "show available commands",
                      "help [cmd]", CmdHelp);
    d.RegisterBuiltin("clear", "clear the screen",
                      "clear", CmdClear);
    d.RegisterBuiltin("echo",  "print arguments",
                      "echo [-n] <text...>", CmdEcho);
    d.RegisterBuiltin("pwd",   "print working directory",
                      "pwd", CmdPwd);
    d.RegisterBuiltin("cd",    "change directory",
                      "cd [dir]", CmdCd);
    d.RegisterBuiltin("ls",    "list directory entries",
                      "ls [-a] [-l] [path...]", CmdLs);
    d.RegisterBuiltin("cat",   "print file contents",
                      "cat <file...>", CmdCat);
    d.RegisterBuiltin("env",    "list environment variables",
                      "env [prefix]", CmdEnv);
    d.RegisterBuiltin("export", "set (and optionally persist) a variable",
                      "export [-p] KEY=VAL...", CmdExport);
    d.RegisterBuiltin("unset",  "unset a variable",
                      "unset [-p] KEY...", CmdUnset);
    d.RegisterBuiltin("box64",      "run box64 with args",
                      "box64 <args...>", CmdBox64);
    d.RegisterBuiltin("wine",       "run wine (auto box64 prefix)",
                      "wine <args...>", CmdWine);
    d.RegisterBuiltin("wineserver", "run wineserver (auto box64 prefix)",
                      "wineserver [-f -p -k]", CmdWineserver);
    d.RegisterBuiltin("procmgr.start", "start reverse-spawn control socket",
                      "procmgr.start [sock-path]", CmdProcMgrStart);
    d.RegisterBuiltin("procmgr.stop",  "stop control socket",
                      "procmgr.stop", CmdProcMgrStop);
    d.RegisterBuiltin("status", "show shell / wine / procmgr status",
                      "status", CmdStatus);
    d.RegisterBuiltin("bg",   "run command in background (output to log file)",
                      "bg <cmd> [args...]", CmdBg);
    d.RegisterBuiltin("jobs", "list background jobs of this session",
                      "jobs", CmdJobs);
    d.RegisterBuiltin("kill", "send SIGTERM to pid",
                      "kill <pid...>", CmdKill);
    d.RegisterBuiltin("wineserver.start",  "start wineserver -f -p in background",
                      "wineserver.start [extra args]", CmdWineserverStart);
    d.RegisterBuiltin("wineserver.stop",   "kill wineserver started by this shell",
                      "wineserver.stop", CmdWineserverStop);
    d.RegisterBuiltin("wineserver.status", "show wineserver state",
                      "wineserver.status", CmdWineserverStatus);
    d.RegisterBuiltin("ps",      "list processes in procmgr registry",
                      "ps [-a]", CmdPs);
    d.RegisterBuiltin("head",    "print first N lines of file",
                      "head [-n N] <file...>", CmdHead);
    d.RegisterBuiltin("tail",    "print last N lines of file",
                      "tail [-n N] <file...>", CmdTail);
    d.RegisterBuiltin("grep",    "search for pattern in files (literal string)",
                      "grep [-i -v -n -c] <pattern> <file...>", CmdGrep);
    d.RegisterBuiltin("history", "show command history",
                      "history [N|-c]", CmdHistory);
    d.RegisterBuiltin("wine.setup", "initialize wineprefix (SetupWinePrefix)",
                      "wine.setup [-f]", CmdWineSetup);
    d.RegisterBuiltin("app.launch", "launch app by name from app.json (stub)",
                      "app.launch <name>", CmdAppLaunch);
}

} // namespace shell