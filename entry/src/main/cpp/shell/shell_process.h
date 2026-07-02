#ifndef HBOX_SHELL_PROCESS_H
#define HBOX_SHELL_PROCESS_H

#include <string>
#include <vector>

namespace shell {

class ShellEngine;

// 用 shell env + 当前 cwd + 异步 stream 启动一个 box64 子进程.
// argv[0] 应该是 "box64" 或不填 (会自动补). 后续元素是 box64 的参数.
// 成功返回 0 (但命令未完成, 进入 busy 状态), 失败返回非 0.
int SpawnBox64FromShell(ShellEngine& e,
                        const std::vector<std::string>& box64_args,
                        const std::string& label);

} // namespace shell

#endif