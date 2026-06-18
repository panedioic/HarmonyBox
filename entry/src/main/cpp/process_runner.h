#pragma once
#include <string>
#include <vector>
#include <functional>
#include <sys/types.h>

namespace proc {

// 流式输出 sink:每行触发 onLine,EOF + waitpid 后触发 onExit。
struct StreamSink {
    std::function<void(pid_t pid, const std::string& line)> onLine;
    std::function<void(pid_t pid, int exitCode)> onExit;
};

// 一次性收集 sink:积累到 maxBytes 或 EOF 后触发 onDone(code, output)。
struct CaptureSink {
    size_t maxBytes = 8192;
    std::function<void(int exitCode, std::string output)> onDone;
};

// stream / capture:至多一个非空。
//   - 任一非空:子进程 stdout/stderr 接管道,后台线程读取并回调对应 sink。
//   - 都为空:子进程 stdout/stderr 重定向到 /dev/null,父侧不开管道,纯 fire-and-forget。
//   - 都非空:返回 -1,视为非法。
//
// env 由调用方完整组装好(LD_LIBRARY_PATH / XDG_RUNTIME_DIR 等都在外面拼)。
// cwd 为空表示不 chdir。
//
// 返回 pid (>0) 或 -1。
int RunBox64(const std::string& exe,
             const std::vector<std::string>& argv,
             const std::vector<std::string>& env,
             const std::string& cwd,
             StreamSink* stream,
             CaptureSink* capture);

int RunCommand(const std::string& exe,
               const std::vector<std::string>& argv,
               const std::vector<std::string>& env,
               const std::string& cwd,
               StreamSink* stream,
               CaptureSink* capture);

// 先 SIGTERM,800ms 后还活着补 SIGKILL。
void TerminateProcess(pid_t pid);

} // namespace proc