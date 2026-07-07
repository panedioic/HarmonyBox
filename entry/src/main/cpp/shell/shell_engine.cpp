#include "shell_engine.h"

#include <hilog/log.h>

#include "shell_tokenizer.h"
#include "builtins/builtins.h"

#include "process_manager.h"

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

    if (!cfg_.log_dir.empty()) {
        session_.Init(cfg_.log_dir);
    }
    
    env_.Init(cfg_.env_persist_path);
    // 默认只读键. 用户可以 export 覆盖也可以, 但先保守: PWD/HOME 只读
    env_.AddReadonly("PWD");
    env_.AddReadonly("HOME");
    env_.AddReadonly("SHELL");
    // PWD/HOME 作为 system var 曝光 (值来自 cfg)
    env_.SetSystemVar("HOME", cfg_.home_dir);
    env_.SetSystemVar("PWD",  cwd_);
    env_.SetSystemVar("SHELL", "hbsh");
    
    readline_.Init(
        [this](const std::string& data) { output_->Write(data); },
        [this](const std::string& line) { OnCommit(line); }
    );
    
    uv_loop_t* loop = nullptr;
    if (napi_get_uv_event_loop(env, &loop) == napi_ok && loop) {
        async_ = new uv_async_t();
        if (uv_async_init(loop, async_, &ShellEngine::OnAsync) == 0) {
            async_->data = this;
        } else {
            delete async_;
            async_ = nullptr;
        }
    }

    RegisterBuiltins(dispatcher_);

    UpdatePrompt();
    initialized_ = true;
    WriteBanner();
    readline_.ShowPrompt();
    return true;
}

void ShellEngine::Shutdown() {
    if (!initialized_) return;

    // 有 busy 进程先 kill 掉
    if (busy_) {
        if (busy_pid_ > 0) {
            KillBusy();
        } else {
            // 外部命令: 无法 kill ArkTS handler, 只能标记结束
            // handler 之后若还调 shellCommandDone, 会因 !busy_ 而忽略
            busy_ = false;
        }
    }

    dispatcher_.ReleaseAllExternal();
    readline_.Reset();
    output_->Flush();
    session_.Shutdown();

    if (async_) {
        uv_close(reinterpret_cast<uv_handle_t*>(async_),
                 [](uv_handle_t* h) {
                     delete reinterpret_cast<uv_async_t*>(h);
                 });
        async_ = nullptr;
    }

    // 丢掉未处理的 async event
    std::lock_guard<std::mutex> lk(async_mu_);
    async_queue_.clear();
    
    // 不 kill 后台任务, 只关 log fd
    jobs_.Clear();

    output_.reset();
    busy_ = false;
    busy_pid_ = 0;
    initialized_ = false;
}

void ShellEngine::Input(const std::string& data) {
    if (!initialized_) return;
    if (busy_) {
        // 只处理 Ctrl+C, 其他忽略
        for (char c : data) {
            if (c == 0x03) {
                Write("^C\r\n");
                KillBusy();
            }
        }
        return;
    }
    readline_.Feed(data);
}

void ShellEngine::Resize(int cols, int rows) {
    if (cols > 0) cfg_.cols = cols;
    if (rows > 0) cfg_.rows = rows;
}

void ShellEngine::Write(const std::string& data) {
    if (output_) output_->Write(data);
    session_.Append(data);
}

void ShellEngine::Writeln(const std::string& data) {
    Write(data + "\r\n");
}

void ShellEngine::WriteErr(const std::string& data) {
    Write("\x1b[31m" + data + "\x1b[0m\r\n");
}

