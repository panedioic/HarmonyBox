#ifndef HBOX_SHELL_BUILTINS_H
#define HBOX_SHELL_BUILTINS_H

#include "../shell_dispatcher.h"

namespace shell {

class ShellEngine;

int CmdHelp (ShellEngine& e, const std::vector<std::string>& args);
int CmdClear(ShellEngine& e, const std::vector<std::string>& args);
int CmdEcho (ShellEngine& e, const std::vector<std::string>& args);
int CmdPwd  (ShellEngine& e, const std::vector<std::string>& args);
int CmdCd   (ShellEngine& e, const std::vector<std::string>& args);
int CmdLs   (ShellEngine& e, const std::vector<std::string>& args);
int CmdCat  (ShellEngine& e, const std::vector<std::string>& args);

void RegisterBuiltins(ShellDispatcher& d);

} // namespace shell

#endif