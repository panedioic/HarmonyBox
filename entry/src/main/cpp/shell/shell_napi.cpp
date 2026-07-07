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

// shellSetSystemEnv(vars: string[]): void
// 每个元素形如 "KEY=VAL". 只能在 shellInit 之后调用.
napi_value ShellSetSystemEnvNapi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;

    bool is_arr = false;
    napi_is_array(env, args[0], &is_arr);
    if (!is_arr) return nullptr;

    uint32_t len = 0;
    napi_get_array_length(env, args[0], &len);

    auto& engine = ShellEngine::Instance();
    if (!engine.IsInitialized()) return nullptr;

    for (uint32_t i = 0; i < len; ++i) {
        napi_value item = nullptr;
        napi_get_element(env, args[0], i, &item);
        std::string s = ReadStringValue(env, item);
        size_t eq = s.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        engine.InjectSystemEnv(s.substr(0, eq), s.substr(eq + 1));
    }
    return nullptr;
}

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
    cfg.env_persist_path = ReadStringProp(env, args[0], "envPersistPath");

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

// shellRegister(name: string, meta: {desc,usage,streaming}, handler: fn): boolean
napi_value ShellRegisterNapi(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        OH_LOG_ERROR(LOG_APP, "shellRegister: need 3 args");
        return MakeBool(env, false);
    }
    std::string name = ReadStringValue(env, args[0]);
    if (name.empty()) return MakeBool(env, false);

    napi_valuetype vt;
    napi_typeof(env, args[1], &vt);
    if (vt != napi_object) return MakeBool(env, false);
    napi_typeof(env, args[2], &vt);
    if (vt != napi_function) return MakeBool(env, false);

    std::string desc  = ReadStringProp(env, args[1], "desc");
    std::string usage = ReadStringProp(env, args[1], "usage");

    napi_value stv = nullptr;
    napi_get_named_property(env, args[1], "streaming", &stv);
    bool streaming = false;
    if (stv) {
        napi_valuetype t;
        napi_typeof(env, stv, &t);
        if (t == napi_boolean) napi_get_value_bool(env, stv, &streaming);
    }

    napi_threadsafe_function tsfn = nullptr;
    napi_value res_name = nullptr;
    napi_create_string_utf8(env, ("ShellExtCmd:" + name).c_str(),
                            NAPI_AUTO_LENGTH, &res_name);
    napi_status st = napi_create_threadsafe_function(
        env, args[2], nullptr, res_name,
        0, 1,
        nullptr, nullptr, nullptr,
        ExternalCallJs,
        &tsfn);
    if (st != napi_ok || !tsfn) {
        OH_LOG_ERROR(LOG_APP, "shellRegister tsfn create failed: %{public}d",
                     (int)st);
        return MakeBool(env, false);
    }

    ShellEngine::Instance().Dispatcher().RegisterExternal(
        name, desc, usage, streaming, tsfn);
    return MakeBool(env, true);
}

napi_value ShellUnregisterNapi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return MakeBool(env, false);
    std::string name = ReadStringValue(env, args[0]);
    if (name.empty()) return MakeBool(env, false);
    bool ok = ShellEngine::Instance().Dispatcher().UnregisterExternal(name);
    return MakeBool(env, ok);
}

// shellCommandDone(code: number): void
napi_value ShellCommandDoneNapi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t code = (argc >= 1) ? ReadInt32Value(env, args[0], 0) : 0;
    ShellEngine::Instance().CommandDone(code);
    return nullptr;
}

// shellStreamWrite(data: string): void
napi_value ShellStreamWriteNapi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;
    std::string data = ReadStringValue(env, args[0]);
    ShellEngine::Instance().StreamWrite(data);
    return nullptr;
}

} // namespace shell