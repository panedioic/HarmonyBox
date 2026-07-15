#pragma once
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <thread>
#include <atomic>

class EglRenderer {
public:
    bool Init(OHNativeWindow* w, int width, int height);
    void OnResize(int w, int h);
    void Shutdown();

    // ★ 新
    void SetClientId(const std::string& cid) { clientId_ = cid; }
    const std::string& GetClientId() const { return clientId_; }

private:
    void RenderLoop();

    OHNativeWindow* window_ = nullptr;
    std::atomic<int> width_{0};
    std::atomic<int> height_{0};

    EGLDisplay eglDisp_ = EGL_NO_DISPLAY;
    EGLContext eglCtx_  = EGL_NO_CONTEXT;
    EGLSurface eglSurf_ = EGL_NO_SURFACE;

    GLuint prog_ = 0;
    GLuint vbo_  = 0;
    GLuint tex_  = 0;

    std::atomic<bool> running_{false};
    std::thread th_;

    std::string clientId_;  // ★
};