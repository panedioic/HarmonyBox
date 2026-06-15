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

struct SeatState {
    wl_resource* seatRes = nullptr;
    std::vector<wl_resource*> keyboards;
    std::vector<wl_resource*> pointers;
};

class WaylandServer {
public:
    using StateCb = std::function<void(const char*)>;
    static WaylandServer* GetInstance();
    bool Start(const std::string& socketPath);
    void Stop();
    bool TakeLatestFrame(std::vector<uint8_t>& outPixels, int& w, int& h);
    void ResetFirstCommit();
    
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
    
    // I/O
    void DispatchKey(uint32_t evdevCode, bool pressed);
    void DispatchModifiers(uint32_t dep, uint32_t lat, uint32_t loc, uint32_t group);
    void DispatchMouseMotion(double x, double y);
    void DispatchMouseButton(uint32_t button, bool pressed);
    void DispatchMouseAxis(double dx, double dy);
    void DispatchMouseEnter(double x, double y);
    void DispatchMouseLeave();
    void SetKeyboardFocus(wl_resource* surface);
    void SetPointerFocus(wl_resource* surface);
    static void seat_bind(wl_client*, void*, uint32_t, uint32_t);
    static void seat_get_pointer(wl_client*, wl_resource*, uint32_t);
    static void seat_get_keyboard(wl_client*, wl_resource*, uint32_t);
    static void seat_get_touch(wl_client*, wl_resource*, uint32_t);
    static void seat_release(wl_client*, wl_resource*);
    static void keyboard_release(wl_client*, wl_resource*);
    static void pointer_release(wl_client*, wl_resource*);
    static void pointer_set_cursor(wl_client*, wl_resource*, uint32_t,
                                   wl_resource*, int32_t, int32_t);
    

    // fix window size
    void SetSizeCallback(std::function<void(int,int)> cb) { sizeCallback_ = std::move(cb); }
    void GetLatestSize(int& w, int& h);

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

    // I/O
    SeatState seat_;
    wl_resource* kbFocus_ = nullptr;
    wl_resource* ptrFocus_ = nullptr;
    int keymapFd_ = -1;
    size_t keymapSize_ = 0;
    bool BuildKeymapFd();
    uint32_t NextSerial();
    uint32_t NowMs();

    wl_resource* mainSurface_ = nullptr; // 追踪主渲染窗口
    
    // fix window size
    std::function<void(int,int)> sizeCallback_;
    int lastNotifiedW_ = -1;
    int lastNotifiedH_ = -1;
};

struct SurfaceState {
    wl_resource* surface = nullptr;
    wl_resource* pendingBuffer = nullptr;
    wl_resource* currentBuffer = nullptr;
    std::vector<wl_resource*> frameCallbacks;
};