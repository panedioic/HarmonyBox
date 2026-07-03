#include "shell_jobs.h"
#include <unistd.h>

namespace shell {

void ShellJobs::Add(const ShellJob& job) {
    Item it;
    it.job = job;
    it.alive = true;
    it.exit_code = 0;
    items_.push_back(std::move(it));
}

void ShellJobs::MarkExited(pid_t pid, int code) {
    for (auto& it : items_) {
        if (it.job.pid == pid && it.alive) {
            it.alive = false;
            it.exit_code = code;
            if (it.job.log_fd >= 0) {
                close(it.job.log_fd);
                it.job.log_fd = -1;
            }
        }
    }
}

bool ShellJobs::Has(pid_t pid) const {
    for (auto& it : items_) if (it.job.pid == pid) return true;
    return false;
}

const ShellJob* ShellJobs::Get(pid_t pid) const {
    for (auto& it : items_) if (it.job.pid == pid) return &it.job;
    return nullptr;
}

std::vector<ShellJob> ShellJobs::All() const {
    std::vector<ShellJob> out;
    out.reserve(items_.size());
    for (auto& it : items_) out.push_back(it.job);
    return out;
}

std::vector<pid_t> ShellJobs::FindByLabel(const std::string& label) const {
    std::vector<pid_t> out;
    for (auto& it : items_) {
        if (it.alive && it.job.label == label) out.push_back(it.job.pid);
    }
    return out;
}

void ShellJobs::CloseLogFd(pid_t pid) {
    for (auto& it : items_) {
        if (it.job.pid == pid && it.job.log_fd >= 0) {
            close(it.job.log_fd);
            it.job.log_fd = -1;
        }
    }
}

void ShellJobs::Clear() {
    for (auto& it : items_) {
        if (it.job.log_fd >= 0) close(it.job.log_fd);
    }
    items_.clear();
}

} // namespace shell