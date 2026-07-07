#ifndef HBOX_SHELL_ENGINE_H
#define HBOX_SHELL_ENGINE_H

#include <memory>
#include <string>
#include <deque>
#include <mutex>
#include <uv.h>
#include <sys/types.h>

#include "napi/native_api.h"
#include "shell_output.h"
#include "shell_readline.h"
#include "shell_dispatcher.h"
#include "shell_session.h"
#include "shell_env.h"
#include "shell_jobs.h"

namespace shell {

struct ShellConfig {
    std::string home_dir;
    std::string log_dir;
    std::string env_persist_path;
    int cols = 80;
    int rows = 24;
};

struct ExternalCallPayload {
    std::string cmd_name;
    std::vector<std::string> args;
    std::vector<std::pair<std::string, std::string>> env_kv;
};
// tsfn call_js_cb 实现 (定义在 shell_napi.cpp)
void ExternalCallJs(napi_env env, napi_value js_cb, void* ctx, void* data);

class ShellEngine {
public:
    static ShellEngine& Instance();
    
    ShellEnv& Env() { return env_; }

    bool Init(napi_env env, const ShellConfig& cfg, napi_value output_cb);
    void Shutdown();
    bool IsInitialized() const { return initialized_; }
    void InjectSystemEnv(const std::string& key, const std::string& val);
    void MarkReadonlyEnv(const std::string& key);

    void Input(const std::string& data);
    void Resize(int cols, int rows);

    // 给 builtins 用
    void Write(const std::string& data);
    void Writeln(const std::string& data);
    void WriteErr(const std::string& data);          // 红色

    const std::string& Cwd() const  { return cwd_; }
    const std::string& Home() const { return cfg_.home_dir; }
    int Cols() const                { return cfg_.cols; }
    int LastExit() const            { return last_exit_; }

    void SetCwd(const std::string& p);

    ShellDispatcher& Dispatcher()   { return dispatcher_; }

    // 命令启动异步任务后调这些, 从任意线程都可
    void PostAsyncOutput(std::string data);
    void PostAsyncExit(int code);
    // 供命令实现调用 (只在 JS 主线程)
    void BeginBusy(pid_t pid, const std::string& label);
    bool IsBusy() const { return busy_; }
    pid_t BusyPid() const { return busy_pid_; }
    
    ShellJobs& Jobs() { return jobs_; }
    // 由后台任务的 exit 事件调 (async 线程 -> 主线程后)
    void OnBgJobExit(pid_t pid, int code);
    
    void PostBgExit(pid_t pid, int code);
    
    const std::vector<std::string>& HistoryRef() const { return readline_.History(); }
    void ClearHistory() { readline_.ClearHistory(); }
    
    // 外部命令派发 (ArkTS handler resolve 后调):
    void CommandDone(int code);
    void StreamWrite(const std::string& data);

private:
    ShellEngine() = default;
    ShellEngine(const ShellEngine&) = delete;
    ShellEngine& operator=(const ShellEngine&) = delete;

    void OnCommit(const std::string& line);
    void UpdatePrompt();
    void WriteBanner();

    bool initialized_ = false;
    ShellConfig cfg_;
    std::unique_ptr<ShellOutput> output_;
    ShellReadline readline_;
    ShellDispatcher dispatcher_;

    std::string cwd_;
    int last_exit_ = 0;
    
    ShellSession session_;
    
    ShellEnv env_;

    struct AsyncEvent {
        enum Type { kOutput, kExit, kBgExit };
        Type type;
        std::string data;
        int exit_code;
        pid_t pid;
    };
    static void OnAsync(uv_async_t* h);
    void DrainAsync();
    void EndBusy(int code);
    void KillBusy();
    // 异步通道
    uv_async_t* async_ = nullptr;
    std::mutex async_mu_;
    std::deque<AsyncEvent> async_queue_;
    // busy state
    bool busy_ = false;
    pid_t busy_pid_ = 0;
    std::string busy_label_;
    
    ShellJobs jobs_;
    
    // 派发外部命令: 通过 tsfn 调 ArkTS handler
    void DispatchExternal(const CommandEntry& cmd,
                          const std::vector<std::string>& args);
};

} // namespace shell

#endif