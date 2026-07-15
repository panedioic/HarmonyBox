#pragma once
#include "napi/native_api.h"

namespace clientnapi {

napi_value SetStateCallback (napi_env env, napi_callback_info info);
napi_value StartWaylandServer(napi_env env, napi_callback_info info);

napi_value LaunchClient (napi_env env, napi_callback_info info);
napi_value StopClient   (napi_env env, napi_callback_info info);
napi_value StopAll      (napi_env env, napi_callback_info info);

napi_value ExecCapture  (napi_env env, napi_callback_info info);
napi_value LaunchCli    (napi_env env, napi_callback_info info);
napi_value StopCli      (napi_env env, napi_callback_info info);
napi_value SetCliCallback(napi_env env, napi_callback_info info);

napi_value SetClientConnectCallback(napi_env env, napi_callback_info info);
napi_value SetClientDisconnectCallback(napi_env env, napi_callback_info info);

} // namespace clientnapi