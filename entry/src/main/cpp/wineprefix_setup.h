#pragma once
#include "napi/native_api.h"
#include <string>

namespace wineprefix {

// 预布置 wineprefix 结构, 把 wine builtin DLL 物理拷贝到
// dosdevices/c:/windows/system32/, 绕过 HAP 沙箱禁 symlink 的限制.
//
// wineprefix:  e.g. "/data/storage/el2/base/haps/entry/files/wineprefix"
// wine_root:   e.g. "/data/storage/el2/base/haps/entry/files/wine"
//
// 幂等: 标记文件 .box64_setup_done 存在时立即返回 true.
// 返回: true 成功; false 失败 (调用方应放弃后续 wineboot).
bool SetupWinePrefix(const std::string& wineprefix,
                     const std::string& wine_root);

// napi 壳: setupWinePrefix(wineprefix: string, wineRoot: string): boolean
napi_value SetupWinePrefixNapi(napi_env env, napi_callback_info info);

} // namespace wineprefix