#include "builtins.h"
#include "../shell_engine.h"
#include "../shell_path.h"

#include <sys/stat.h>
#include <errno.h>
#include <string.h>

namespace shell {

int CmdCd(ShellEngine& e, const std::vector<std::string>& args) {
    std::string target;
    if (args.empty()) {
        target = e.Home();
    } else {
        target = ResolvePath(e.Cwd(), e.Home(), args[0]);
    }
    struct stat st;
    if (stat(target.c_str(), &st) != 0) {
        e.WriteErr(std::string("cd: ") + target + ": " + strerror(errno));
        return 1;
    }
    if (!S_ISDIR(st.st_mode)) {
        e.WriteErr("cd: not a directory: " + target);
        return 1;
    }
    e.SetCwd(target);
    return 0;
}

} // namespace shell