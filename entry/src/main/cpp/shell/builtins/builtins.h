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
int CmdEnv    (ShellEngine& e, const std::vector<std::string>& args);
int CmdExport (ShellEngine& e, const std::vector<std::string>& args);
int CmdUnset  (ShellEngine& e, const std::vector<std::string>& args);
int CmdBox64      (ShellEngine& e, const std::vector<std::string>& args);
int CmdWine       (ShellEngine& e, const std::vector<std::string>& args);
int CmdWineserver (ShellEngine& e, const std::vector<std::string>& args);
int CmdProcMgrStart(ShellEngine& e, const std::vector<std::string>& args);
int CmdProcMgrStop (ShellEngine& e, const std::vector<std::string>& args);
int CmdStatus     (ShellEngine& e, const std::vector<std::string>& args);
int CmdBg              (ShellEngine& e, const std::vector<std::string>& args);
int CmdJobs            (ShellEngine& e, const std::vector<std::string>& args);
int CmdKill            (ShellEngine& e, const std::vector<std::string>& args);
int CmdWineserverStart (ShellEngine& e, const std::vector<std::string>& args);
int CmdWineserverStop  (ShellEngine& e, const std::vector<std::string>& args);
int CmdWineserverStatus(ShellEngine& e, const std::vector<std::string>& args);
int CmdPs      (ShellEngine& e, const std::vector<std::string>& args);
int CmdHead    (ShellEngine& e, const std::vector<std::string>& args);
int CmdTail    (ShellEngine& e, const std::vector<std::string>& args);
int CmdGrep    (ShellEngine& e, const std::vector<std::string>& args);
int CmdHistory (ShellEngine& e, const std::vector<std::string>& args);
int CmdWineSetup(ShellEngine& e, const std::vector<std::string>& args);
int CmdAppLaunch(ShellEngine& e, const std::vector<std::string>& args);

void RegisterBuiltins(ShellDispatcher& d);

} // namespace shell

#endif