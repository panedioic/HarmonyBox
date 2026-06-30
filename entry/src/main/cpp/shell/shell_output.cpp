#include "shell_output.h"

#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "HBox_NAPI_Shell_SOutput"

namespace shell {

namespace {

struct OutputEvent {
    std::string data;
};

// tsfn 的 call_js_cb：在 JS 线程被调用，把字节传给 ArkTS 回调
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
        0,                  // max_queue_size: unlimited
        1,                  // initial thread count
        nullptr, nullptr, nullptr,
        OutputCallJs,
        &tsfn);
    if (st != napi_ok || !tsfn) {
        OH_LOG_ERROR(LOG_APP, "create output tsfn failed: %{public}d", (int)st);
        return nullptr;
    }
    return std::unique_ptr<ShellOutput>(new ShellOutput(tsfn));
}

ShellOutput::ShellOutput(napi_threadsafe_function tsfn) : tsfn_(tsfn) {}

ShellOutput::~ShellOutput() {
    if (tsfn_) {
        napi_release_threadsafe_function(tsfn_, napi_tsfn_release);
        tsfn_ = nullptr;
    }
}

void ShellOutput::Write(const std::string& data) {
    if (!tsfn_ || data.empty()) return;
    auto* ev = new OutputEvent{data};
    napi_status st = napi_call_threadsafe_function(tsfn_, ev, napi_tsfn_blocking);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, "shell output tsfn call failed: %{public}d", (int)st);
        delete ev;
    }
}

} // namespace shell