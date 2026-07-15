// wayland_server.cpp
#include "wayland_server.h"
#include "xdg-shell-server-protocol.h"
#include "viewporter-server-protocol.h"
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
#define LOG_TAG "HBox_NAPI_WL_Server"
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

static const struct wl_subsurface_interface k_subsurface_impl = {
    .destroy      = WaylandServer::wl_subsurface_destroy,
    .set_position = WaylandServer::wl_subsurface_set_position,
    .place_above  = WaylandServer::wl_subsurface_place_above,
    .place_below  = WaylandServer::wl_subsurface_place_below,
    .set_sync     = WaylandServer::wl_subsurface_set_sync,
    .set_desync   = WaylandServer::wl_subsurface_set_desync,
};

static const struct wl_subcompositor_interface k_subcompositor_impl = {
    .destroy        = WaylandServer::wl_subcompositor_destroy,
    .get_subsurface = WaylandServer::wl_subcompositor_get_subsurface,
};

static const struct wp_viewport_interface k_wp_viewport_impl = {
    .destroy         = WaylandServer::wp_viewport_destroy,
    .set_source      = WaylandServer::wp_viewport_set_source,
    .set_destination = WaylandServer::wp_viewport_set_destination,
};
static const struct wp_viewporter_interface k_wp_viewporter_impl = {
    .destroy      = WaylandServer::wp_viewporter_destroy,
    .get_viewport = WaylandServer::wp_viewporter_get_viewport,
};

static const struct wl_output_interface k_output_impl = {
    .release = WaylandServer::wl_output_release,
};

// wl_display client_created listener trampoline
static void OnWlClientCreated(wl_listener* /*l*/, void* data) {
    auto* client = static_cast<wl_client*>(data);
    auto ctx = WaylandServer::GetInstance()->GetOrCreateClientCtx(client);
    if (ctx) {
        OH_LOG_INFO(LOG_APP,
            "★CLIENT_CREATED id=%{public}s pid=%{public}d",
            ctx->id.c_str(), (int)ctx->pid);
    }
}

// wl_client destroy listener trampoline
static void OnWlClientDestroyed(wl_listener* listener, void* /*data*/) {
    ClientContext* ctx = nullptr;
    ctx = wl_container_of(listener, ctx, destroyListener);
    if (!ctx) return;
    std::string id = ctx->id;
    OH_LOG_INFO(LOG_APP, "★CLIENT_DESTROYED id=%{public}s", id.c_str());

    WaylandServer::GetInstance()->FireClientDisconnect(id);
    WaylandServer::GetInstance()->EraseClientCtx(ctx->client);
}

std::shared_ptr<ClientContext>
WaylandServer::GetOrCreateClientCtx(wl_client* c) {
    if (!c) return nullptr;
    std::lock_guard<std::mutex> lk(clientsMutex_);
    auto it = clients_.find(c);
    if (it != clients_.end()) return it->second;

    auto ctx = std::make_shared<ClientContext>();
    ctx->client = c;
    ctx->id     = "c" + std::to_string(++clientSeq_);

    // 取 pid
    pid_t pid = -1; uid_t uid = 0; gid_t gid = 0;
    wl_client_get_credentials(c, &pid, &uid, &gid);
    ctx->pid = pid;

    // 挂 destroy 监听
    ctx->destroyListener.notify = OnWlClientDestroyed;
    wl_client_add_destroy_listener(c, &ctx->destroyListener);

    clients_[c] = ctx;
    idIndex_[ctx->id] = c;
    return ctx;
}

std::shared_ptr<ClientContext>
WaylandServer::FindClientCtx(wl_client* c) {
    if (!c) return nullptr;
    std::lock_guard<std::mutex> lk(clientsMutex_);
    auto it = clients_.find(c);
    return (it == clients_.end()) ? nullptr : it->second;
}

std::shared_ptr<ClientContext>
WaylandServer::FindClientCtxById(const std::string& id) {
    std::lock_guard<std::mutex> lk(clientsMutex_);
    auto it = idIndex_.find(id);
    if (it == idIndex_.end()) return nullptr;
    auto cit = clients_.find(it->second);
    return (cit == clients_.end()) ? nullptr : cit->second;
}

