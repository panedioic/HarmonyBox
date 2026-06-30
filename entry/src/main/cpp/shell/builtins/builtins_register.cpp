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
}

} // namespace shell