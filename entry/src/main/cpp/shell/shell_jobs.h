#ifndef HBOX_SHELL_JOBS_H
#define HBOX_SHELL_JOBS_H

#include <string>
#include <vector>
#include <sys/types.h>

namespace shell {

struct ShellJob {
    pid_t pid;
    std::string label;      // 便于识别, 如 "wineserver"
    std::string log_path;
    int log_fd;             // 由 ShellJobs 持有, dtor 里关
    int64_t start_ms;
};

class ShellJobs {
public:
    void Add(const ShellJob& job);
    void MarkExited(pid_t pid, int code);   // 由 async exit event 调
    bool Has(pid_t pid) const;
    const ShellJob* Get(pid_t pid) const;
    std::vector<ShellJob> All() const;
    std::vector<pid_t> FindByLabel(const std::string& label) const;
    void CloseLogFd(pid_t pid);              // exit 时关 fd, 保留记录
    void Clear();                            // shell shutdown 时清理

private:
    struct Item {
        ShellJob job;
        bool alive;
        int exit_code;
    };
    std::vector<Item> items_;
};

} // namespace shell

#endif