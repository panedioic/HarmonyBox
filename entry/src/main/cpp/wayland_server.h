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
#include <map>

#include "client_context.h"

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
    bool TakeLatestFrame(const std::string& clientId, std::vector<uint8_t>& outPixels, int& w, int& h);
    void ResetFirstCommit();
    
    void SetStateCallback(StateCb cb) { stateCb_ = std::move(cb); }
    void FireState(const char* s) { if (stateCb_) stateCb_(s); }

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
    void DispatchKey(const std::string& clientId, uint32_t evdevCode, bool pressed);
    void DispatchModifiers(const std::string& clientId, uint32_t dep, uint32_t lat, uint32_t loc, uint32_t group);
    void DispatchMouseMotion(const std::string& clientId, double x, double y);
    void DispatchMouseButton(const std::string& clientId, uint32_t button, bool pressed);
    void DispatchMouseAxis(const std::string& clientId, double dx, double dy);
    void DispatchMouseEnter(const std::string& clientId, double x, double y);
    void DispatchMouseLeave(const std::string& clientId);
    // 内部使用: 按 ctx 设置焦点
    void SetKeyboardFocusForCtx(std::shared_ptr<ClientContext> ctx, wl_resource* surface);
    void SetPointerFocusForCtx(std::shared_ptr<ClientContext> ctx, wl_resource* surface);

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
    void SetSizeCallback(std::function<void(const std::string&, int, int)> cb) {
        sizeCallback_ = std::move(cb);
    }
    void GetLatestSize(const std::string& clientId, int& w, int& h);
    
    // remove csd border
    struct WindowGeom {
        int32_t x = 0;
        int32_t y = 0;
        int32_t w = 0;
        int32_t h = 0;
        bool valid = false;
    };
    void SetWindowGeometry(wl_resource* surf, int32_t x, int32_t y, int32_t w, int32_t h);
    void ClearWindowGeometry(wl_resource* surf);
    WindowGeom GetWindowGeometry(wl_resource* surf);
    
    // for dragging
    void SetMoveCallback(std::function<void(const std::string&)> cb) {
        moveCallback_ = std::move(cb);
    }
    void FireMoveRequest(const std::string& cid);
    void ReleaseAllPointerButtons(const std::string& cid);
    
    // for maximize window
    void SetMaximizeCallback(std::function<void(const std::string&)> cb) {
        maximizeCallback_ = std::move(cb);
    }
    void SetUnmaximizeCallback(std::function<void(const std::string&)> cb) {
        unmaximizeCallback_ = std::move(cb);
    }
    void SetResizeCallback(std::function<void(const std::string&, uint32_t)> cb) {
        resizeCallback_ = std::move(cb);
    }

    void FireMaximizeRequest(const std::string& cid);
    void FireUnmaximizeRequest(const std::string& cid);
    void FireResizeRequest(const std::string& cid, uint32_t edges);
    
    void SetActiveToplevel(wl_client* c, wl_resource* tl, wl_resource* xs);
    void ClearActiveToplevel(wl_resource* tl);   // 遍历所有 ctx
    void SendToplevelConfigure(const std::string& cid, int w, int h, bool maximized);
    void DoSendToplevelConfigure(const std::string& cid, int w, int h, bool maximized);
    
    // for minimize window
    void SetMinimizeCallback(std::function<void(const std::string&)> cb) {
        minimizeCallback_ = std::move(cb);
    }
    void FireMinimizeRequest(const std::string& cid);
    
    // wl_subcompositor / wl_subsurface stub
    static void wl_subcompositor_bind(wl_client* client, void* data,
                                       uint32_t version, uint32_t id);
    static void wl_subcompositor_destroy(wl_client*, wl_resource* r);
    static void wl_subcompositor_get_subsurface(wl_client* client,
                                                 wl_resource* res,
                                                 uint32_t id,
                                                 wl_resource* surface,
                                                 wl_resource* parent);
    
    static void wl_subsurface_destroy(wl_client*, wl_resource* r);
    static void wl_subsurface_set_position(wl_client*, wl_resource*,
                                            int32_t, int32_t);
    static void wl_subsurface_place_above(wl_client*, wl_resource*,
                                           wl_resource*);
    static void wl_subsurface_place_below(wl_client*, wl_resource*,
                                           wl_resource*);
    static void wl_subsurface_set_sync(wl_client*, wl_resource*);
    static void wl_subsurface_set_desync(wl_client*, wl_resource*);
    
    // wp_viewporter / wp_viewport stub
    static void wp_viewporter_bind(wl_client* client, void* data,
                                    uint32_t version, uint32_t id);
    static void wp_viewporter_destroy(wl_client*, wl_resource* r);
    static void wp_viewporter_get_viewport(wl_client* client, wl_resource* res,
                                            uint32_t id, wl_resource* surface);
    
    static void wp_viewport_destroy(wl_client*, wl_resource* r);
    static void wp_viewport_set_source(wl_client*, wl_resource*,
                                        wl_fixed_t, wl_fixed_t,
                                        wl_fixed_t, wl_fixed_t);
    static void wp_viewport_set_destination(wl_client*, wl_resource*,
                                             int32_t, int32_t);
    
    // wl_output stub
    static void wl_output_bind(wl_client* client, void* data,
                               uint32_t version, uint32_t id);
    static void wl_output_release(wl_client*, wl_resource* r);

    // multi instance support
    std::shared_ptr<ClientContext> FindClientCtx(wl_client* c);
    std::shared_ptr<ClientContext> FindClientCtxById(const std::string& id);
    std::shared_ptr<ClientContext> GetOrCreateClientCtx(wl_client* c);
    void EraseClientCtx(wl_client* c);
    void SetClientConnectCallback(std::function<void(const std::string&)> cb) {
        clientConnectCb_ = std::move(cb);
    }
    void SetClientDisconnectCallback(std::function<void(const std::string&)> cb) {
        clientDisconnectCb_ = std::move(cb);
    }
    void FireClientConnect(const std::string& id) {
        if (clientConnectCb_) clientConnectCb_(id);
    }
    void FireClientDisconnect(const std::string& id) {
        if (clientDisconnectCb_) clientDisconnectCb_(id);
    }

