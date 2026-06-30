#ifndef HBOX_SHELL_OUTPUT_H
#define HBOX_SHELL_OUTPUT_H

#include <memory>
#include <string>

#include <uv.h>
#include "napi/native_api.h"

namespace shell {

// 输出通道: pending 缓冲 + 阈值/定时双触发 flush
class ShellOutput {
public:
    static std::unique_ptr<ShellOutput> Create(napi_env env, napi_value js_cb);
    ~ShellOutput();

    void Write(const std::string& data);
    void Flush();   // 立即 flush, 供 Shutdown 等场景

private:
    ShellOutput(napi_env env, napi_threadsafe_function tsfn);
    ShellOutput(const ShellOutput&) = delete;
    ShellOutput& operator=(const ShellOutput&) = delete;

    bool InitTimer();
    void ScheduleTimer();
    void DoFlush();
    static void OnTimer(uv_timer_t* h);

    napi_env env_ = nullptr;
    napi_threadsafe_function tsfn_ = nullptr;
    uv_timer_t* timer_ = nullptr;   // heap, close 回调里 delete
    bool timer_pending_ = false;

    std::string pending_;

    static constexpr size_t   kThreshold     = 4096;
    static constexpr uint64_t kFlushDelayMs  = 16;
};

} // namespace shell

#endif