#ifndef HBOX_TAR_NAPI_H
#define HBOX_TAR_NAPI_H

#include "napi/native_api.h"

namespace tar {

napi_value TarExtractNapi(napi_env env, napi_callback_info info);
napi_value TarCreateNapi (napi_env env, napi_callback_info info);

}  // namespace tar

#endif