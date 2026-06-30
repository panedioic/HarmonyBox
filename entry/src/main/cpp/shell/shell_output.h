#ifndef HBOX_SHELL_OUTPUT_H
#define HBOX_SHELL_OUTPUT_H

#include <memory>
#include <string>
#include "napi/native_api.h"

namespace shell {

// 把字节流推回 ArkTS 端的 javaScriptProxy 输出回调。
// M1: 立刻 flush，不做批量。批量化放到 M4。
class ShellOutput {
public:
    static std::unique_ptr<ShellOutput> Create(napi_env env, napi_value js_cb);
    ~ShellOutput();

    void Write(const std::string& data);

private:
    explicit ShellOutput(napi_threadsafe_function tsfn);
    ShellOutput(const ShellOutput&) = delete;
    ShellOutput& operator=(const ShellOutput&) = delete;

    napi_threadsafe_function tsfn_ = nullptr;
};

} // namespace shell

#endif