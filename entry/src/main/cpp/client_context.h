#pragma once
#include <wayland-server-core.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <sys/types.h>
#include <vector>

struct ClientContext {
    std::string   id;             // "c1", "c2", ... 上抛给 ArkTS
    std::string   instanceId;   // ★ 新: 从子进程 env 读到的
    wl_client*    client = nullptr;
    pid_t         pid = -1;

    // per-client 主 surface 选举
    wl_resource*  mainSurface  = nullptr;
    std::atomic<bool> firstCommit{false};

    // 尺寸通知去抖
    int lastNotifiedW = -1;
    int lastNotifiedH = -1;

    // ★ 新增: per-client 帧缓冲
    std::mutex           frameMutex;
    std::vector<uint8_t> latestPixels;
    int  latestW = 0;
    int  latestH = 0;
    std::atomic<bool> dirty{false};

    // ★ 新: per-client 焦点
    wl_resource* kbFocus  = nullptr;
    wl_resource* ptrFocus = nullptr;
    
    // wl_listener trampoline: destroy 事件. 通过 wl_container_of 反查 ctx
    wl_listener destroyListener{};

    bool MarkFirstCommit() {
        bool expected = false;
        return firstCommit.compare_exchange_strong(expected, true);
    }
    
    wl_resource* activeToplevel   = nullptr;
    wl_resource* activeXdgSurface = nullptr;
};