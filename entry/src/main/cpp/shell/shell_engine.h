#ifndef HBOX_SHELL_ENGINE_H
#define HBOX_SHELL_ENGINE_H

#include <memory>
#include <string>

#include "napi/native_api.h"
#include "shell_output.h"
#include "shell_readline.h"
#include "shell_dispatcher.h"
#include "shell_session.h"

namespace shell {

struct ShellConfig {
    std::string home_dir;
    std::string log_dir;
    int cols = 80;
    int rows = 24;
};

class ShellEngine {
public:
    static ShellEngine& Instance();

    bool Init(napi_env env, const ShellConfig& cfg, napi_value output_cb);
    void Shutdown();
    bool IsInitialized() const { return initialized_; }

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

    void SetCwd(const std::string& p) { cwd_ = p; UpdatePrompt(); }

    ShellDispatcher& Dispatcher()   { return dispatcher_; }

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
};

} // namespace shell

#endif