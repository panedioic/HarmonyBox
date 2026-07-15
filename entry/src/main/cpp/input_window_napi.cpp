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

struct ClientIdEvent {
    std::string cid;
};

struct ClientResizeEvent {
    std::string cid;
    uint32_t edges;
};

void ClientIdTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    auto* ev = static_cast<ClientIdEvent*>(data);
    if (env && jsCb && ev) {
        napi_value undef, arg;
        napi_get_undefined(env, &undef);
        napi_create_string_utf8(env, ev->cid.c_str(), NAPI_AUTO_LENGTH, &arg);
        napi_call_function(env, undef, jsCb, 1, &arg, nullptr);
    }
    delete ev;
}

void ClientResizeTsfnCallJs(napi_env env, napi_value jsCb, void*, void* data) {
    auto* ev = static_cast<ClientResizeEvent*>(data);
    if (env && jsCb && ev) {
        napi_value undef, args[2];
        napi_get_undefined(env, &undef);
        napi_create_string_utf8(env, ev->cid.c_str(), NAPI_AUTO_LENGTH, &args[0]);
        napi_create_uint32(env, ev->edges, &args[1]);
        napi_call_function(env, undef, jsCb, 2, args, nullptr);
    }
    delete ev;
}

} // anonymous namespace

namespace iwnapi {

// ===================== keyboard / mouse =====================

napi_value SendKey(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string cid = napiutil::GetStringArg(env, args[0]);
    int32_t code = 0;
    bool pressed = false;
    napi_get_value_int32(env, args[1], &code);
    napi_get_value_bool(env, args[2], &pressed);
    WaylandServer::GetInstance()->DispatchKey(cid, (uint32_t)code, pressed);
    return nullptr;
}

napi_value SendModifiers(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string cid = napiutil::GetStringArg(env, args[0]);
    uint32_t v[4] = {0, 0, 0, 0};
    for (int i = 0; i < 4; i++) {
        int32_t t = 0;
        napi_get_value_int32(env, args[i + 1], &t);
        v[i] = (uint32_t)t;
    }
    WaylandServer::GetInstance()->DispatchModifiers(cid, v[0], v[1], v[2], v[3]);
    return nullptr;
}

napi_value SendMouseMove(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string cid = napiutil::GetStringArg(env, args[0]);
    double x = 0, y = 0;
    napi_get_value_double(env, args[1], &x);
    napi_get_value_double(env, args[2], &y);
    WaylandServer::GetInstance()->DispatchMouseMotion(cid, x, y);
    return nullptr;
}

napi_value SendMouseButton(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string cid = napiutil::GetStringArg(env, args[0]);
    int32_t btn = 0;
    bool pressed = false;
    napi_get_value_int32(env, args[1], &btn);
    napi_get_value_bool(env, args[2], &pressed);
    WaylandServer::GetInstance()->DispatchMouseButton(cid, (uint32_t)btn, pressed);
    return nullptr;
}

napi_value SendMouseAxis(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string cid = napiutil::GetStringArg(env, args[0]);
    double dx = 0, dy = 0;
    napi_get_value_double(env, args[1], &dx);
    napi_get_value_double(env, args[2], &dy);
    WaylandServer::GetInstance()->DispatchMouseAxis(cid, dx, dy);
    return nullptr;
}

napi_value SendMouseHover(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string cid = napiutil::GetStringArg(env, args[0]);
    bool inside = false;
    napi_get_value_bool(env, args[1], &inside);
    if (inside)
        WaylandServer::GetInstance()->DispatchMouseEnter(cid, 0, 0);
    else
        WaylandServer::GetInstance()->DispatchMouseLeave(cid);
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

napi_value GetLatestSize(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string cid = napiutil::GetStringArg(env, args[0]);
    int w = 0, h = 0;
    WaylandServer::GetInstance()->GetLatestSize(cid, w, h);

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
    if (g_moveTsfn) {
        napi_release_threadsafe_function(g_moveTsfn, napi_tsfn_release);
        g_moveTsfn = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, "WLMove", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, args[0], nullptr, name,
        0, 1, nullptr, nullptr, nullptr, ClientIdTsfnCallJs, &g_moveTsfn);

    WaylandServer::GetInstance()->SetMoveCallback(
        [](const std::string& cid) {
            if (g_moveTsfn) {
                napi_call_threadsafe_function(g_moveTsfn,
                    new ClientIdEvent{cid}, napi_tsfn_blocking);
            }
        });
    return nullptr;
}

napi_value SetMaximizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_maximizeTsfn) {
        napi_release_threadsafe_function(g_maximizeTsfn, napi_tsfn_release);
        g_maximizeTsfn = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, "WLMaximize", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, args[0], nullptr, name,
        0, 1, nullptr, nullptr, nullptr, ClientIdTsfnCallJs, &g_maximizeTsfn);

    WaylandServer::GetInstance()->SetMaximizeCallback(
        [](const std::string& cid) {
            if (g_maximizeTsfn) {
                napi_call_threadsafe_function(g_maximizeTsfn,
                    new ClientIdEvent{cid}, napi_tsfn_blocking);
            }
        });
    return nullptr;
}

napi_value SetUnmaximizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_unmaximizeTsfn) {
        napi_release_threadsafe_function(g_unmaximizeTsfn, napi_tsfn_release);
        g_unmaximizeTsfn = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, "WLUnmaximize", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, args[0], nullptr, name,
        0, 1, nullptr, nullptr, nullptr, ClientIdTsfnCallJs, &g_unmaximizeTsfn);

    WaylandServer::GetInstance()->SetUnmaximizeCallback(
        [](const std::string& cid) {
            if (g_unmaximizeTsfn) {
                napi_call_threadsafe_function(g_unmaximizeTsfn,
                    new ClientIdEvent{cid}, napi_tsfn_blocking);
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
    napi_value name;
    napi_create_string_utf8(env, "WLResize", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, args[0], nullptr, name,
        0, 1, nullptr, nullptr, nullptr, ClientResizeTsfnCallJs, &g_resizeTsfn);

    WaylandServer::GetInstance()->SetResizeCallback(
        [](const std::string& cid, uint32_t edges) {
            if (g_resizeTsfn) {
                napi_call_threadsafe_function(g_resizeTsfn,
                    new ClientResizeEvent{cid, edges}, napi_tsfn_blocking);
            }
        });
    return nullptr;
}

napi_value SetMinimizeCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_minimizeTsfn) {
        napi_release_threadsafe_function(g_minimizeTsfn, napi_tsfn_release);
        g_minimizeTsfn = nullptr;
    }
    napi_value name;
    napi_create_string_utf8(env, "WLMinimize", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, args[0], nullptr, name,
        0, 1, nullptr, nullptr, nullptr, ClientIdTsfnCallJs, &g_minimizeTsfn);

    WaylandServer::GetInstance()->SetMinimizeCallback(
        [](const std::string& cid) {
            if (g_minimizeTsfn) {
                napi_call_threadsafe_function(g_minimizeTsfn,
                    new ClientIdEvent{cid}, napi_tsfn_blocking);
            }
        });
    return nullptr;
}

napi_value RequestClientResize(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string cid = napiutil::GetStringArg(env, args[0]);
    int32_t w = 0, h = 0;
    bool maximized = false;
    napi_get_value_int32(env, args[1], &w);
    napi_get_value_int32(env, args[2], &h);
    napi_get_value_bool(env, args[3], &maximized);
    WaylandServer::GetInstance()->SendToplevelConfigure(cid, w, h, maximized);
    return nullptr;
}

} // namespace iwnapi