private:
    WaylandServer() = default;
    void Loop();

    wl_display* display_ = nullptr;
    std::thread loopThread_;
    std::atomic<bool> running_{false};
    
    StateCb stateCb_;

    // I/O
    SeatState seat_;
    int keymapFd_ = -1;
    size_t keymapSize_ = 0;
    bool BuildKeymapFd();
    uint32_t NextSerial();
    uint32_t NowMs();
    
    // fix window size
    std::function<void(const std::string&, int, int)> sizeCallback_;
    
    // for remove csd border
    std::mutex geomMutex_;
    std::map<wl_resource*, WindowGeom> geomMap_;
    
    // for dragging
    std::function<void(const std::string&)> moveCallback_;
    
    // for maximize window
    std::function<void(const std::string&)> maximizeCallback_;
    std::function<void(const std::string&)> unmaximizeCallback_;
    std::function<void(const std::string&, uint32_t)> resizeCallback_;
    
    // for minimize window
    std::function<void(const std::string&)> minimizeCallback_;

    // per-client 表
    std::mutex                                                    clientsMutex_;
    std::unordered_map<wl_client*, std::shared_ptr<ClientContext>> clients_;
    std::unordered_map<std::string, wl_client*>                    idIndex_;
    std::atomic<int>                                               clientSeq_{0};

    // 新事件回调
    std::function<void(const std::string&)> clientConnectCb_;
    std::function<void(const std::string&)> clientDisconnectCb_;

    // wl_display 全局 listener
    wl_listener clientCreatedListener_{};
};

struct SurfaceState {
    wl_resource* surface = nullptr;
    wl_resource* pendingBuffer = nullptr;
    wl_resource* currentBuffer = nullptr;
    std::vector<wl_resource*> frameCallbacks;
};