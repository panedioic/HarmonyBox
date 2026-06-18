#pragma once
#include "napi/native_api.h"
#include <string>
#include <vector>

namespace napiutil {

std::string GetStringArg(napi_env env, napi_value v);
std::vector<std::string> GetStringArrayArg(napi_env env, napi_value v);

// 公共的"无参 JS 回调"call_js 实现,给所有 () => void 类型的 tsfn 复用
void NoArgTsfnCallJs(napi_env env, napi_value jsCb, void*, void*);

} // namespace napiutil