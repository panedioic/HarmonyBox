// plugin_manager.h
#pragma once
#include "napi/native_api.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include "egl_renderer.h"
#include <string>
#include <unordered_map>

class PluginManager {
public:
    static PluginManager* GetInstance();
    void Export(napi_env env, napi_value exports);

    // XComponent 回调入口
    static void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window);
    static void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window);
    static void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window);
    static void DispatchTouchEventCB(OH_NativeXComponent*, void*) {}

private:
    PluginManager() = default;
    EglRenderer renderer_;
    OH_NativeXComponent_Callback callback_{};
};