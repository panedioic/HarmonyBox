#ifndef HBOX_SHELL_NAPI_H
#define HBOX_SHELL_NAPI_H

#include "napi/native_api.h"

namespace shell {

napi_value ShellInitNapi(napi_env env, napi_callback_info info);
napi_value ShellInputNapi(napi_env env, napi_callback_info info);
napi_value ShellResizeNapi(napi_env env, napi_callback_info info);
napi_value ShellShutdownNapi(napi_env env, napi_callback_info info);
napi_value ShellSetSystemEnvNapi(napi_env env, napi_callback_info info);

} // namespace shell

#endif