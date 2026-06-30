#ifndef HBOX_SHELL_ENGINE_H
#define HBOX_SHELL_ENGINE_H

#include <memory>
#include <string>

#include "napi/native_api.h"
#include "shell_output.h"
#include "shell_readline.h"

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

    std::string cwd_;
};

} // namespace shell

#endif