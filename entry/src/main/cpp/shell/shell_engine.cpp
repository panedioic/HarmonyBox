#include "shell_engine.h"

#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "HBox_NAPI_Shell_SEngine"

namespace shell {

ShellEngine& ShellEngine::Instance() {
    static ShellEngine s;
    return s;
}

bool ShellEngine::Init(napi_env env, const ShellConfig& cfg, napi_value output_cb) {
    if (initialized_) {
        Shutdown();
    }
    cfg_ = cfg;
    output_ = ShellOutput::Create(env, output_cb);
    if (!output_) {
        OH_LOG_ERROR(LOG_APP, "shell init: output create failed");
        return false;
    }

    cwd_ = cfg_.home_dir;

    readline_.Init(
        [this](const std::string& data) { output_->Write(data); },
        [this](const std::string& line) { OnCommit(line); }
    );

    UpdatePrompt();
    initialized_ = true;
    WriteBanner();
    readline_.ShowPrompt();

    OH_LOG_INFO(LOG_APP, "shell engine initialized");
    return true;
}

void ShellEngine::Shutdown() {
    if (!initialized_) return;
    readline_.Reset();
    output_.reset();
    initialized_ = false;
    OH_LOG_INFO(LOG_APP, "shell engine shutdown");
}

void ShellEngine::Input(const std::string& data) {
    if (!initialized_) return;
    readline_.Feed(data);
}

void ShellEngine::Resize(int cols, int rows) {
    if (cols > 0) cfg_.cols = cols;
    if (rows > 0) cfg_.rows = rows;
}

void ShellEngine::OnCommit(const std::string& line) {
    if (line.empty()) {
        readline_.ShowPrompt();
        return;
    }

    // M2: 只做 echo-back，M3 上 dispatcher
    output_->Write("\x1b[90myou typed:\x1b[0m " + line + "\r\n");
    readline_.ShowPrompt();
}

void ShellEngine::UpdatePrompt() {
    // 缩短路径: home 替换成 ~
    std::string display_path = cwd_;
    if (cwd_ == cfg_.home_dir) {
        display_path = "~";
    } else if (cwd_.size() > cfg_.home_dir.size() &&
               cwd_.substr(0, cfg_.home_dir.size()) == cfg_.home_dir &&
               cwd_[cfg_.home_dir.size()] == '/') {
        display_path = "~" + cwd_.substr(cfg_.home_dir.size());
    }
    // 超长截断
    if (display_path.size() > 30) {
        size_t last_slash = display_path.rfind('/');
        size_t second_last = display_path.rfind('/', last_slash > 0 ? last_slash - 1 : 0);
        if (second_last != std::string::npos && second_last > 3) {
            display_path = ".../" + display_path.substr(second_last + 1);
        }
    }

    std::string prompt_str = "\x1b[1;36mhbsh\x1b[0m:\x1b[1;34m" + display_path + "\x1b[0m$ ";
    int visible_len = 5 + 1 + (int)display_path.size() + 2; // "hbsh" ":" path "$ "
    readline_.SetPrompt(prompt_str, visible_len);
}

void ShellEngine::WriteBanner() {
    output_->Write("\x1b[1;32m╭─────────────────────────────────╮\x1b[0m\r\n");
    output_->Write("\x1b[1;32m│  HarmonyBox Debug Shell  v0.1   │\x1b[0m\r\n");
    output_->Write("\x1b[1;32m╰─────────────────────────────────╯\x1b[0m\r\n");
    output_->Write("type \x1b[33mhelp\x1b[0m to list commands\r\n\r\n");
}

} // namespace shell