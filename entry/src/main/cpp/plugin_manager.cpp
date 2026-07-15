#include "plugin_manager.h"
#include <native_window/external_window.h>

#undef LOG_TAG
#define LOG_TAG "WL_Plugin"
#include <hilog/log.h>

PluginManager* PluginManager::GetInstance() {
    static PluginManager s;
    return &s;
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
    OH_LOG_INFO(LOG_APP, "PluginManager Export: callback registered for nxc=%{public}p", nxc);
}

// ★ 新: 从 ArkTS 调用. AppRunner.onLoad 里绑定.
void PluginManager::BindXComponentClient(const std::string& xcId,
                                          const std::string& clientId) {
    std::lock_guard<std::mutex> lk(mu_);
    // 检查已有 instance 中是否有 xcId 匹配 (通过 OH_NativeXComponent_GetXComponentId 拿)
    // 但 OnSurfaceCreated 时还没 xcId, 所以先记 pending
    pendingBind_[xcId] = clientId;
    OH_LOG_INFO(LOG_APP, "BindXComponentClient xcId=%{public}s cid=%{public}s (pending)",
                xcId.c_str(), clientId.c_str());

    // 也尝试立即绑定 (如果 XComponent 已经 create 过)
    for (auto& kv : insts_) {
        char id[128] = {0};
        uint64_t idSize = sizeof(id);
        if (OH_NativeXComponent_GetXComponentId(kv.first, id, &idSize) == 0) {
            if (xcId == id) {
                kv.second->clientId = clientId;
                if (kv.second->renderer) {
                    kv.second->renderer->SetClientId(clientId);
                }
                OH_LOG_INFO(LOG_APP, "BindXComponentClient bound existing xcId=%{public}s",
                            xcId.c_str());
                break;
            }
        }
    }
}

PluginManager::Instance* PluginManager::FindByComponent(OH_NativeXComponent* c) {
    auto it = insts_.find(c);
    return (it == insts_.end()) ? nullptr : it->second.get();
}

PluginManager::Instance* PluginManager::FindOrCreateByComponent(OH_NativeXComponent* c) {
    auto it = insts_.find(c);
    if (it != insts_.end()) return it->second.get();
    auto inst = std::make_unique<Instance>();

    // 取 xcId
    char id[128] = {0};
    uint64_t idSize = sizeof(id);
    OH_NativeXComponent_GetXComponentId(c, id, &idSize);
    inst->xcId = id;

    // 查 pending 表
    auto pit = pendingBind_.find(inst->xcId);
    if (pit != pendingBind_.end()) {
        inst->clientId = pit->second;
        pendingBind_.erase(pit);
    }

    inst->renderer = std::make_unique<EglRenderer>();
    if (!inst->clientId.empty()) {
        inst->renderer->SetClientId(inst->clientId);
    }
    Instance* raw = inst.get();
    insts_[c] = std::move(inst);
    OH_LOG_INFO(LOG_APP, "FindOrCreate xcId=%{public}s cid=%{public}s",
                raw->xcId.c_str(), raw->clientId.c_str());
    return raw;
}

void PluginManager::OnSurfaceCreatedCB(OH_NativeXComponent* c, void* window) {
    auto* self = GetInstance();
    std::lock_guard<std::mutex> lk(self->mu_);
    Instance* inst = self->FindOrCreateByComponent(c);
    if (!inst || !inst->renderer) return;

    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(c, window, &w, &h);
    inst->renderer->Init(reinterpret_cast<OHNativeWindow*>(window),
                         (int)w, (int)h);
}

void PluginManager::OnSurfaceChangedCB(OH_NativeXComponent* c, void* window) {
    auto* self = GetInstance();
    std::lock_guard<std::mutex> lk(self->mu_);
    Instance* inst = self->FindByComponent(c);
    if (!inst || !inst->renderer) return;

    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(c, window, &w, &h);
    inst->renderer->OnResize((int)w, (int)h);
}

void PluginManager::OnSurfaceDestroyedCB(OH_NativeXComponent* c, void*) {
    auto* self = GetInstance();
    std::unique_ptr<Instance> victim;
    {
        std::lock_guard<std::mutex> lk(self->mu_);
        auto it = self->insts_.find(c);
        if (it == self->insts_.end()) return;
        victim = std::move(it->second);
        self->insts_.erase(it);
    }
    // 出锁再 Shutdown, 因为 Shutdown 里要 join 渲染线程, 别死锁
    if (victim && victim->renderer) {
        victim->renderer->Shutdown();
    }
}

void PluginManager::DispatchTouchEventCB(OH_NativeXComponent*, void*) {
    // 触摸暂不用
}