void WaylandServer::EraseClientCtx(wl_client* c) {
    if (!c) return;
    std::lock_guard<std::mutex> lk(clientsMutex_);
    auto it = clients_.find(c);
    if (it == clients_.end()) return;
    idIndex_.erase(it->second->id);
    clients_.erase(it);
}

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
    
    // 注册 client 创建监听
    clientCreatedListener_.notify = OnWlClientCreated;
    wl_display_add_client_created_listener(display_, &clientCreatedListener_);

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
    wl_global_create(display_, &wl_subcompositor_interface, 1, this, wl_subcompositor_bind);
    wl_global_create(display_, &wp_viewporter_interface, 1, this, wp_viewporter_bind);
    wl_global_create(display_, &wl_output_interface, 4, this, wl_output_bind);
    
    RegisterXdgShell(display_);
    
    // io
    wl_global_create(display_, &wl_seat_interface, 5, this, seat_bind);
    BuildKeymapFd();

    running_ = true;
    loopThread_ = std::thread(&WaylandServer::Loop, this);
    OH_LOG_INFO(LOG_APP, "wayland server started at %s", socketPath.c_str());
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
        {
            std::lock_guard<std::mutex> lk(self->clientsMutex_);
            for (auto& kv : self->clients_) {
                auto& ctx = kv.second;
                if (ctx->mainSurface == r) {
                    ctx->mainSurface = nullptr;
                    ctx->firstCommit = false;
                    ctx->lastNotifiedW = -1;
                    ctx->lastNotifiedH = -1;
                }
                // ★ 清理焦点
                if (ctx->kbFocus == r)  ctx->kbFocus  = nullptr;
                if (ctx->ptrFocus == r) ctx->ptrFocus = nullptr;
            }
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

void WaylandServer::surface_commit(wl_client* client, wl_resource* surfRes) {
    auto* s = static_cast<SurfaceState*>(wl_resource_get_user_data(surfRes));

    // ─── 1. NULL buffer commit ─── (不变)
    if (!s->pendingBuffer) {
        static int null_count = 0;
        if (++null_count % 20 == 1) {
            OH_LOG_INFO(LOG_APP, "★COMMIT_NULL surf=%{public}p count=%{public}d",
                        surfRes, null_count);
        }
        if (!s->frameCallbacks.empty()) {
            uint32_t now = (uint32_t)(time(nullptr) * 1000);
            for (auto* cb : s->frameCallbacks) {
                wl_callback_send_done(cb, now);
                wl_resource_destroy(cb);
            }
            s->frameCallbacks.clear();
        }
        return;
    }

    auto* self = WaylandServer::GetInstance();

    // ★ 拿到本次 commit 所属的 client ctx
    auto ctx = self->GetOrCreateClientCtx(client);
    if (!ctx) return;

    // ─── 2. main surface 排他选举 (per-ctx) ───
    if (ctx->mainSurface == nullptr) {
        ctx->mainSurface = surfRes;
        ctx->firstCommit = false;
        ctx->lastNotifiedW = -1;
        ctx->lastNotifiedH = -1;
        OH_LOG_INFO(LOG_APP, "MAIN_SET ctx=%{public}s surf=%{public}p",
                    ctx->id.c_str(), surfRes);
    }

    // ─── 3. 非主 surface 处理 (不变) ───
    if (ctx->mainSurface != surfRes) {
        static int nonmain_count = 0;
        if (++nonmain_count % 20 == 1) {
            OH_LOG_INFO(LOG_APP, "★COMMIT_NONMAIN ctx=%{public}s surf=%{public}p main=%{public}p",
                        ctx->id.c_str(), surfRes, ctx->mainSurface);
        }
        wl_buffer_send_release(s->pendingBuffer);
        s->currentBuffer = s->pendingBuffer;
        s->pendingBuffer = nullptr;
        uint32_t now = (uint32_t)(time(nullptr) * 1000);
        for (auto* cb : s->frameCallbacks) {
            wl_callback_send_done(cb, now);
            wl_resource_destroy(cb);
        }
        s->frameCallbacks.clear();
        return;
    }

    // ─── 4. 主窗口正常搬运 ───
    // (SHM 拷贝逻辑不变, 但尺寸通知去抖用 ctx 的字段)
    wl_shm_buffer* shm = wl_shm_buffer_get(s->pendingBuffer);
    if (shm) {
        int32_t bufW = wl_shm_buffer_get_width(shm);
        int32_t bufH = wl_shm_buffer_get_height(shm);
        int32_t stride = wl_shm_buffer_get_stride(shm);

       WindowGeom g = self->GetWindowGeometry(surfRes);
        int32_t srcX = 0, srcY = 0;
        int32_t outW = bufW, outH = bufH;
        if (g.valid) {
            srcX = std::max(0, g.x);
            srcY = std::max(0, g.y);
            outW = std::min(g.w, bufW - srcX);
            outH = std::min(g.h, bufH - srcY);
            if (outW <= 0 || outH <= 0) {
                srcX = 0; srcY = 0; outW = bufW; outH = bufH;
            }
        }

        wl_shm_buffer_begin_access(shm);
        const uint8_t* src = static_cast<const uint8_t*>(wl_shm_buffer_get_data(shm));

        {
            // ★ 写到 ctx 的 mutex/latestPixels
            std::lock_guard<std::mutex> lk(ctx->frameMutex);
            const int dstStride = outW * 4;
            ctx->latestPixels.resize(dstStride * outH);
            if (srcX == 0 && srcY == 0 && outW == bufW && outH == bufH
                && stride == bufW * 4) {
                std::memcpy(ctx->latestPixels.data(), src, stride * outH);
            } else {
                for (int row = 0; row < outH; ++row) {
                    const uint8_t* srcRow = src + (srcY + row) * stride + srcX * 4;
                    std::memcpy(ctx->latestPixels.data() + row * dstStride,
                                srcRow, dstStride);
                }
            }
            ctx->latestW = outW;
            ctx->latestH = outH;
                ctx->dirty.store(true);
        }
        wl_shm_buffer_end_access(shm);

        if (ctx->lastNotifiedW != outW || ctx->lastNotifiedH != outH) {
            ctx->lastNotifiedW = outW;
            ctx->lastNotifiedH = outH;
            OH_LOG_INFO(LOG_APP, "★BUF_NEW ctx=%{public}s %{public}dx%{public}d",
                        ctx->id.c_str(), outW, outH);
            if (self->sizeCallback_) self->sizeCallback_(ctx->id, outW, outH);
        }
    } else {
        OH_LOG_INFO(LOG_APP, "★COMMIT_NON_SHM buffer=%{public}p", s->pendingBuffer);
    }

    wl_buffer_send_release(s->pendingBuffer);
    s->currentBuffer = s->pendingBuffer;
    s->pendingBuffer = nullptr;

    uint32_t now = (uint32_t)(time(nullptr) * 1000);
    for (auto* cb : s->frameCallbacks) {
        wl_callback_send_done(cb, now);
        wl_resource_destroy(cb);
    }
    s->frameCallbacks.clear();

    static FpsCounter commitFps("commit");
    commitFps.Tick();

    // ─── 5. 首帧: 触发 client connect ───
    if (ctx->MarkFirstCommit()) {
        OH_LOG_INFO(LOG_APP, "★FIRST_COMMIT ctx=%{public}s surf=%{public}p",
                    ctx->id.c_str(), surfRes);
        self->SetKeyboardFocusForCtx(ctx, surfRes);
        self->SetPointerFocusForCtx(ctx, surfRes);

        // ★ 新事件: onClientConnect(id)
        self->FireClientConnect(ctx->id);

        // ★ 老事件: FireState("active") 保持兼容
        // 目前 ArkTS WaylandService 里 setStateCallback 收到 "active" 转成
        // onClientConnect(DEFAULT_CLIENT_ID). 7-B 移除这段桥接后就不再需要
        // 触发 "active". 现在保留.
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

bool WaylandServer::TakeLatestFrame(const std::string& clientId,
                                     std::vector<uint8_t>& out,
                                     int& w, int& h) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx) return false;
    std::lock_guard<std::mutex> lk(ctx->frameMutex);
    bool expected = true;
    if (!ctx->dirty.compare_exchange_strong(expected, false)) return false;
    out = ctx->latestPixels;
    w = ctx->latestW;
    h = ctx->latestH;
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
    auto ctx = self->FindClientCtx(c);
    if (ctx && ctx->kbFocus) {
        wl_array keys; wl_array_init(&keys);
        wl_keyboard_send_enter(kb, self->NextSerial(), ctx->kbFocus, &keys);
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
void WaylandServer::SetKeyboardFocusForCtx(std::shared_ptr<ClientContext> ctx, wl_resource* surf) {
    if (!ctx || ctx->kbFocus == surf) return;
    uint32_t serial = NextSerial();
    if (ctx->kbFocus) {
        for (auto* k : seat_.keyboards) {
            if (wl_resource_get_client(k) == ctx->client) {
                wl_keyboard_send_leave(k, serial, ctx->kbFocus);
            }
        }
    }
    ctx->kbFocus = surf;
    if (surf) {
        wl_array a; wl_array_init(&a);
        for (auto* k : seat_.keyboards) {
            if (wl_resource_get_client(k) == ctx->client) {
                wl_keyboard_send_enter(k, serial, surf, &a);
            }
        }
        wl_array_release(&a);
    }
}

void WaylandServer::SetPointerFocusForCtx(std::shared_ptr<ClientContext> ctx, wl_resource* surf) {
    if (!ctx || ctx->ptrFocus == surf) return;
    uint32_t serial = NextSerial();
    if (ctx->ptrFocus) {
        for (auto* p : seat_.pointers) {
            if (wl_resource_get_client(p) == ctx->client) {
                wl_pointer_send_leave(p, serial, ctx->ptrFocus);
            }
        }
    }
    ctx->ptrFocus = surf;
    if (surf) {
        for (auto* p : seat_.pointers) {
            if (wl_resource_get_client(p) == ctx->client) {
                wl_pointer_send_enter(p, serial, surf,
                    wl_fixed_from_int(0), wl_fixed_from_int(0));
            }
        }
    }
}

// ─── 事件分发 ───
void WaylandServer::DispatchKey(const std::string& clientId,
                                  uint32_t code, bool pressed) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx || !ctx->kbFocus) return;

    uint32_t serial = NextSerial();
    uint32_t t = NowMs();
    for (auto* k : seat_.keyboards) {
        if (wl_resource_get_client(k) != ctx->client) continue;
        wl_keyboard_send_key(k, serial, t, code,
            pressed ? WL_KEYBOARD_KEY_STATE_PRESSED
                    : WL_KEYBOARD_KEY_STATE_RELEASED);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchModifiers(const std::string& clientId,
                                        uint32_t d, uint32_t l,
                                        uint32_t lk, uint32_t g) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx || !ctx->kbFocus) return;

    uint32_t serial = NextSerial();
    for (auto* k : seat_.keyboards) {
        if (wl_resource_get_client(k) != ctx->client) continue;
        wl_keyboard_send_modifiers(k, serial, d, l, lk, g);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseMotion(const std::string& clientId,
                                          double x, double y) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx || !ctx->ptrFocus) return;

    // window_geometry 补偿
    WindowGeom g = GetWindowGeometry(ctx->ptrFocus);
    if (g.valid) { x += g.x; y += g.y; }

    uint32_t t = NowMs();
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        wl_pointer_send_motion(p, t,
            wl_fixed_from_double(x), wl_fixed_from_double(y));
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseButton(const std::string& clientId,
                                          uint32_t button, bool pressed) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx || !ctx->ptrFocus) return;

    uint32_t serial = NextSerial();
    uint32_t t = NowMs();
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        wl_pointer_send_button(p, serial, t, button,
            pressed ? WL_POINTER_BUTTON_STATE_PRESSED
                    : WL_POINTER_BUTTON_STATE_RELEASED);
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::DispatchMouseAxis(const std::string& clientId,
                                        double dx, double dy) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx || !ctx->ptrFocus) return;

    uint32_t t = NowMs();
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
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

