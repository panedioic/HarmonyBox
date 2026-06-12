// wayland_server.cpp
#include "wayland_server.h"
#include <cstring>
#include <ctime>
#include <unistd.h>
#include <sys/mman.h>

#include "fps_counter.h"

extern "C" void RegisterXdgShell(wl_display* display);

#undef LOG_TAG
#define LOG_TAG "WL_Server"
#include <hilog/log.h>

static const struct wl_surface_interface k_surface_impl = {
    .destroy           = WaylandServer::surface_destroy,
    .attach            = WaylandServer::surface_attach,
    .damage            = WaylandServer::surface_damage,
    .frame             = WaylandServer::surface_frame,
    .set_opaque_region = WaylandServer::surface_set_opaque_region,
    .set_input_region  = WaylandServer::surface_set_input_region,
    .commit            = WaylandServer::surface_commit,
    .set_buffer_transform = WaylandServer::surface_set_buffer_transform,
    .set_buffer_scale  = WaylandServer::surface_set_buffer_scale,
    .damage_buffer     = WaylandServer::surface_damage_buffer,
    .offset            = WaylandServer::surface_offset,
};

static const struct wl_region_interface k_region_impl = {
    .destroy  = WaylandServer::region_destroy,
    .add      = WaylandServer::region_add,
    .subtract = WaylandServer::region_subtract,
};

static const struct wl_compositor_interface k_compositor_impl = {
    .create_surface = WaylandServer::compositor_create_surface,
    .create_region  = WaylandServer::compositor_create_region,
};

WaylandServer* WaylandServer::GetInstance() {
    static WaylandServer s;
    return &s;
}

bool WaylandServer::Start(const std::string& socketPath) {
    if (running_) return true;

    // 删除可能残留的 socket
    unlink(socketPath.c_str());

    display_ = wl_display_create();
    if (!display_) {
        OH_LOG_ERROR(LOG_APP, "wl_display_create failed");
        return false;
    }

    // 用绝对路径 socket
    int fd = wl_display_add_socket_auto(display_) ?
             -1 : 0; // 这里其实我们要的是 add_socket(path) 形式
    // 用 add_socket 接口需要相对 XDG_RUNTIME_DIR 的名字。
    // 鸿蒙没有 XDG_RUNTIME_DIR，所以我们直接 setenv 一下：
    {
        std::string dir = socketPath.substr(0, socketPath.find_last_of('/'));
        std::string name = socketPath.substr(socketPath.find_last_of('/') + 1);
        setenv("XDG_RUNTIME_DIR", dir.c_str(), 1);
        if (wl_display_add_socket(display_, name.c_str()) != 0) {
            OH_LOG_ERROR(LOG_APP, "wl_display_add_socket failed");
            return false;
        }
        // 同时把这个写进环境变量，子进程 fork 后会继承
        setenv("WAYLAND_DISPLAY", name.c_str(), 1);
    }

    // 注册 globals
    wl_global_create(display_, &wl_compositor_interface, 4, this, compositor_bind);
    wl_display_init_shm(display_); // wl_shm 由 libwayland 内置实现
    
    RegisterXdgShell(display_);

    running_ = true;
    loopThread_ = std::thread(&WaylandServer::Loop, this);
    OH_LOG_INFO(LOG_APP, "wayland server started at %s", socketPath.c_str());
    firstCommit_ = false;
    return true;
}

void WaylandServer::Stop() {
    if (!running_) return;
    running_ = false;
    if (display_) {
        wl_display_terminate(display_);
    }
    if (loopThread_.joinable()) loopThread_.join();
    if (display_) {
        wl_display_destroy(display_);
        display_ = nullptr;
    }
    firstCommit_ = false;
}

void WaylandServer::Loop() {
    while (running_) {
        wl_display_flush_clients(display_);
        wl_event_loop* loop = wl_display_get_event_loop(display_);
        wl_event_loop_dispatch(loop, 50);
    }
}

