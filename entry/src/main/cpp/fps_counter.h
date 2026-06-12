#pragma once
#include <chrono>
#include <atomic>

#undef LOG_TAG
#define LOG_TAG "FPS"
#include <hilog/log.h>

class FpsCounter {
public:
    explicit FpsCounter(const char* tag) : tag_(tag) {
        last_ = std::chrono::steady_clock::now();
    }
    void Tick() {
        ++frames_;
        auto now = std::chrono::steady_clock::now();
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_).count();
        if (ms >= 1000) {
            double fps = frames_ * 1000.0 / ms;
            OH_LOG_INFO(LOG_APP, "[%{public}s] fps=%{public}.2f frames=%{public}d in %{public}lldms",
                        tag_, fps, (int)frames_, (long long)ms);
            frames_ = 0;
            last_ = now;
        }
    }
private:
    const char* tag_;
    std::chrono::steady_clock::time_point last_;
    int frames_ = 0;
};