void WaylandServer::DispatchMouseEnter(const std::string& clientId,
                                         double x, double y) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx || !ctx->ptrFocus) return;

    WindowGeom g = GetWindowGeometry(ctx->ptrFocus);
    if (g.valid) { x += g.x; y += g.y; }

    uint32_t serial = NextSerial();
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        wl_pointer_send_enter(p, serial, ctx->ptrFocus,
            wl_fixed_from_double(x), wl_fixed_from_double(y));
    }
}

void WaylandServer::DispatchMouseLeave(const std::string& clientId) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx || !ctx->ptrFocus) return;

    uint32_t serial = NextSerial();
    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        wl_pointer_send_leave(p, serial, ctx->ptrFocus);
    }
}

// 修改或追加 ResetFirstCommit 的实现：
// 确保带上 WaylandServer:: 作用域
void WaylandServer::ResetFirstCommit() {
    std::lock_guard<std::mutex> lk(clientsMutex_);
    for (auto& kv : clients_) {
        auto& ctx = kv.second;
        ctx->mainSurface = nullptr;
        ctx->firstCommit = false;
        ctx->lastNotifiedW = -1;
        ctx->lastNotifiedH = -1;
        ctx->kbFocus = nullptr;
        ctx->ptrFocus = nullptr;
    }
}