// ───────────── compositor ─────────────
void WaylandServer::compositor_bind(wl_client* client, void* data, uint32_t version, uint32_t id) {
    wl_resource* res = wl_resource_create(client, &wl_compositor_interface, version, id);
    wl_resource_set_implementation(res, &k_compositor_impl, data, nullptr);
}

void WaylandServer::compositor_create_surface(wl_client* client, wl_resource* compositorRes, uint32_t id) {
    auto* state = new SurfaceState();
    wl_resource* surfRes = wl_resource_create(client, &wl_surface_interface,
                                              wl_resource_get_version(compositorRes), id);
    state->surface = surfRes;
    wl_resource_set_implementation(surfRes, &k_surface_impl, state,
        [](wl_resource* r) {
            auto* s = static_cast<SurfaceState*>(wl_resource_get_user_data(r));
            delete s;
        });
}

void WaylandServer::compositor_create_region(wl_client* client, wl_resource* compositorRes, uint32_t id) {
    wl_resource* res = wl_resource_create(client, &wl_region_interface,
                                          wl_resource_get_version(compositorRes), id);
    wl_resource_set_implementation(res, &k_region_impl, nullptr, nullptr);
}

// ───────────── surface ─────────────
void WaylandServer::surface_attach(wl_client*, wl_resource* surfRes, wl_resource* buffer, int32_t, int32_t) {
    auto* s = static_cast<SurfaceState*>(wl_resource_get_user_data(surfRes));
    s->pendingBuffer = buffer;
}

void WaylandServer::surface_commit(wl_client*, wl_resource* surfRes) {
    auto* s = static_cast<SurfaceState*>(wl_resource_get_user_data(surfRes));
    if (!s->pendingBuffer) return;

    wl_shm_buffer* shm = wl_shm_buffer_get(s->pendingBuffer);
    if (shm) {
        int32_t w = wl_shm_buffer_get_width(shm);
        int32_t h = wl_shm_buffer_get_height(shm);
        int32_t stride = wl_shm_buffer_get_stride(shm);

        wl_shm_buffer_begin_access(shm);
        const uint8_t* src = static_cast<const uint8_t*>(wl_shm_buffer_get_data(shm));

        auto* self = WaylandServer::GetInstance();
        {
            std::lock_guard<std::mutex> lk(self->frameMutex_);
            self->latestPixels_.resize(stride * h);
            std::memcpy(self->latestPixels_.data(), src, stride * h);
            self->latestW_ = w;
            self->latestH_ = h;
            self->dirty_ = true;
        }
        wl_shm_buffer_end_access(shm);
    }

    wl_buffer_send_release(s->pendingBuffer);
    s->currentBuffer = s->pendingBuffer;
    s->pendingBuffer = nullptr;

    // 帧回调
    uint32_t now = (uint32_t)(time(nullptr) * 1000);
    for (auto* cb : s->frameCallbacks) {
        wl_callback_send_done(cb, now);
        wl_resource_destroy(cb);
    }
    s->frameCallbacks.clear();
    
    static FpsCounter commitFps("commit");
    commitFps.Tick();
    
    // 首帧到达 → 通知 UI
    auto* self = GetInstance();
    if (self->MarkFirstCommit()) {
        self->FireState("active");
    }
}

void WaylandServer::surface_frame(wl_client* client, wl_resource* surfRes, uint32_t cbId) {
    auto* s = static_cast<SurfaceState*>(wl_resource_get_user_data(surfRes));
    wl_resource* cbRes = wl_resource_create(client, &wl_callback_interface, 1, cbId);
    s->frameCallbacks.push_back(cbRes);
}

void WaylandServer::surface_destroy(wl_client*, wl_resource* surfRes) { wl_resource_destroy(surfRes); }
void WaylandServer::surface_damage(wl_client*, wl_resource*, int32_t, int32_t, int32_t, int32_t) {}

bool WaylandServer::TakeLatestFrame(std::vector<uint8_t>& out, int& w, int& h) {
    std::lock_guard<std::mutex> lk(frameMutex_);
    if (!dirty_) return false;
    out = latestPixels_;
    w = latestW_; h = latestH_;
    dirty_ = false;
    return true;
}