// egl_renderer.cpp（要点）
#include "egl_renderer.h"
#include "wayland_server.h"
#include <vector>
#include <unistd.h>

#include "fps_counter.h"

#undef LOG_TAG
#define LOG_TAG "WL_EGL"
#include <hilog/log.h>

#define EGL_CHECK(x) do { \
    auto v = (x); \
    EGLint e = eglGetError(); \
    if (e != EGL_SUCCESS) { \
        OH_LOG_ERROR(LOG_APP, #x " egl err=0x%{public}x", e); \
    } \
} while(0)

static const char* kVS = R"(#version 300 es
layout(location=0) in vec2 aPos;
layout(location=1) in vec2 aUV;
out vec2 vUV;
void main(){ vUV = aUV; gl_Position = vec4(aPos,0,1);} )";

static const char* kFS = R"(#version 300 es
precision mediump float;
in vec2 vUV; out vec4 oColor;
uniform sampler2D uTex;
void main(){ oColor = texture(uTex, vUV).bgra; } // wl 是 ARGB little-endian = BGRA 内存序
)";

static GLuint compile(GLenum t, const char* src) {
    GLuint s = glCreateShader(t);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024] = {0};
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        OH_LOG_ERROR(LOG_APP, "shader compile failed: %{public}s", log);
    }
    return s;
}

static void linkCheck(GLuint p) {
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024] = {0};
        glGetProgramInfoLog(p, sizeof(log), nullptr, log);
        OH_LOG_ERROR(LOG_APP, "program link failed: %{public}s", log);
    }
}

bool EglRenderer::Init(OHNativeWindow* w, int width, int height) {
    window_ = w; width_ = width; height_ = height;
    
//    eglDisp_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
//    eglInitialize(eglDisp_, nullptr, nullptr);
    eglDisp_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (eglDisp_ == EGL_NO_DISPLAY) { OH_LOG_ERROR(LOG_APP, "no egl display"); return false; }
    EGLint major = 0, minor = 0;
    if (!eglInitialize(eglDisp_, &major, &minor)) {
        OH_LOG_ERROR(LOG_APP, "eglInitialize failed 0x%{public}x", eglGetError()); return false;
    }
    OH_LOG_INFO(LOG_APP, "egl %{public}d.%{public}d", major, minor);
    
    EGLConfig cfg; EGLint nCfg;
    EGLint attrs[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                       EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
                       EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
    eglChooseConfig(eglDisp_, attrs, &cfg, 1, &nCfg);
    EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    eglCtx_ = eglCreateContext(eglDisp_, cfg, EGL_NO_CONTEXT, ctxAttrs);
    // ↓↓↓ 关键：OHOS 上 EGLNativeWindowType 是 unsigned long
    eglSurf_ = eglCreateWindowSurface(eglDisp_, cfg,
                                      reinterpret_cast<EGLNativeWindowType>(window_),
                                      nullptr);
    
    if (eglSurf_ == EGL_NO_SURFACE) {
        OH_LOG_ERROR(LOG_APP, "eglCreateWindowSurface failed 0x%{public}x", eglGetError());
        return false;
    }
    
    running_ = true;
    th_ = std::thread(&EglRenderer::RenderLoop, this);
    return true;
}

void EglRenderer::RenderLoop() {
    if (!eglMakeCurrent(eglDisp_, eglSurf_, eglSurf_, eglCtx_)) {
        OH_LOG_ERROR(LOG_APP, "eglMakeCurrent failed 0x%{public}x", eglGetError());
        return;
    }

    // 着色器
    GLuint vs = compile(GL_VERTEX_SHADER, kVS);
    GLuint fs = compile(GL_FRAGMENT_SHADER, kFS);
    prog_ = glCreateProgram();
    glAttachShader(prog_, vs); glAttachShader(prog_, fs);
    glLinkProgram(prog_);

    // 全屏 quad
    float quad[] = {
        -1,-1, 0,1,   1,-1, 1,1,   -1,1, 0,0,
         1,-1, 1,1,   1, 1, 1,0,   -1,1, 0,0,
    };
    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);

    glGenTextures(1, &tex_);
    glBindTexture(GL_TEXTURE_2D, tex_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    
    FpsCounter fps("render");

    std::vector<uint8_t> px;
    int fw = 0, fh = 0;

    while (running_) {
        if (WaylandServer::GetInstance()->TakeLatestFrame(px, fw, fh) && fw>0 && fh>0) {
            glBindTexture(GL_TEXTURE_2D, tex_);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, fw, fh, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, px.data());
        }

        glViewport(0, 0, width_, height_);
        glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);

        glUseProgram(prog_);
        glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,16,(void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1,2,GL_FLOAT,GL_FALSE,16,(void*)8);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex_);
        glUniform1i(glGetUniformLocation(prog_, "uTex"), 0);
        glDrawArrays(GL_TRIANGLES, 0, 6);

        eglSwapBuffers(eglDisp_, eglSurf_);
        fps.Tick();
        usleep(16667);
    }
}

void EglRenderer::Shutdown() {
    running_ = false;
    if (th_.joinable()) th_.join();
    if (eglDisp_ != EGL_NO_DISPLAY) {
        eglMakeCurrent(eglDisp_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (eglSurf_ != EGL_NO_SURFACE) eglDestroySurface(eglDisp_, eglSurf_);
        if (eglCtx_  != EGL_NO_CONTEXT) eglDestroyContext(eglDisp_, eglCtx_);
        eglTerminate(eglDisp_);
        eglDisp_ = EGL_NO_DISPLAY;
        eglCtx_  = EGL_NO_CONTEXT;
        eglSurf_ = EGL_NO_SURFACE;
    }
}