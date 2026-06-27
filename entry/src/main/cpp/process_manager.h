#pragma once

#include "napi/native_api.h"

#include <cstdint>
#include <functional>
#include <string>
#include <sys/types.h>
#include <vector>
#include <memory>

namespace procmgr {

// ============================================================
//  类型
// ============================================================

enum class LaunchKind {
    kNative,   // execve 一个原生 ARM 二进制
    kBox64,    // fork 后在子进程内 dlopen(libbox64.so) + box64_run
};

enum class KindHint {
    kAuto,         // basename(exe_path) == "box64" 即 Box64,否则 Native
    kForceNative,
    kForceBox64,
};

// 流式输出: 每行一次 on_line; EOF + waitpid 完成后 on_exit
struct StreamSink {
    std::function<void(pid_t pid, const std::string& line)> on_line;
    std::function<void(pid_t pid, int exit_code)>           on_exit;
};

// 一次性收集: 攒到 max_bytes 或 EOF 后 on_done(code, output)
struct CaptureSink {
    size_t max_bytes = 8192;
    std::function<void(int exit_code, std::string output)> on_done;
};

// 启动请求
struct SpawnRequest {
    std::string              exe_path;     // 实际启动的可执行文件
    std::vector<std::string> argv;         // 完整 argv (含 argv[0]);空时自动填 [exe_path]
    std::vector<std::string> env;          // 完整 env, "KEY=VALUE"
    std::string              cwd;          // 空 = 不 chdir
    std::string              proc_name;    // prctl(PR_SET_NAME),≤15 字符;空 = 不设置
    KindHint                 kind_hint = KindHint::kAuto;

    // stream / capture 同时只能有一个非空,都为空则 stdout/stderr → /dev/null
    StreamSink*  stream  = nullptr;
    CaptureSink* capture = nullptr;
    
    bool sync_wait = false;                 // 阻塞等子进程结束
    
    // 共享 sink. 优先级高于 raw stream/capture 指针.
    std::shared_ptr<StreamSink>  shared_stream;
    std::shared_ptr<CaptureSink> shared_capture;
    
    pid_t caller_pid = -1;   // sock 路径下由 HandleCreate 填; NAPI 直调时 -1
};

struct SpawnResult {
    pid_t       pid  = -1;                 // > 0 表示成功
    LaunchKind  kind = LaunchKind::kNative;
    std::string error;                     // 失败时填,成功时为空
    int exit_code = -1;                    // 新增: sync_wait=true 且 pid>0 时有效
};

struct ProcessInfo {
    pid_t       pid           = 0;
    pid_t       parent_pid    = 0;        // 逻辑父进程 (SO_PEERCRED 拿到)
    LaunchKind  kind          = LaunchKind::kNative;
    std::string exe_path;
    int64_t     start_time_ms = 0;        // epoch 毫秒
    int         exit_code     = -1;       // -1 = 尚未退出
    bool        alive         = true;
    // 共享 sink. NAPI 调用时由入口填; sock 路径通过 peer PID
    // 反查父进程, 把这两个字段继承过来.
    std::shared_ptr<StreamSink>  shared_stream;
    std::shared_ptr<CaptureSink> shared_capture;
};

// ============================================================
//  Native API
// ============================================================

// 启动一个进程。fork 一返回就出栈,不等子进程就绪。
SpawnResult Spawn(const SpawnRequest& req);

// SIGTERM,800ms 后还活着补 SIGKILL。pid <= 0 静默忽略。
void Terminate(pid_t pid);

// 拿一份进程表快照。
std::vector<ProcessInfo> ListProcesses();

// ============================================================
//  Control Socket (可选,给 box64 子进程的反向 spawn 通道)
// ============================================================
//
// 协议: 长度前缀帧(4 字节 BE 长度 + 文本 payload)
// 详见 process_manager.cpp 中的协议注释。
bool StartControlSocket(const std::string& sock_path);
void StopControlSocket();

// ============================================================
//  NAPI
// ============================================================
//
// runCommand(exePath: string,
//            argv: string[],
//            env: string[],
//            cwd?: string,
//            onEvent?: (event: 'out'|'exit', data: string) => void,
//            kindHint?: 'auto'|'native'|'box64'): number
//   - 返回 pid (>0) 或 -1
//   - 自动按 exePath 末尾是 "box64" 判定走 Box64 还是 Native
napi_value RunCommandNapi   (napi_env env, napi_callback_info info);

// terminate(pid: number): void
napi_value TerminateNapi    (napi_env env, napi_callback_info info);

// listProcesses(): { pid, parentPid, kind, exePath, startTimeMs,
//                    exitCode, alive }[]
napi_value ListProcessesNapi(napi_env env, napi_callback_info info);

// ---- Control Socket 显式控制 ----
//
// startProcMgr(sockPath: string): boolean
//   显式启动反向 spawn 通道。重复调用安全(已启动返回 true)。
napi_value StartControlSocketNapi(napi_env env, napi_callback_info info);

// stopProcMgr(): void
napi_value StopControlSocketNapi (napi_env env, napi_callback_info info);

// ---- 兼容旧接口 (DEPRECATED) ----
//
// runBox64(elfPath, argv, env, cwd?, onEvent?): number
//   等价于 runCommand(..., kindHint='box64')。
//   迁移完成后请删除,改用 runCommand。
napi_value RunBox64NapiCompat   (napi_env env, napi_callback_info info);

} // namespace procmgr