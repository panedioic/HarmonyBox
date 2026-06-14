// wayland_server.cpp
#include "wayland_server.h"
#include <cstring>
#include <ctime>
#include <unistd.h>
#include <sys/mman.h>
#include <algorithm>

extern "C" {
#include <linux/memfd.h>
#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 0x0001
#endif
int memfd_create(const char* name, unsigned int flags);
}

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
    
    // io
    wl_global_create(display_, &wl_seat_interface, 5, this, seat_bind);
    BuildKeymapFd();

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
            auto* self = WaylandServer::GetInstance();
            if (self->mainSurface_ == r) {
                self->mainSurface_ = nullptr;
            }
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
    
    auto* self = WaylandServer::GetInstance();
    // 1. 首次有 buffer 提交的 surface，作为排他的主渲染窗口
    if (self->mainSurface_ == nullptr) {
        self->mainSurface_ = surfRes;
        OH_LOG_INFO(LOG_APP, "Main surface bound to %{public}p", surfRes);
    }
    // 2. 如果提交的不是主窗口（比如是客户端用来显示鼠标光标的32x32 surface）
    // 拦截像素拷贝，直接释放 buffer 并归还 frame callback 防止客户端卡死
    if (self->mainSurface_ != surfRes) {
        wl_buffer_send_release(s->pendingBuffer);
        s->currentBuffer = s->pendingBuffer;
        s->pendingBuffer = nullptr;
        // 必须消耗掉 frame callback，否则对应组件/光标动画会卡死在第一帧
        uint32_t now = (uint32_t)(time(nullptr) * 1000);
        for (auto* cb : s->frameCallbacks) {
            wl_callback_send_done(cb, now);
            wl_resource_destroy(cb);
        }
        s->frameCallbacks.clear();
        return;
    }
    // 3. 以下为主窗口的正常渲染搬运逻辑 (原代码保持不变)
    wl_shm_buffer* shm = wl_shm_buffer_get(s->pendingBuffer);
    if (shm) {
        int32_t w = wl_shm_buffer_get_width(shm);
        int32_t h = wl_shm_buffer_get_height(shm);
        int32_t stride = wl_shm_buffer_get_stride(shm);

        wl_shm_buffer_begin_access(shm);
        const uint8_t* src = static_cast<const uint8_t*>(wl_shm_buffer_get_data(shm));
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
    if (self->MarkFirstCommit()) {
        self->SetKeyboardFocus(surfRes);
        self->SetPointerFocus(surfRes);
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

// ===== Keyboard and Mouse =====

static const struct wl_seat_interface k_seat_impl = {
    .get_pointer  = WaylandServer::seat_get_pointer,
    .get_keyboard = WaylandServer::seat_get_keyboard,
    .get_touch    = WaylandServer::seat_get_touch,
    .release      = WaylandServer::seat_release,
};

static const struct wl_keyboard_interface k_keyboard_impl = {
    .release = WaylandServer::keyboard_release,
};

static const struct wl_pointer_interface k_pointer_impl = {
    .set_cursor = WaylandServer::pointer_set_cursor,
    .release    = WaylandServer::pointer_release,
};

uint32_t WaylandServer::NextSerial() { return wl_display_next_serial(display_); }

uint32_t WaylandServer::NowMs() {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

bool WaylandServer::BuildKeymapFd() {
    static const char kKeymap[] =
        "xkb_keymap {\n"
        "  xkb_keycodes  { include \"evdev+aliases(qwerty)\" };\n"
        "  xkb_types     { include \"complete\" };\n"
        "  xkb_compat    { include \"complete\" };\n"
        "  xkb_symbols   { include \"pc+us+inet(evdev)\" };\n"
        "};\n";
    keymapSize_ = sizeof(kKeymap);
    int fd = memfd_create("hbox-xkb", MFD_CLOEXEC);
    if (fd < 0) return false;
    if (ftruncate(fd, keymapSize_) < 0) { close(fd); return false; }
    void* p = mmap(nullptr, keymapSize_, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { close(fd); return false; }
    memcpy(p, kKeymap, keymapSize_);
    munmap(p, keymapSize_);
    keymapFd_ = fd;
    return true;
}

void WaylandServer::seat_bind(wl_client* c, void* data, uint32_t v, uint32_t id) {
    auto* self = static_cast<WaylandServer*>(data);
    wl_resource* res = wl_resource_create(c, &wl_seat_interface, v, id);
    wl_resource_set_implementation(res, &k_seat_impl, self, nullptr);
    self->seat_.seatRes = res;
    wl_seat_send_capabilities(res,
        WL_SEAT_CAPABILITY_KEYBOARD | WL_SEAT_CAPABILITY_POINTER);
    if (v >= 2) wl_seat_send_name(res, "default");
}

void WaylandServer::seat_get_keyboard(wl_client* c, wl_resource* sr, uint32_t id) {
    auto* self = static_cast<WaylandServer*>(wl_resource_get_user_data(sr));
    wl_resource* kb = wl_resource_create(c, &wl_keyboard_interface,
        wl_resource_get_version(sr), id);
    wl_resource_set_implementation(kb, &k_keyboard_impl, self, [](wl_resource* r) {
        auto& v = WaylandServer::GetInstance()->seat_.keyboards;
        v.erase(std::remove(v.begin(), v.end(), r), v.end());
    });
    self->seat_.keyboards.push_back(kb);

    if (self->keymapFd_ >= 0) {
        wl_keyboard_send_keymap(kb, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
            self->keymapFd_, (uint32_t)self->keymapSize_);
    }
    if (wl_resource_get_version(kb) >= 4) {
        wl_keyboard_send_repeat_info(kb, 25, 400);
    }
    if (self->kbFocus_ &&
        wl_resource_get_client(self->kbFocus_) == c) {
        wl_array keys; wl_array_init(&keys);
        wl_keyboard_send_enter(kb, self->NextSerial(), self->kbFocus_, &keys);
        wl_array_release(&keys);
    }
}

void WaylandServer::seat_get_pointer(wl_client* c, wl_resource* sr, uint32_t id) {
    auto* self = static_cast<WaylandServer*>(wl_resource_get_user_data(sr));
    wl_resource* p = wl_resource_create(c, &wl_pointer_interface,
        wl_resource_get_version(sr), id);
    wl_resource_set_implementation(p, &k_pointer_impl, self, [](wl_resource* r) {
        auto& v = WaylandServer::GetInstance()->seat_.pointers;
        v.erase(std::remove(v.begin(), v.end(), r), v.end());
    });
    self->seat_.pointers.push_back(p);
}

void WaylandServer::seat_get_touch(wl_client* c, wl_resource* sr, uint32_t id) {
    wl_resource* t = wl_resource_create(c, &wl_touch_interface,
        wl_resource_get_version(sr), id);
    static const struct wl_touch_interface impl = {
        .release = [](wl_client*, wl_resource* r) { wl_resource_destroy(r); }
    };
    wl_resource_set_implementation(t, &impl, nullptr, nullptr);
}

void WaylandServer::seat_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
void WaylandServer::keyboard_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
void WaylandServer::pointer_release(wl_client*, wl_resource* r) { wl_resource_destroy(r); }
void WaylandServer::pointer_set_cursor(wl_client*, wl_resource*, uint32_t,
                                       wl_resource*, int32_t, int32_t) {
    // 暂不实现自定义光标,客户端可能会调
}

// ─── 焦点 ───
void WaylandServer::SetKeyboardFocus(wl_resource* surf) {
    if (kbFocus_ == surf) return;
    uint32_t serial = NextSerial();
    if (kbFocus_) {
        for (auto* k : seat_.keyboards)
            if (wl_resource_get_client(k) == wl_resource_get_client(kbFocus_))
                wl_keyboard_send_leave(k, serial, kbFocus_);
    }
    kbFocus_ = surf;
    if (kbFocus_) {
        wl_array a; wl_array_init(&a);
        for (auto* k : seat_.keyboards)
            if (wl_resource_get_client(k) == wl_resource_get_client(kbFocus_))
                wl_keyboard_send_enter(k, serial, kbFocus_, &a);
        wl_array_release(&a);
    }
}

void WaylandServer::SetPointerFocus(wl_resource* surf) {
    if (ptrFocus_ == surf) return;
    uint32_t serial = NextSerial();
    if (ptrFocus_) {
        for (auto* p : seat_.pointers)
            if (wl_resource_get_client(p) == wl_resource_get_client(ptrFocus_))
                wl_pointer_send_leave(p, serial, ptrFocus_);
    }
    ptrFocus_ = surf;
    if (ptrFocus_) {
        for (auto* p : seat_.pointers)
            if (wl_resource_get_client(p) == wl_resource_get_client(ptrFocus_))
                wl_pointer_send_enter(p, serial, ptrFocus_,
                    wl_fixed_from_int(0), wl_fixed_from_int(0));
    }
}

// ─── 事件分发 ───
void WaylandServer::DispatchKey(uint32_t code, bool pressed) {
    if (!kbFocus_) return;
    uint32_t serial = NextSerial(), t = NowMs();
    auto* c = wl_resource_get_client(kbFocus_);
    for (auto* k : seat_.keyboards)
        if (wl_resource_get_client(k) == c)
            wl_keyboard_send_key(k, serial, t, code,
                pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchModifiers(uint32_t d, uint32_t l, uint32_t lk, uint32_t g) {
    if (!kbFocus_) return;
    uint32_t serial = NextSerial();
    auto* c = wl_resource_get_client(kbFocus_);
    for (auto* k : seat_.keyboards)
        if (wl_resource_get_client(k) == c)
            wl_keyboard_send_modifiers(k, serial, d, l, lk, g);
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseMotion(double x, double y) {
    if (!ptrFocus_) return;
    uint32_t t = NowMs();
    auto* c = wl_resource_get_client(ptrFocus_);
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != c) continue;
        wl_pointer_send_motion(p, t,
            wl_fixed_from_double(x), wl_fixed_from_double(y));
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseButton(uint32_t button, bool pressed) {
    if (!ptrFocus_) return;
    uint32_t serial = NextSerial(), t = NowMs();
    auto* c = wl_resource_get_client(ptrFocus_);
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != c) continue;
        wl_pointer_send_button(p, serial, t, button,
            pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseAxis(double dx, double dy) {
    if (!ptrFocus_) return;
    uint32_t t = NowMs();
    auto* c = wl_resource_get_client(ptrFocus_);
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != c) continue;
        if (dx != 0)
            wl_pointer_send_axis(p, t, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
                                 wl_fixed_from_double(dx));
        if (dy != 0)
            wl_pointer_send_axis(p, t, WL_POINTER_AXIS_VERTICAL_SCROLL,
                                 wl_fixed_from_double(dy));
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseEnter(double x, double y) {
    if (!ptrFocus_) return;
    uint32_t serial = NextSerial();
    auto* c = wl_resource_get_client(ptrFocus_);
    for (auto* p : seat_.pointers)
        if (wl_resource_get_client(p) == c)
            wl_pointer_send_enter(p, serial, ptrFocus_,
                wl_fixed_from_double(x), wl_fixed_from_double(y));
}

void WaylandServer::DispatchMouseLeave() {
    if (!ptrFocus_) return;
    uint32_t serial = NextSerial();
    auto* c = wl_resource_get_client(ptrFocus_);
    for (auto* p : seat_.pointers)
        if (wl_resource_get_client(p) == c)
            wl_pointer_send_leave(p, serial, ptrFocus_);
}

// 修改或追加 ResetFirstCommit 的实现：
// 确保带上 WaylandServer:: 作用域
void WaylandServer::ResetFirstCommit() {
    firstCommit_ = false;
    mainSurface_ = nullptr;
    kbFocus_ = nullptr;
    ptrFocus_ = nullptr;
}

