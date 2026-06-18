#pragma once
#include "napi/native_api.h"

namespace iwnapi {

// 键鼠
napi_value SendKey         (napi_env env, napi_callback_info info);
napi_value SendModifiers   (napi_env env, napi_callback_info info);
napi_value SendMouseMove   (napi_env env, napi_callback_info info);
napi_value SendMouseButton (napi_env env, napi_callback_info info);
napi_value SendMouseAxis   (napi_env env, napi_callback_info info);
napi_value SendMouseHover  (napi_env env, napi_callback_info info);

// 窗口事件
napi_value SetSizeCallback       (napi_env env, napi_callback_info info);
napi_value GetLatestSize         (napi_env env, napi_callback_info info);
napi_value SetMoveCallback       (napi_env env, napi_callback_info info);
napi_value SetMaximizeCallback   (napi_env env, napi_callback_info info);
napi_value SetUnmaximizeCallback (napi_env env, napi_callback_info info);
napi_value SetResizeCallback     (napi_env env, napi_callback_info info);
napi_value RequestClientResize   (napi_env env, napi_callback_info info);
napi_value SetMinimizeCallback   (napi_env env, napi_callback_info info);

} // namespace iwnapi