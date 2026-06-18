#pragma once
#include "napi/native_api.h"
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


// 通过 libbox64.so 动态库运行 x86_64 ELF。
//
// 关键约束: 父进程绝不能 dlopen libbox64.so。一旦父进程加载了它,
// OHOS LSM 会让该进程及其后续所有 fork 子进程失去 PROT_EXEC 权限,
// dynarec / ET_EXEC 加载都会失败。所以只在 fork 出来的子进程里
// dlopen libbox64.so + dlsym(box64_run) 后调用。
//
// 子进程会:
//   1. setenv 把 env 中的 KEY=VALUE 写入 environ
//   2. munmap 低 4GB 的 anon / ark VM 区域,给 ET_EXEC link base 腾位置
//   3. dlopen libbox64.so (依次尝试: 短名 / LD_LIBRARY_PATH 各目录 / 写死路径)
//   4. 调用 box64_run(argc, argv, environ),其中 argv = ["box64", elfPath, guestArgs...]
//
// stream / capture 至多一个非空; 都为 nullptr 时 stdout/stderr 重定向到 /dev/null。
//
// 返回 pid (>0) 或 -1。
int RunBox64(const std::string& elfPath,
             const std::vector<std::string>& guestArgs,
             const std::vector<std::string>& env,
             const std::string& cwd,
             StreamSink* stream,
             CaptureSink* capture);

// 通过 execve 运行原生 ARM 可执行文件。
int RunCommand(const std::string& exe,
               const std::vector<std::string>& argv,
               const std::vector<std::string>& env,
               const std::string& cwd,
               StreamSink* stream,
               CaptureSink* capture);

// 先 SIGTERM,800ms 后还活着补 SIGKILL。
void TerminateProcess(pid_t pid);

// ============ NAPI wrappers ============
//
// JS 签名:
//   runBox64(exe: string,
//            argv: string[],
//            env:  string[],
//            cwd:  string,
//            cb?:  (pid: number, event: 'out') => void): number
//
//   runCommand(...同上)
//
//   terminate(pid: number): void
//
// cb 省略或传 null/undefined  → 子进程 stdout/stderr 重定向到 /dev/null。
// cb 是函数                   → 按行回调 'out',进程结束回调 'exit' (data = exit code 字符串)。
// 返回值: pid (>0) 或 -1。
napi_value RunBox64Napi  (napi_env env, napi_callback_info info);
napi_value RunCommandNapi(napi_env env, napi_callback_info info);
napi_value TerminateNapi (napi_env env, napi_callback_info info);

} // namespace proc