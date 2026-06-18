#include "napi_utils.h"

namespace napiutil {

std::string GetStringArg(napi_env env, napi_value v) {
    if (!v) return {};
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return {};
    std::string out(len, '\0');
    size_t copied = 0;
    napi_get_value_string_utf8(env, v, out.data(), len + 1, &copied);
    out.resize(copied);
    return out;
}

std::vector<std::string> GetStringArrayArg(napi_env env, napi_value v) {
    std::vector<std::string> out;
    if (!v) return out;
    bool isArr = false;
    if (napi_is_array(env, v, &isArr) != napi_ok || !isArr) return out;
    uint32_t n = 0;
    napi_get_array_length(env, v, &n);
    out.reserve(n);
    for (uint32_t i = 0; i < n; ++i) {
        napi_value el = nullptr;
        napi_get_element(env, v, i, &el);
        out.push_back(GetStringArg(env, el));
    }
    return out;
}

void NoArgTsfnCallJs(napi_env env, napi_value jsCb, void*, void*) {
    if (env && jsCb) {
        napi_value undef;
        napi_get_undefined(env, &undef);
        napi_call_function(env, undef, jsCb, 0, nullptr, nullptr);
    }
}

} // namespace napiutil