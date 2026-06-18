#pragma once
#include "napi/native_api.h"
#include <sys/types.h>

namespace fsutil {

// access(X_OK) 失败则 chmod 0755。空路径直接返回。
void EnsureExecutable(const char* path);

// chmod 目录下所有非点开头的条目,返回成功的个数。
int ChmodDirFiles(const char* dir, mode_t mode);

// napi 壳:chmodDirFiles(dir: string): number
napi_value ChmodDirFilesNapi(napi_env env, napi_callback_info info);

} // namespace fsutil