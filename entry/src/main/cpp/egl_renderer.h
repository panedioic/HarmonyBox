#pragma once
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <thread>
#include <atomic>

class EglRenderer {
public:
    bool Init(OHNativeWindow* window, int w, int h);
    void Shutdown();
    void OnResize(int w, int h) { width_ = w; height_ = h; }
private:
    void RenderLoop();
    OHNativeWindow* window_ = nullptr;
    EGLDisplay eglDisp_ = EGL_NO_DISPLAY;
    EGLContext eglCtx_  = EGL_NO_CONTEXT;
    EGLSurface eglSurf_ = EGL_NO_SURFACE;
    GLuint tex_ = 0, prog_ = 0, vbo_ = 0;
    std::thread th_;
    std::atomic<bool> running_{false};
    std::atomic<int> width_{0};
    std::atomic<int> height_{0};
};