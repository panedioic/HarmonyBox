// plugin_manager.cpp
#include "plugin_manager.h"
#include <native_window/external_window.h>

#undef LOG_TAG
#define LOG_TAG "WL_Plugin"
#include <hilog/log.h>

PluginManager* PluginManager::GetInstance() {
    static PluginManager s; return &s;
}

void PluginManager::Export(napi_env env, napi_value exports) {
    napi_value xcVal = nullptr;
    napi_status st = napi_get_named_property(env, exports,
        OH_NATIVE_XCOMPONENT_OBJ, &xcVal);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, "no XComponent obj on exports");
        return;
    }
    OH_NativeXComponent* nxc = nullptr;
    if (napi_unwrap(env, xcVal, reinterpret_cast<void**>(&nxc)) != napi_ok || !nxc) {
        OH_LOG_WARN(LOG_APP, "napi_unwrap NativeXComponent failed");
        return;
    }
    callback_.OnSurfaceCreated   = OnSurfaceCreatedCB;
    callback_.OnSurfaceChanged   = OnSurfaceChangedCB;
    callback_.OnSurfaceDestroyed = OnSurfaceDestroyedCB;
    callback_.DispatchTouchEvent = DispatchTouchEventCB;
    OH_NativeXComponent_RegisterCallback(nxc, &callback_);
}

void PluginManager::OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
    auto* self = GetInstance();
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    self->renderer_.Init(reinterpret_cast<OHNativeWindow*>(window), (int)w, (int)h);
}

void PluginManager::OnSurfaceChangedCB(OH_NativeXComponent*, void*) {
    // 这里可以做尺寸变化重建 surface，先忽略
}

void PluginManager::OnSurfaceDestroyedCB(OH_NativeXComponent*, void*) {
    GetInstance()->renderer_.Shutdown();
}