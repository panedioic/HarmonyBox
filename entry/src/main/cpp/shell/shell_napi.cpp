#include "shell_napi.h"
#include "shell_engine.h"

#include <string>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "HBox_NAPI_Shell"

namespace shell {

namespace {

std::string ReadStringValue(napi_env env, napi_value v) {
    if (!v) return {};
    napi_valuetype t;
    napi_typeof(env, v, &t);
    if (t != napi_string) return {};
    size_t len = 0;
    napi_get_value_string_utf8(env, v, nullptr, 0, &len);
    std::string out(len, '\0');
    size_t copied = 0;
    napi_get_value_string_utf8(env, v, out.data(), len + 1, &copied);
    out.resize(copied);
    return out;
}

int32_t ReadInt32Value(napi_env env, napi_value v, int32_t fb) {
    if (!v) return fb;
    napi_valuetype t;
    napi_typeof(env, v, &t);
    if (t != napi_number) return fb;
    int32_t out = fb;
    napi_get_value_int32(env, v, &out);
    return out;
}

std::string ReadStringProp(napi_env env, napi_value obj, const char* name) {
    napi_value v = nullptr;
    if (napi_get_named_property(env, obj, name, &v) != napi_ok) return {};
    return ReadStringValue(env, v);
}

int32_t ReadInt32Prop(napi_env env, napi_value obj, const char* name, int32_t fb) {
    napi_value v = nullptr;
    if (napi_get_named_property(env, obj, name, &v) != napi_ok) return fb;
    return ReadInt32Value(env, v, fb);
}

napi_value MakeBool(napi_env env, bool b) {
    napi_value r = nullptr;
    napi_get_boolean(env, b, &r);
    return r;
}

} // anonymous namespace

// shellInit(opts: {homeDir,logDir,cols,rows}, outputCb: (data:string)=>void): boolean
napi_value ShellInitNapi(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        OH_LOG_ERROR(LOG_APP, "shellInit: need 2 args (opts, outputCb)");
        return MakeBool(env, false);
    }

    napi_valuetype t;
    napi_typeof(env, args[0], &t);
    if (t != napi_object) {
        OH_LOG_ERROR(LOG_APP, "shellInit: arg0 must be object");
        return MakeBool(env, false);
    }
    napi_typeof(env, args[1], &t);
    if (t != napi_function) {
        OH_LOG_ERROR(LOG_APP, "shellInit: arg1 must be function");
        return MakeBool(env, false);
    }

    ShellConfig cfg;
    cfg.home_dir = ReadStringProp(env, args[0], "homeDir");
    cfg.log_dir  = ReadStringProp(env, args[0], "logDir");
    cfg.cols     = ReadInt32Prop(env, args[0], "cols", 80);
    cfg.rows     = ReadInt32Prop(env, args[0], "rows", 24);

    bool ok = ShellEngine::Instance().Init(env, cfg, args[1]);
    return MakeBool(env, ok);
}

// shellInput(data: string): void
napi_value ShellInputNapi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;
    std::string data = ReadStringValue(env, args[0]);
    if (!data.empty()) {
        ShellEngine::Instance().Input(data);
    }
    return nullptr;
}

// shellResize(cols: number, rows: number): void
napi_value ShellResizeNapi(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int cols = (argc >= 1) ? ReadInt32Value(env, args[0], 0) : 0;
    int rows = (argc >= 2) ? ReadInt32Value(env, args[1], 0) : 0;
    ShellEngine::Instance().Resize(cols, rows);
    return nullptr;
}

// shellShutdown(): void
napi_value ShellShutdownNapi(napi_env env, napi_callback_info /*info*/) {
    ShellEngine::Instance().Shutdown();
    return nullptr;
}

} // namespace shell