void WaylandServer::GetLatestSize(const std::string& clientId,
                                   int& w, int& h) {
    auto ctx = FindClientCtxById(clientId);
    if (!ctx) { w = 0; h = 0; return; }
    std::lock_guard<std::mutex> lk(ctx->frameMutex);
    w = ctx->latestW;
    h = ctx->latestH;
}

// for remove csd border
void WaylandServer::SetWindowGeometry(wl_resource* surf,
    int32_t x, int32_t y, int32_t w, int32_t h) {
    if (!surf) return;
    std::lock_guard<std::mutex> lk(geomMutex_);
    WindowGeom g;
    g.x = x; g.y = y; g.w = w; g.h = h;
    g.valid = (w > 0 && h > 0);
    geomMap_[surf] = g;
}

void WaylandServer::ClearWindowGeometry(wl_resource* surf) {
    if (!surf) return;
    std::lock_guard<std::mutex> lk(geomMutex_);
    geomMap_.erase(surf);
}

WaylandServer::WindowGeom WaylandServer::GetWindowGeometry(wl_resource* surf) {
    std::lock_guard<std::mutex> lk(geomMutex_);
    auto it = geomMap_.find(surf);
    if (it == geomMap_.end()) return WindowGeom();
    return it->second;
}

// for dragging
void WaylandServer::FireMoveRequest(const std::string& cid) {
    ReleaseAllPointerButtons(cid);
    if (moveCallback_) moveCallback_(cid);
}

