#include "input_window_napi.h"
#include "napi_utils.h"
#include "wayland_server.h"

namespace {

napi_threadsafe_function g_sizeTsfn       = nullptr;
napi_threadsafe_function g_moveTsfn       = nullptr;
napi_threadsafe_function g_maximizeTsfn   = nullptr;
napi_threadsafe_function g_unmaximizeTsfn = nullptr;
napi_threadsafe_function g_resizeTsfn     = nullptr;
napi_threadsafe_function g_minimizeTsfn   = nullptr;

// 事件结构加个 id
struct SizeEvent {
    std::string id;
    int w;
    int h;
};

void SizeTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    SizeEvent* ev = static_cast<SizeEvent*>(data);
    if (env && jsCb && ev) {
        napi_value undef, args[3];
        napi_get_undefined(env, &undef);
        napi_create_string_utf8(env, ev->id.c_str(), NAPI_AUTO_LENGTH, &args[0]);
        napi_create_int32(env, ev->w, &args[1]);
        napi_create_int32(env, ev->h, &args[2]);
        napi_call_function(env, undef, jsCb, 3, args, nullptr);
    }
    delete ev;
}

void ResizeTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    uint32_t* edges = static_cast<uint32_t*>(data);
    if (env && jsCb && edges) {
        napi_value undef, arg;
        napi_get_undefined(env, &undef);
        napi_create_uint32(env, *edges, &arg);
        napi_call_function(env, undef, jsCb, 1, &arg, nullptr);
    }
    delete edges;
}

// 通用:释放旧 tsfn,创建新 tsfn,然后把 wayland 端的回调指过来
void RebindNoArgTsfn(napi_env env,
                     napi_value jsCb,
                     napi_threadsafe_function& slot,
                     const char* resName) {
    if (slot) {
        napi_release_threadsafe_function(slot, napi_tsfn_release);
        slot = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, resName, NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, jsCb, nullptr, name,
        0, 1, nullptr, nullptr, nullptr,
        napiutil::NoArgTsfnCallJs, &slot);
}

} // anonymous namespace

namespace iwnapi {

// ===================== keyboard / mouse =====================

napi_value SendKey(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t code = 0; bool pressed = false;
    napi_get_value_int32(env, args[0], &code);
    napi_get_value_bool (env, args[1], &pressed);
    WaylandServer::GetInstance()->DispatchKey((uint32_t)code, pressed);
    return nullptr;
}

napi_value SendModifiers(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t v[4] = {0,0,0,0};
    for (int i = 0; i < 4; i++) {
        int32_t t = 0;
        napi_get_value_int32(env, args[i], &t);
        v[i] = (uint32_t)t;
    }
    WaylandServer::GetInstance()->DispatchModifiers(v[0], v[1], v[2], v[3]);
    return nullptr;
}

napi_value SendMouseMove(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double x = 0, y = 0;
    napi_get_value_double(env, args[0], &x);
    napi_get_value_double(env, args[1], &y);
    WaylandServer::GetInstance()->DispatchMouseMotion(x, y);
    return nullptr;
}

napi_value SendMouseButton(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t btn = 0; bool pressed = false;
    napi_get_value_int32(env, args[0], &btn);
    napi_get_value_bool (env, args[1], &pressed);
    WaylandServer::GetInstance()->DispatchMouseButton((uint32_t)btn, pressed);
    return nullptr;
}

napi_value SendMouseAxis(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double dx = 0, dy = 0;
    napi_get_value_double(env, args[0], &dx);
    napi_get_value_double(env, args[1], &dy);
    WaylandServer::GetInstance()->DispatchMouseAxis(dx, dy);
    return nullptr;
}

napi_value SendMouseHover(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool inside = false;
    napi_get_value_bool(env, args[0], &inside);
    if (inside) WaylandServer::GetInstance()->DispatchMouseEnter(0, 0);
    else        WaylandServer::GetInstance()->DispatchMouseLeave();
    return nullptr;
}

// ===================== window events =====================

napi_value SetSizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_sizeTsfn) {
        napi_release_threadsafe_function(g_sizeTsfn, napi_tsfn_release);
        g_sizeTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WLSize", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, SizeTsfnCallJs, &g_sizeTsfn);
    
    WaylandServer::GetInstance()->SetSizeCallback(
        [](const std::string& id, int w, int h) {
            if (g_sizeTsfn) {
                auto* ev = new SizeEvent{id, w, h};
                napi_call_threadsafe_function(g_sizeTsfn, ev, napi_tsfn_blocking);
            }
        });
    return nullptr;
}

napi_value GetLatestSize(napi_env env, napi_callback_info /*info*/) {
    int w = 0, h = 0;
    WaylandServer::GetInstance()->GetLatestSize(w, h);
    napi_value result, vw, vh;
    napi_create_object(env, &result);
    napi_create_int32(env, w, &vw);
    napi_create_int32(env, h, &vh);
    napi_set_named_property(env, result, "w", vw);
    napi_set_named_property(env, result, "h", vh);
    return result;
}

napi_value SetMoveCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    RebindNoArgTsfn(env, args[0], g_moveTsfn, "WLMove");
    WaylandServer::GetInstance()->SetMoveCallback([]() {
        if (g_moveTsfn) {
            napi_call_threadsafe_function(g_moveTsfn, nullptr, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

napi_value SetMaximizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    RebindNoArgTsfn(env, args[0], g_maximizeTsfn, "WLMaximize");
    WaylandServer::GetInstance()->SetMaximizeCallback([]() {
        if (g_maximizeTsfn) {
            napi_call_threadsafe_function(g_maximizeTsfn, nullptr, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

napi_value SetUnmaximizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    RebindNoArgTsfn(env, args[0], g_unmaximizeTsfn, "WLUnmaximize");
    WaylandServer::GetInstance()->SetUnmaximizeCallback([]() {
        if (g_unmaximizeTsfn) {
            napi_call_threadsafe_function(g_unmaximizeTsfn, nullptr, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

napi_value SetResizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_resizeTsfn) {
        napi_release_threadsafe_function(g_resizeTsfn, napi_tsfn_release);
        g_resizeTsfn = nullptr;
    }
    napi_value resName;
    napi_create_string_utf8(env, "WLResize", NAPI_AUTO_LENGTH, &resName);
    napi_create_threadsafe_function(env, args[0], nullptr, resName,
        0, 1, nullptr, nullptr, nullptr, ResizeTsfnCallJs, &g_resizeTsfn);

    WaylandServer::GetInstance()->SetResizeCallback([](uint32_t edges) {
        if (g_resizeTsfn) {
            auto* e = new uint32_t(edges);
            napi_call_threadsafe_function(g_resizeTsfn, e, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

napi_value RequestClientResize(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t w = 0, h = 0;
    bool maximized = false;
    napi_get_value_int32(env, args[0], &w);
    napi_get_value_int32(env, args[1], &h);
    napi_get_value_bool (env, args[2], &maximized);
    WaylandServer::GetInstance()->SendToplevelConfigure(w, h, maximized);
    return nullptr;
}

napi_value SetMinimizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    RebindNoArgTsfn(env, args[0], g_minimizeTsfn, "WLMinimize");
    WaylandServer::GetInstance()->SetMinimizeCallback([]() {
        if (g_minimizeTsfn) {
            napi_call_threadsafe_function(g_minimizeTsfn, nullptr, napi_tsfn_blocking);
        }
    });
    return nullptr;
}

} // namespace iwnapi