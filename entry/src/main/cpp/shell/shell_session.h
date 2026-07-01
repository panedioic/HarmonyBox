#ifndef HBOX_SHELL_SESSION_H
#define HBOX_SHELL_SESSION_H

#include <string>

namespace shell {

// 会话日志: 每次 Init 开一个带时间戳的新文件,
// 命令输出经 ANSI 剥离后追加写入. 启动时清理旧文件.
class ShellSession {
public:
    bool Init(const std::string& log_dir);
    void Shutdown();

    // 写入命令产生的输出 (会做 ANSI 剥离)
    void Append(const std::string& data);

    // 写入"已格式化"的合成行 (如 "$ ls\n"), 不做 ANSI 处理
    void AppendDirect(const std::string& line);

    void Flush();

    const std::string& GetLogPath() const { return log_path_; }
    bool IsOpen() const { return log_fd_ >= 0; }

private:
    void WriteStripped(const std::string& data);
    void WriteRaw(const char* data, size_t len);
    static void RotateLogs(const std::string& dir, int keep);
    static std::string MakeTimestamp();

    static constexpr int kMaxLogs = 20;

    int log_fd_ = -1;
    std::string log_path_;
    int ansi_state_ = 0;
};

} // namespace shell

#endif