void WaylandServer::FireMaximizeRequest(const std::string& cid) {
    ReleaseAllPointerButtons(cid);
    if (maximizeCallback_) maximizeCallback_(cid);
}

void WaylandServer::FireUnmaximizeRequest(const std::string& cid) {
    ReleaseAllPointerButtons(cid);
    if (unmaximizeCallback_) unmaximizeCallback_(cid);
}

void WaylandServer::FireResizeRequest(const std::string& cid, uint32_t edges) {
    ReleaseAllPointerButtons(cid);
    if (resizeCallback_) resizeCallback_(cid, edges);
}

void WaylandServer::FireMinimizeRequest(const std::string& cid) {
    ReleaseAllPointerButtons(cid);
    if (minimizeCallback_) minimizeCallback_(cid);
}

void WaylandServer::ReleaseAllPointerButtons(const std::string& cid) {
    auto ctx = FindClientCtxById(cid);
    if (!ctx || !ctx->ptrFocus) return;

    uint32_t serial = NextSerial();
    uint32_t t = NowMs();
    const uint32_t btns[] = {0x110, 0x111, 0x112};

    for (auto* p : seat_.pointers) {
        if (wl_resource_get_client(p) != ctx->client) continue;
        for (uint32_t b : btns) {
            wl_pointer_send_button(p, serial, t, b,
                WL_POINTER_BUTTON_STATE_RELEASED);
        }
        if (wl_resource_get_version(p) >= 5) wl_pointer_send_frame(p);
    }
    wl_display_flush_clients(display_);
}

