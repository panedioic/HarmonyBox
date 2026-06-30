#include "shell_engine.h"

#include <hilog/log.h>

#include "shell_tokenizer.h"
#include "builtins/builtins.h"

#undef LOG_TAG
#define LOG_TAG "HBox_NAPI_Shell_SEngine"

namespace shell {

ShellEngine& ShellEngine::Instance() {
    static ShellEngine s;
    return s;
}

bool ShellEngine::Init(napi_env env, const ShellConfig& cfg, napi_value output_cb) {
    if (initialized_) Shutdown();

    cfg_ = cfg;
    output_ = ShellOutput::Create(env, output_cb);
    if (!output_) {
        OH_LOG_ERROR(LOG_APP, "shell init: output create failed");
        return false;
    }
    cwd_ = cfg_.home_dir;
    last_exit_ = 0;

    readline_.Init(
        [this](const std::string& data) { output_->Write(data); },
        [this](const std::string& line) { OnCommit(line); }
    );

    RegisterBuiltins(dispatcher_);

    UpdatePrompt();
    initialized_ = true;
    WriteBanner();
    readline_.ShowPrompt();
    return true;
}

void ShellEngine::Shutdown() {
    if (!initialized_) return;
    readline_.Reset();
    output_.reset();
    initialized_ = false;
}

void ShellEngine::Input(const std::string& data) {
    if (!initialized_) return;
    readline_.Feed(data);
}

void ShellEngine::Resize(int cols, int rows) {
    if (cols > 0) cfg_.cols = cols;
    if (rows > 0) cfg_.rows = rows;
}

void ShellEngine::Write(const std::string& data) {
    if (output_) output_->Write(data);
}

void ShellEngine::Writeln(const std::string& data) {
    if (output_) output_->Write(data + "\r\n");
}

void ShellEngine::WriteErr(const std::string& data) {
    if (output_) output_->Write("\x1b[31m" + data + "\x1b[0m\r\n");
}

void ShellEngine::OnCommit(const std::string& line) {
    if (line.empty()) {
        readline_.ShowPrompt();
        return;
    }

    TokenizeResult tk = Tokenize(line);
    if (!tk.ok) {
        WriteErr("hbsh: " + tk.error);
        last_exit_ = 2;
        readline_.ShowPrompt();
        return;
    }
    if (tk.tokens.empty()) {
        readline_.ShowPrompt();
        return;
    }

    const std::string& name = tk.tokens[0];
    const CommandEntry* cmd = dispatcher_.Find(name);
    if (!cmd) {
        WriteErr("hbsh: command not found: " + name);
        last_exit_ = 127;
        readline_.ShowPrompt();
        return;
    }

    try {
        std::vector<std::string> args(tk.tokens.begin() + 1, tk.tokens.end());
        last_exit_ = cmd->fn(*this, args);
    } catch (const std::exception& e) {
        WriteErr(std::string("hbsh: exception: ") + e.what());
        last_exit_ = 1;
    } catch (...) {
        WriteErr("hbsh: unknown exception");
        last_exit_ = 1;
    }

    readline_.ShowPrompt();
}

void ShellEngine::UpdatePrompt() {
    std::string display = cwd_;
    if (!cfg_.home_dir.empty()) {
        if (cwd_ == cfg_.home_dir) {
            display = "~";
        } else if (cwd_.size() > cfg_.home_dir.size() &&
                   cwd_.compare(0, cfg_.home_dir.size(), cfg_.home_dir) == 0 &&
                   cwd_[cfg_.home_dir.size()] == '/') {
            display = "~" + cwd_.substr(cfg_.home_dir.size());
        }
    }
    if (display.size() > 30) {
        size_t last = display.rfind('/');
        if (last != std::string::npos && last > 0) {
            size_t prev = display.rfind('/', last - 1);
            if (prev != std::string::npos) {
                display = ".../" + display.substr(prev + 1);
            }
        }
    }
    std::string prompt = "\x1b[1;36mhbsh\x1b[0m:\x1b[1;34m" + display + "\x1b[0m$ ";
    int visible = 5 + 1 + (int)display.size() + 2;
    readline_.SetPrompt(prompt, visible);
}

void ShellEngine::WriteBanner() {
    output_->Write("\x1b[1;32m╭─────────────────────────────────╮\x1b[0m\r\n");
    output_->Write("\x1b[1;32m│  HarmonyBox Debug Shell  v0.1   │\x1b[0m\r\n");
    output_->Write("\x1b[1;32m╰─────────────────────────────────╯\x1b[0m\r\n");
    output_->Write("type \x1b[33mhelp\x1b[0m to list commands\r\n\r\n");
}

} // namespace shell