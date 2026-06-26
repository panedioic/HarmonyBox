#include "fs_utils.h"
#include "napi_utils.h"

#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <string>

#undef LOG_TAG
#define LOG_TAG "WL_HBox"
#include <hilog/log.h>

namespace fsutil {

void EnsureExecutable(const char* path) {
    if (!path || !*path) return;
    if (access(path, X_OK) != 0) {
        chmod(path, 0755);
    }
}

int ChmodDirFiles(const char* dir, mode_t mode) {
    if (!dir || !*dir) return 0;
    DIR* d = opendir(dir);
    if (!d) return 0;
    int count = 0;
    struct dirent* e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        std::string p = std::string(dir) + "/" + e->d_name;
        if (chmod(p.c_str(), mode) == 0) count++;
    }
    closedir(d);
    return count;
}

napi_value ChmodDirFilesNapi(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string dir = napiutil::GetStringArg(env, args[0]);
    int count = ChmodDirFiles(dir.c_str(), 0755);
    OH_LOG_INFO(LOG_APP, "chmod %{public}d files under %{public}s", count, dir.c_str());
    napi_value r;
    napi_create_int32(env, count, &r);
    return r;
}

bool EnsureBox64TmpDir() {
    const char* kBox64TmpDir = "/data/storage/el2/base/cache/box64-tmp";
    mode_t kDirMode = 0700;
    struct stat st;
    // 1. 检查路径是否存在
    if (stat(kBox64TmpDir, &st) != 0) {
        // 不存在 → 创建
        if (errno != ENOENT) {
            OH_LOG_ERROR(LOG_APP,
                         "stat(%{public}s) failed: %{public}s",
                         kBox64TmpDir, strerror(errno));
            return false;
        }
        if (mkdir(kBox64TmpDir, kDirMode) != 0) {
            OH_LOG_ERROR(LOG_APP,
                         "mkdir(%{public}s, 0700) failed: %{public}s",
                         kBox64TmpDir, strerror(errno));
            return false;
        }
        OH_LOG_INFO(LOG_APP,
                    "box64 tmp dir created: %{public}s", kBox64TmpDir);
        return true;
    }
    // 2. 已存在 → 校验是否为目录
    if (!S_ISDIR(st.st_mode)) {
        OH_LOG_ERROR(LOG_APP,
                     "%{public}s exists but is not a directory",
                     kBox64TmpDir);
        return false;
    }
    // 3. 校验权限并修正
    mode_t current_mode = st.st_mode & 0777;
    if (current_mode != kDirMode) {
        if (chmod(kBox64TmpDir, kDirMode) != 0) {
            OH_LOG_ERROR(LOG_APP,
                         "chmod(%{public}s, 0700) failed: %{public}s",
                         kBox64TmpDir, strerror(errno));
            return false;
        }
        OH_LOG_INFO(LOG_APP,
                    "box64 tmp dir permissions fixed: 0%{public}o → 0%{public}o",
                    current_mode, kDirMode);
    } else {
        OH_LOG_INFO(LOG_APP,
                    "box64 tmp dir already OK: %{public}s (0%{public}o)",
                    kBox64TmpDir, current_mode);
    }
    return true;
}

napi_value EnsureBox64TmpDirNapi(napi_env env, napi_callback_info info) {
    bool ok = EnsureBox64TmpDir();
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

} // namespace fsutil