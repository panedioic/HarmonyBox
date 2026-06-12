#pragma once
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <string>
#include <thread>
#include <mutex>
#include <vector>
#include <functional>
#include <atomic>
#include <cstdint>

class WaylandServer {
public:
    using StateCb = std::function<void(const char*)>;
    static WaylandServer* GetInstance();
    bool Start(const std::string& socketPath);
    void Stop();
    bool TakeLatestFrame(std::vector<uint8_t>& outPixels, int& w, int& h);
    void ResetFirstCommit() { firstCommit_ = false; }
    
    void SetStateCallback(StateCb cb) { stateCb_ = std::move(cb); }
    void FireState(const char* s) { if (stateCb_) stateCb_(s); }
    bool MarkFirstCommit() {
        bool expected = false;
        return firstCommit_.compare_exchange_strong(expected, true);
    }

    static void compositor_bind(wl_client*, void*, uint32_t, uint32_t);
    static void compositor_create_surface(wl_client*, wl_resource*, uint32_t);
    static void compositor_create_region(wl_client*, wl_resource*, uint32_t);

    static void surface_attach(wl_client*, wl_resource*, wl_resource*, int32_t, int32_t);
    static void surface_commit(wl_client*, wl_resource*);
    static void surface_destroy(wl_client*, wl_resource*);
    static void surface_damage(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t);
    static void surface_frame(wl_client*, wl_resource*, uint32_t);
    static void surface_set_opaque_region(wl_client*, wl_resource*, wl_resource*) {}
    static void surface_set_input_region(wl_client*, wl_resource*, wl_resource*) {}
    static void surface_set_buffer_transform(wl_client*, wl_resource*, int32_t) {}
    static void surface_set_buffer_scale(wl_client*, wl_resource*, int32_t) {}
    static void surface_damage_buffer(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}
    static void surface_offset(wl_client*, wl_resource*, int32_t, int32_t) {}

    static void region_destroy(wl_client*, wl_resource*) {}
    static void region_add(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}
    static void region_subtract(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}

private:
    WaylandServer() = default;
    void Loop();

    wl_display* display_ = nullptr;
    std::thread loopThread_;
    std::atomic<bool> running_{false};

    std::mutex frameMutex_;
    std::vector<uint8_t> latestPixels_;
    int latestW_ = 0;
    int latestH_ = 0;
    std::atomic<bool> dirty_{false};
    
    StateCb stateCb_;
    std::atomic<bool> firstCommit_{false};
};

struct SurfaceState {
    wl_resource* surface = nullptr;
    wl_resource* pendingBuffer = nullptr;
    wl_resource* currentBuffer = nullptr;
    std::vector<wl_resource*> frameCallbacks;
};