void WaylandServer::SetActiveToplevel(wl_client* c,
                                       wl_resource* tl, wl_resource* xs) {
    auto ctx = FindClientCtx(c);
    if (!ctx) return;
    ctx->activeToplevel = tl;
    ctx->activeXdgSurface = xs;
}

void WaylandServer::ClearActiveToplevel(wl_resource* tl) {
    std::lock_guard<std::mutex> lk(clientsMutex_);
    for (auto& kv : clients_) {
        auto& ctx = kv.second;
        if (ctx->activeToplevel == tl) {
            ctx->activeToplevel = nullptr;
            ctx->activeXdgSurface = nullptr;
            break;
        }
    }
}

namespace {
struct ConfigureCtx {
    std::string cid;
    int w;
    int h;
    bool maximized;
};
}

static void idle_send_configure(void* data) {
    auto* c = static_cast<ConfigureCtx*>(data);
    WaylandServer::GetInstance()->DoSendToplevelConfigure(
        c->cid, c->w, c->h, c->maximized);
    delete c;
}

void WaylandServer::SendToplevelConfigure(const std::string& cid,
                                            int w, int h, bool maximized) {
    if (!display_ || w <= 0 || h <= 0) return;
    auto* c = new ConfigureCtx{cid, w, h, maximized};
    wl_event_loop* loop = wl_display_get_event_loop(display_);
    wl_event_loop_add_idle(loop, idle_send_configure, c);
}

void WaylandServer::DoSendToplevelConfigure(const std::string& cid,
                                              int w, int h, bool maximized) {
    auto ctx = FindClientCtxById(cid);
    if (!ctx || !ctx->activeToplevel || !ctx->activeXdgSurface || !display_) return;

    wl_array states;
    wl_array_init(&states);
    uint32_t* s1 = (uint32_t*)wl_array_add(&states, sizeof(uint32_t));
    *s1 = XDG_TOPLEVEL_STATE_ACTIVATED;
    if (maximized) {
        uint32_t* s2 = (uint32_t*)wl_array_add(&states, sizeof(uint32_t));
        *s2 = XDG_TOPLEVEL_STATE_MAXIMIZED;
    }
    xdg_toplevel_send_configure(ctx->activeToplevel, w, h, &states);
    wl_array_release(&states);

    uint32_t serial = wl_display_next_serial(display_);
    xdg_surface_send_configure(ctx->activeXdgSurface, serial);
    wl_display_flush_clients(display_);

    OH_LOG_INFO(LOG_APP,
        "HBOX_WIN_RESIZE_CFG_SEND cid=%{public}s %{public}dx%{public}d "
        "max=%{public}d serial=%{public}u",
        cid.c_str(), w, h, maximized ? 1 : 0, serial);
}

// ─── wl_subsurface stub ───
void WaylandServer::wl_subsurface_destroy(wl_client*, wl_resource* r) {
    wl_resource_destroy(r);
}
void WaylandServer::wl_subsurface_set_position(wl_client*, wl_resource*,
                                                int32_t, int32_t) {}
void WaylandServer::wl_subsurface_place_above(wl_client*, wl_resource*,
                                               wl_resource*) {}
void WaylandServer::wl_subsurface_place_below(wl_client*, wl_resource*,
                                               wl_resource*) {}
