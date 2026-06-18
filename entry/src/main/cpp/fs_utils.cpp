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

} // namespace fsutil