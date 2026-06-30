#include "shell_output.h"

#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "HBox_NAPI_Shell_SOutput"

namespace shell {

namespace {

struct OutputEvent {
    std::string data;
};

void OutputCallJs(napi_env env, napi_value js_cb, void* /*ctx*/, void* raw) {
    auto* ev = static_cast<OutputEvent*>(raw);
    if (!ev) return;
    if (env && js_cb) {
        napi_value undef = nullptr;
        napi_value arg = nullptr;
        napi_get_undefined(env, &undef);
        napi_create_string_utf8(env, ev->data.c_str(), ev->data.size(), &arg);
        napi_call_function(env, undef, js_cb, 1, &arg, nullptr);
    }
    delete ev;
}

} // anonymous namespace

std::unique_ptr<ShellOutput> ShellOutput::Create(napi_env env, napi_value js_cb) {
    if (!env || !js_cb) return nullptr;

    napi_threadsafe_function tsfn = nullptr;
    napi_value res_name = nullptr;
    napi_create_string_utf8(env, "ShellOutput", NAPI_AUTO_LENGTH, &res_name);
    napi_status st = napi_create_threadsafe_function(
        env, js_cb, nullptr, res_name,
        0,    // unlimited queue
        1,
        nullptr, nullptr, nullptr,
        OutputCallJs,
        &tsfn);
    if (st != napi_ok || !tsfn) {
        OH_LOG_ERROR(LOG_APP, "create output tsfn failed: %{public}d", (int)st);
        return nullptr;
    }

    std::unique_ptr<ShellOutput> out(new ShellOutput(env, tsfn));
    if (!out->InitTimer()) {
        return nullptr;
    }
    return out;
}

ShellOutput::ShellOutput(napi_env env, napi_threadsafe_function tsfn)
    : env_(env), tsfn_(tsfn) {}

bool ShellOutput::InitTimer() {
    uv_loop_t* loop = nullptr;
    napi_status st = napi_get_uv_event_loop(env_, &loop);
    if (st != napi_ok || !loop) {
        OH_LOG_ERROR(LOG_APP, "get uv loop failed: %{public}d", (int)st);
        return false;
    }
    timer_ = new uv_timer_t();
    if (uv_timer_init(loop, timer_) != 0) {
        OH_LOG_ERROR(LOG_APP, "uv_timer_init failed");
        delete timer_;
        timer_ = nullptr;
        return false;
    }
    timer_->data = this;
    return true;
}

ShellOutput::~ShellOutput() {
    // 最后一次 flush, 不再 schedule
    DoFlush();

    if (timer_) {
        uv_timer_stop(timer_);
        // close 是异步的, 回调里释放 timer 对象
        uv_close(reinterpret_cast<uv_handle_t*>(timer_),
                 [](uv_handle_t* h) {
                     delete reinterpret_cast<uv_timer_t*>(h);
                 });
        timer_ = nullptr;
    }
    if (tsfn_) {
        napi_release_threadsafe_function(tsfn_, napi_tsfn_release);
        tsfn_ = nullptr;
    }
}

void ShellOutput::Write(const std::string& data) {
    if (!tsfn_ || data.empty()) return;
    pending_ += data;
    if (pending_.size() >= kThreshold) {
        DoFlush();
    } else {
        ScheduleTimer();
    }
}

void ShellOutput::Flush() {
    DoFlush();
}

void ShellOutput::ScheduleTimer() {
    if (timer_pending_ || !timer_) return;
    int r = uv_timer_start(timer_, &ShellOutput::OnTimer, kFlushDelayMs, 0);
    if (r == 0) {
        timer_pending_ = true;
    } else {
        OH_LOG_WARN(LOG_APP, "uv_timer_start failed: %{public}d", r);
    }
}

void ShellOutput::OnTimer(uv_timer_t* h) {
    auto* self = static_cast<ShellOutput*>(h->data);
    if (!self) return;
    self->timer_pending_ = false;
    self->DoFlush();
}

void ShellOutput::DoFlush() {
    if (pending_.empty()) return;
    if (timer_pending_ && timer_) {
        uv_timer_stop(timer_);
        timer_pending_ = false;
    }
    auto* ev = new OutputEvent{std::move(pending_)};
    pending_.clear();
    napi_status st = napi_call_threadsafe_function(
        tsfn_, ev, napi_tsfn_blocking);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, "tsfn call failed: %{public}d", (int)st);
        delete ev;
    }
}

} // namespace shell