void ShellEngine::OnCommit(const std::string& line) {
    if (line.empty()) {
        readline_.ShowPrompt();
        return;
    }

    // 给日志加一行 "$ command", 不输出到 xterm
    if (session_.IsOpen()) {
        session_.AppendDirect("$ " + line + "\n");
    }
    
    TokenizeResult tk = Tokenize(line, [this](const std::string& k) { return env_.Get(k); });
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
        if (cmd->kind == CommandKind::kBuiltin) {
            last_exit_ = cmd->fn(*this, args);
        } else if (cmd->kind == CommandKind::kExternal) {
            DispatchExternal(*cmd, args);
            // busy 状态由 DispatchExternal 内部设置
        }
    } catch (const std::exception& ex) {
        WriteErr(std::string("hbsh: exception: ") + ex.what());
        last_exit_ = 1;
    } catch (...) {
        WriteErr("hbsh: unknown exception");
        last_exit_ = 1;
    }

    // 如果命令启动了异步任务, 不打 prompt
    if (busy_) return;
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
    Write("\x1b[1;32m╭─────────────────────────────────╮\x1b[0m\r\n");
    Write("\x1b[1;32m│  HarmonyBox Debug Shell  v0.1   │\x1b[0m\r\n");
    Write("\x1b[1;32m╰─────────────────────────────────╯\x1b[0m\r\n");
    Write("type \x1b[33mhelp\x1b[0m to list commands\r\n");
    if (session_.IsOpen()) {
        Write("\x1b[90mlog: " + session_.GetLogPath() + "\x1b[0m\r\n");
    }
    Write("\r\n");
}

void ShellEngine::SetCwd(const std::string& p) { 
    cwd_ = p; 
    env_.SetSystemVar("PWD", cwd_); 
    UpdatePrompt(); 
}

void ShellEngine::InjectSystemEnv(const std::string& key, const std::string& val) {
    env_.SetSystemVar(key, val);
}

void ShellEngine::MarkReadonlyEnv(const std::string& key) {
    env_.AddReadonly(key);
}

void ShellEngine::PostAsyncOutput(std::string data) {
    {
        std::lock_guard<std::mutex> lk(async_mu_);
        AsyncEvent ev;
        ev.type = AsyncEvent::kOutput;
        ev.data = std::move(data);
        ev.exit_code = 0;
        async_queue_.push_back(std::move(ev));
    }
    if (async_) uv_async_send(async_);
}

void ShellEngine::PostAsyncExit(int code) {
    {
        std::lock_guard<std::mutex> lk(async_mu_);
        AsyncEvent ev;
        ev.type = AsyncEvent::kExit;
        ev.exit_code = code;
        async_queue_.push_back(std::move(ev));
    }
    if (async_) uv_async_send(async_);
}

void ShellEngine::OnAsync(uv_async_t* h) {
    auto* self = static_cast<ShellEngine*>(h->data);
    if (self) self->DrainAsync();
}

void ShellEngine::DrainAsync() {
    std::deque<AsyncEvent> local;
    {
        std::lock_guard<std::mutex> lk(async_mu_);
        local.swap(async_queue_);
    }
    if (!initialized_) return;
    for (auto& ev : local) {
        if (ev.type == AsyncEvent::kOutput) {
            Write(ev.data);
        } else if (ev.type == AsyncEvent::kExit) {
            EndBusy(ev.exit_code);
        } else if (ev.type == AsyncEvent::kBgExit) {
            OnBgJobExit(ev.pid, ev.exit_code);
        }
    }
}

void ShellEngine::BeginBusy(pid_t pid, const std::string& label) {
    busy_ = true;
    busy_pid_ = pid;
    busy_label_ = label;
}

void ShellEngine::EndBusy(int code) {
    if (!busy_) return;
    busy_ = false;
    busy_pid_ = 0;
    last_exit_ = code;
    std::string tag = code == 0 ? "\x1b[90m" : "\x1b[31m";
    Writeln(tag + "[" + busy_label_ + " exit=" + std::to_string(code) + "]\x1b[0m");
    busy_label_.clear();
    readline_.ShowPrompt();
}

void ShellEngine::KillBusy() {
    if (busy_pid_ > 0) {
        procmgr::Terminate(busy_pid_);
    }
}

