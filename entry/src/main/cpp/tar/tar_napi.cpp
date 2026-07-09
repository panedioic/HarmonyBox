#include "tar_napi.h"
#include "tar_reader.h"
#include "tar_writer.h"

#include <string>
#include <thread>

namespace tar {

namespace {

std::string ReadStringArg(napi_env env, napi_value v) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) return "";
    std::string s(len, '\0');
    size_t got = 0;
    napi_get_value_string_utf8(env, v, s.data(), len + 1, &got);
    return s;
}

napi_value BuildResult(napi_env env, bool ok, int a, int b,
                       const std::string& err) {
    napi_value o = nullptr;
    napi_create_object(env, &o);
    napi_value okv, av, bv, ev;
    napi_get_boolean(env, ok, &okv);
    napi_create_int32(env, a, &av);
    napi_create_int32(env, b, &bv);
    napi_create_string_utf8(env, err.c_str(), err.size(), &ev);
    napi_set_named_property(env, o, "ok",       okv);
    napi_set_named_property(env, o, "count",    av);
    napi_set_named_property(env, o, "skipped",  bv);
    napi_set_named_property(env, o, "error",    ev);
    return o;
}

// 异步 worker 通用
struct Job {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string archive;
    std::string dir;
    bool is_extract = false;
    // 结果
    bool ok = false;
    int a = 0, b = 0;
    std::string err;
};

void ExecuteWork(napi_env, void* data) {
    Job* j = static_cast<Job*>(data);
    if (j->is_extract) {
        ExtractResult r = Extract(j->archive, j->dir);
        j->ok = r.ok; j->a = r.extracted; j->b = r.skipped; j->err = r.error;
    } else {
        CreateResult r = Create(j->archive, j->dir);
        j->ok = r.ok; j->a = r.included; j->b = r.skipped; j->err = r.error;
    }
}

void CompleteWork(napi_env env, napi_status /*status*/, void* data) {
    Job* j = static_cast<Job*>(data);
    napi_value result = BuildResult(env, j->ok, j->a, j->b, j->err);
    if (j->ok || j->err.empty()) {
        napi_resolve_deferred(env, j->deferred, result);
    } else {
        // 也 resolve, 由调用方看 ok/error 字段。避免 throw 破坏 promise chain
        napi_resolve_deferred(env, j->deferred, result);
    }
    napi_delete_async_work(env, j->work);
    delete j;
}

napi_value RunAsync(napi_env env, const std::string& archive,
                    const std::string& dir, bool is_extract) {
    Job* j = new Job();
    j->archive = archive;
    j->dir = dir;
    j->is_extract = is_extract;

    napi_value promise = nullptr;
    napi_create_promise(env, &j->deferred, &promise);
    napi_value name = nullptr;
    napi_create_string_utf8(env,
        is_extract ? "TarExtract" : "TarCreate", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name,
        ExecuteWork, CompleteWork, j, &j->work);
    napi_queue_async_work(env, j->work);
    return promise;
}

}  // anonymous namespace

// tarExtract(archive, destDir): Promise<{ok, count, skipped, error}>
napi_value TarExtractNapi(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "tarExtract(archive, destDir)");
        return nullptr;
    }
    return RunAsync(env,
                    ReadStringArg(env, args[0]),
                    ReadStringArg(env, args[1]),
                    true);
}

// tarCreate(archive, srcDir): Promise<{ok, count, skipped, error}>
napi_value TarCreateNapi(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "tarCreate(archive, srcDir)");
        return nullptr;
    }
    return RunAsync(env,
                    ReadStringArg(env, args[0]),
                    ReadStringArg(env, args[1]),
                    false);
}

}  // namespace tar