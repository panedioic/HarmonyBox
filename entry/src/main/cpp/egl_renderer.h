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
private:
    void RenderLoop();
    OHNativeWindow* window_ = nullptr;
    EGLDisplay eglDisp_ = EGL_NO_DISPLAY;
    EGLContext eglCtx_  = EGL_NO_CONTEXT;
    EGLSurface eglSurf_ = EGL_NO_SURFACE;
    GLuint tex_ = 0, prog_ = 0, vbo_ = 0;
    int width_ = 0, height_ = 0;
    std::thread th_;
    std::atomic<bool> running_{false};
};