void WaylandServer::wl_subsurface_set_sync(wl_client*, wl_resource*) {}
void WaylandServer::wl_subsurface_set_desync(wl_client*, wl_resource*) {}

// ─── wl_subcompositor stub ───
void WaylandServer::wl_subcompositor_destroy(wl_client*, wl_resource* r) {
    wl_resource_destroy(r);
}

void WaylandServer::wl_subcompositor_get_subsurface(wl_client* client,
                                                     wl_resource* res,
                                                     uint32_t id,
                                                     wl_resource* /*surface*/,
                                                     wl_resource* /*parent*/) {
    wl_resource* sub = wl_resource_create(client, &wl_subsurface_interface,
                                          wl_resource_get_version(res), id);
    if (sub) {
        wl_resource_set_implementation(sub, &k_subsurface_impl, nullptr, nullptr);
    }
}

void WaylandServer::wl_subcompositor_bind(wl_client* client, void*,
                                           uint32_t /*version*/, uint32_t id) {
    wl_resource* res = wl_resource_create(client, &wl_subcompositor_interface,
                                          1, id);
    wl_resource_set_implementation(res, &k_subcompositor_impl, nullptr, nullptr);
    OH_LOG_INFO(LOG_APP, "wl_subcompositor bound");
}

// wp_viewporter / wp_viewport stub
void WaylandServer::wp_viewport_destroy(wl_client*, wl_resource* r) {
    wl_resource_destroy(r);
}
void WaylandServer::wp_viewport_set_source(wl_client*, wl_resource*,
                                            wl_fixed_t, wl_fixed_t,
                                            wl_fixed_t, wl_fixed_t) {}
void WaylandServer::wp_viewport_set_destination(wl_client*, wl_resource*,
                                                 int32_t, int32_t) {}
void WaylandServer::wp_viewporter_destroy(wl_client*, wl_resource* r) {
    wl_resource_destroy(r);
}
void WaylandServer::wp_viewporter_get_viewport(wl_client* client,
                                                wl_resource* res,
                                                uint32_t id,
                                                wl_resource* /*surface*/) {
    wl_resource* vp = wl_resource_create(client, &wp_viewport_interface,
                                          wl_resource_get_version(res), id);
    if (vp) {
        wl_resource_set_implementation(vp, &k_wp_viewport_impl, nullptr, nullptr);
    }
}
void WaylandServer::wp_viewporter_bind(wl_client* client, void*,
                                        uint32_t /*version*/, uint32_t id) {
    wl_resource* res = wl_resource_create(client, &wp_viewporter_interface,
                                          1, id);
    wl_resource_set_implementation(res, &k_wp_viewporter_impl,
                                    nullptr, nullptr);
    OH_LOG_INFO(LOG_APP, "wp_viewporter bound");
}

void WaylandServer::wl_output_release(wl_client*, wl_resource* r) {
    wl_resource_destroy(r);
}

void WaylandServer::wl_output_bind(wl_client* client, void*,
                                    uint32_t version, uint32_t id) {
    uint32_t use_ver = std::min(version, 4u);
    wl_resource* res = wl_resource_create(client, &wl_output_interface,
                                          use_ver, id);
    wl_resource_set_implementation(res, &k_output_impl, nullptr, nullptr);

    // 虚拟显示器: 1920x1080 @ 60Hz, scale=1, 在 (0,0)
    wl_output_send_geometry(res,
        0, 0,                                       // x, y
        340, 190,                                   // 物理尺寸 mm
        WL_OUTPUT_SUBPIXEL_UNKNOWN,
        "HarmonyBox", "Virtual",                    // make, model
        WL_OUTPUT_TRANSFORM_NORMAL);

    wl_output_send_mode(res,
        WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
        1920, 1080,                                 // width, height
        60000);                                     // refresh in mHz

    if (use_ver >= 2) {
        wl_output_send_scale(res, 1);
        wl_output_send_done(res);
    }

    OH_LOG_INFO(LOG_APP, "wl_output bound v=%{public}u", use_ver);
}