void ShellEngine::PostBgExit(pid_t pid, int code) {
    {
        std::lock_guard<std::mutex> lk(async_mu_);
        AsyncEvent ev;
        ev.type = AsyncEvent::kBgExit;
        ev.exit_code = code;
        ev.pid = pid;
        async_queue_.push_back(std::move(ev));
    }
    if (async_) uv_async_send(async_);
}

void ShellEngine::OnBgJobExit(pid_t pid, int code) {
    jobs_.MarkExited(pid, code);
    // busy 状态下不打断当前提示, 只在空闲时通知
    if (!busy_) {
        // 把提示写在当前行头
        Write("\r\x1b[K");
        std::string tag = code == 0 ? "\x1b[90m" : "\x1b[33m";
        const ShellJob* j = jobs_.Get(pid);
        std::string label = j ? j->label : "job";
        Writeln(tag + "[" + label + " pid=" + std::to_string(pid) +
                " exit=" + std::to_string(code) + "]\x1b[0m");
        readline_.ShowPrompt();
    }
}

void ShellEngine::DispatchExternal(const CommandEntry& cmd,
                                   const std::vector<std::string>& args) {
    if (!cmd.tsfn) {
        WriteErr("hbsh: external command '" + cmd.name + "' has null tsfn");
        return;
    }
    auto* payload = new ExternalCallPayload();
    payload->cmd_name = cmd.name;
    payload->args = args;

    // 把 env 打包
    for (auto& e : env_.All()) {
        payload->env_kv.push_back({ e.key, e.val });
    }

    // busy_pid 用负数表示"外部命令", label 用 cmd 名
    BeginBusy((pid_t)(-1), cmd.name);

    napi_status st = napi_call_threadsafe_function(
        cmd.tsfn, payload, napi_tsfn_blocking);
    if (st != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "shell external tsfn call failed: %{public}d",
                     (int)st);
        delete payload;
        EndBusy(1);
    }
}

void ShellEngine::CommandDone(int code) {
    if (!busy_) return;
    // 外部命令没有 pid, 通过 async 走一遍保持顺序 (与流式 output 有序)
    PostAsyncExit(code);
}

void ShellEngine::StreamWrite(const std::string& data) {
    if (!busy_ || data.empty()) return;
    PostAsyncOutput(data);
}

} // namespace shell

namespace shell {

void ExternalCallJs(napi_env env, napi_value js_cb,
                    void* /*ctx*/, void* raw) {
    auto* payload = static_cast<ExternalCallPayload*>(raw);
    if (!payload) return;
    if (!env || !js_cb) { delete payload; return; }

    napi_value js_args = nullptr;
    napi_create_array_with_length(env, payload->args.size(), &js_args);
    for (size_t i = 0; i < payload->args.size(); ++i) {
        napi_value s = nullptr;
        napi_create_string_utf8(env, payload->args[i].c_str(),
                                payload->args[i].size(), &s);
        napi_set_element(env, js_args, (uint32_t)i, s);
    }

    napi_value js_env = nullptr;
    napi_create_object(env, &js_env);
    for (auto& kv : payload->env_kv) {
        napi_value v = nullptr;
        napi_create_string_utf8(env, kv.second.c_str(), kv.second.size(), &v);
        napi_set_named_property(env, js_env, kv.first.c_str(), v);
    }

    napi_value js_meta = nullptr;
    napi_create_object(env, &js_meta);
    napi_value js_name = nullptr;
    napi_create_string_utf8(env, payload->cmd_name.c_str(),
                            payload->cmd_name.size(), &js_name);
    napi_set_named_property(env, js_meta, "name", js_name);

    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    napi_value call_args[3] = { js_args, js_env, js_meta };
    napi_value ret = nullptr;
    napi_status st = napi_call_function(env, undef, js_cb, 3, call_args, &ret);
    if (st != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "shell external handler call failed: %{public}d",
                     (int)st);
        ShellEngine::Instance().CommandDone(1);
    }
    delete payload;
}

}  // namespace shell