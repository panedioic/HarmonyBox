#pragma once
#include <wayland-server-core.h>
#include <atomic>
#include <cstdint>
#include <string>
#include <sys/types.h>

struct ClientContext {
    std::string   id;             // "c1", "c2", ... 上抛给 ArkTS
    wl_client*    client = nullptr;
    pid_t         pid = -1;

    // per-client 主 surface 选举
    wl_resource*  mainSurface  = nullptr;
    std::atomic<bool> firstCommit{false};

    // 尺寸通知去抖
    int lastNotifiedW = -1;
    int lastNotifiedH = -1;

    // wl_listener trampoline: destroy 事件. 通过 wl_container_of 反查 ctx
    wl_listener destroyListener{};

    bool MarkFirstCommit() {
        bool expected = false;
        return firstCommit.compare_exchange_strong(expected, true);
    }
};