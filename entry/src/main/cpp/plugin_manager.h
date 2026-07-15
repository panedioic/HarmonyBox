#pragma once
#include <napi/native_api.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include "egl_renderer.h"
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

class PluginManager {
public:
    static PluginManager* GetInstance();
    void Export(napi_env env, napi_value exports);

    // 由 ArkTS 调用: 绑定 xcId ↔ clientId
    void BindXComponentClient(const std::string& xcId,
                              const std::string& clientId);

    static void OnSurfaceCreatedCB(OH_NativeXComponent* c, void* window);
    static void OnSurfaceChangedCB(OH_NativeXComponent* c, void* window);
    static void OnSurfaceDestroyedCB(OH_NativeXComponent* c, void* window);
    static void DispatchTouchEventCB(OH_NativeXComponent* c, void* window);

private:
    struct Instance {
        std::string  xcId;
        std::string  clientId;
        std::unique_ptr<EglRenderer> renderer;
    };

    Instance* FindByComponent(OH_NativeXComponent* c);
    Instance* FindOrCreateByComponent(OH_NativeXComponent* c);

    OH_NativeXComponent_Callback callback_{};
    std::mutex mu_;
    std::unordered_map<OH_NativeXComponent*, std::unique_ptr<Instance>> insts_;
    // 待绑定: XComponent 尚未 OnSurfaceCreated 时先记住 xcId→clientId
    std::unordered_map<std::string, std::string> pendingBind_;
};