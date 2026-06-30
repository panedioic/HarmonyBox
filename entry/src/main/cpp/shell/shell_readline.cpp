#include "shell_readline.h"

namespace shell {

void ShellReadline::Init(ReadlineWriteFn write_fn, ReadlineCommitFn commit_fn) {
    write_fn_ = std::move(write_fn);
    commit_fn_ = std::move(commit_fn);
    buf_.clear();
    cursor_ = 0;
    esc_state_ = 0;
    history_idx_ = -1;
}

void ShellReadline::SetPrompt(const std::string& prompt, int visible_len) {
    prompt_ = prompt;
    prompt_visible_len_ = visible_len;
}

void ShellReadline::ShowPrompt() {
    write_fn_(prompt_);
}

void ShellReadline::Reset() {
    buf_.clear();
    cursor_ = 0;
    esc_state_ = 0;
    history_idx_ = -1;
    history_saved_.clear();
}

void ShellReadline::Feed(const std::string& data) {
    for (size_t i = 0; i < data.size(); ++i) {
        HandleByte(static_cast<unsigned char>(data[i]));
    }
}

void ShellReadline::HandleByte(unsigned char b) {
    // ESC 状态机
    if (esc_state_ == 1) {
        if (b == '[') {
            esc_state_ = 2;
            esc_param_.clear();
            return;
        }
        if (b == 'O') {
            esc_state_ = 4;  // SS3 序列 (Home/End on some terminals)
            return;
        }
        // 非 CSI/SS3: 丢弃
        esc_state_ = 0;
        return;
    }
    if (esc_state_ == 2) {
        // CSI 参数或中间字节
        if (b >= '0' && b <= '9') { esc_param_.push_back((char)b); return; }
        if (b == ';') { esc_param_.push_back(';'); return; }
        // final byte
        if (b == '~') {
            // 特殊键: ESC [ 3 ~ = Delete, ESC [ 1 ~ = Home, ESC [ 4 ~ = End
            if (esc_param_ == "3") DeleteForward();
            else if (esc_param_ == "1") CursorHome();
            else if (esc_param_ == "4") CursorEnd();
            esc_state_ = 0;
            return;
        }
        HandleEscSeq((char)b);
        esc_state_ = 0;
        return;
    }
    if (esc_state_ == 4) {
        // SS3: ESC O H = Home, ESC O F = End
        if (b == 'H') CursorHome();
        else if (b == 'F') CursorEnd();
        esc_state_ = 0;
        return;
    }

    // 非转义
    if (b == 0x1b) { esc_state_ = 1; return; }  // ESC

    switch (b) {
        case 0x0d:  Submit(); return;            // Enter (CR)
        case 0x0a:  return;                      // LF: ignore
        case 0x7f:  // fallthrough
        case 0x08:  Backspace(); return;         // Backspace/DEL
        case 0x03:  Cancel(); return;            // Ctrl+C
        case 0x0c:  ClearScreen(); return;       // Ctrl+L
        case 0x01:  CursorHome(); return;        // Ctrl+A
        case 0x05:  CursorEnd(); return;         // Ctrl+E
        case 0x0b:  KillToEnd(); return;         // Ctrl+K
        case 0x15:  KillToStart(); return;       // Ctrl+U
        case 0x14:  SwapChars(); return;         // Ctrl+T
        case 0x09:  return;                      // TAB: M2 不做补全
        case 0x04:                               // Ctrl+D
            if (buf_.empty()) {
                // EOF on empty line - 可选: 显示 exit 提示
                write_fn_("^D\r\n");
            } else {
                DeleteForward();
            }
            return;
        default: break;
    }

    // 可打印字符 (包括 UTF-8 后续字节)
    if (b >= 0x20) {
        InsertChar((char)b);
    }
}

void ShellReadline::HandleEscSeq(char final_ch) {
    switch (final_ch) {
        case 'A': HistoryPrev(); break;     // Up
        case 'B': HistoryNext(); break;     // Down
        case 'C': CursorRight(); break;     // Right
        case 'D': CursorLeft(); break;      // Left
        case 'H': CursorHome(); break;      // Home (xterm)
        case 'F': CursorEnd(); break;       // End (xterm)
        default: break;                     // 其它忽略
    }
}

void ShellReadline::InsertChar(char ch) {
    buf_.insert(buf_.begin() + cursor_, ch);
    cursor_++;
    if (cursor_ == (int)buf_.size()) {
        // 末尾追加: 直接输出字符, 不用重画整行
        write_fn_(std::string(1, ch));
    } else {
        RedrawLine();
    }
}

void ShellReadline::Backspace() {
    if (cursor_ <= 0) return;
    buf_.erase(cursor_ - 1, 1);
    cursor_--;
    if (cursor_ == (int)buf_.size()) {
        // 在末尾: 简单回退
        write_fn_("\b \b");
    } else {
        RedrawLine();
    }
}

void ShellReadline::DeleteForward() {
    if (cursor_ >= (int)buf_.size()) return;
    buf_.erase(cursor_, 1);
    RedrawLine();
}

void ShellReadline::CursorLeft() {
    if (cursor_ > 0) {
        cursor_--;
        write_fn_("\x1b[D");
    }
}

void ShellReadline::CursorRight() {
    if (cursor_ < (int)buf_.size()) {
        cursor_++;
        write_fn_("\x1b[C");
    }
}

void ShellReadline::CursorHome() {
    if (cursor_ > 0) {
        write_fn_("\x1b[" + std::to_string(cursor_) + "D");
        cursor_ = 0;
    }
}

void ShellReadline::CursorEnd() {
    int d = (int)buf_.size() - cursor_;
    if (d > 0) {
        write_fn_("\x1b[" + std::to_string(d) + "C");
        cursor_ = (int)buf_.size();
    }
}

void ShellReadline::KillToEnd() {
    if (cursor_ >= (int)buf_.size()) return;
    buf_.erase(cursor_);
    write_fn_("\x1b[K");
}

void ShellReadline::KillToStart() {
    if (cursor_ <= 0) return;
    buf_.erase(0, cursor_);
    cursor_ = 0;
    RedrawLine();
}

void ShellReadline::SwapChars() {
    if (cursor_ < 2 || buf_.size() < 2) return;
    std::swap(buf_[cursor_ - 2], buf_[cursor_ - 1]);
    RedrawLine();
}

void ShellReadline::ClearScreen() {
    write_fn_("\x1b[2J\x1b[H");
    ShowPrompt();
    write_fn_(buf_);
    int back = (int)buf_.size() - cursor_;
    if (back > 0) {
        write_fn_("\x1b[" + std::to_string(back) + "D");
    }
}

void ShellReadline::Cancel() {
    write_fn_("^C\r\n");
    buf_.clear();
    cursor_ = 0;
    history_idx_ = -1;
    history_saved_.clear();
    ShowPrompt();
}

void ShellReadline::Submit() {
    write_fn_("\r\n");
    std::string line = buf_;
    buf_.clear();
    cursor_ = 0;

    // 去重加入历史
    std::string trimmed = line;
    while (!trimmed.empty() && (trimmed.back() == ' ' || trimmed.back() == '\t'))
        trimmed.pop_back();
    while (!trimmed.empty() && (trimmed.front() == ' ' || trimmed.front() == '\t'))
        trimmed.erase(trimmed.begin());

    if (!trimmed.empty()) {
        if (history_.empty() || history_.back() != trimmed) {
            history_.push_back(trimmed);
            if ((int)history_.size() > kMaxHistory) {
                history_.erase(history_.begin());
            }
        }
    }
    history_idx_ = -1;
    history_saved_.clear();

    // 交给上层处理
    if (commit_fn_) commit_fn_(trimmed);
}

void ShellReadline::HistoryPrev() {
    if (history_.empty()) return;
    if (history_idx_ == -1) {
        history_saved_ = buf_;
        history_idx_ = (int)history_.size() - 1;
    } else if (history_idx_ > 0) {
        history_idx_--;
    } else {
        return;
    }
    buf_ = history_[history_idx_];
    cursor_ = (int)buf_.size();
    RedrawLine();
}

void ShellReadline::HistoryNext() {
    if (history_idx_ == -1) return;
    if (history_idx_ < (int)history_.size() - 1) {
        history_idx_++;
        buf_ = history_[history_idx_];
    } else {
        history_idx_ = -1;
        buf_ = history_saved_;
        history_saved_.clear();
    }
    cursor_ = (int)buf_.size();
    RedrawLine();
}

void ShellReadline::RedrawLine() {
    // 回到行首（跳过 prompt），清到行尾，重绘 buffer，定位光标
    std::string out;
    out += "\r";                         // 回到行首
    out += prompt_;                      // 重画 prompt
    out += buf_;                         // 重画 buffer
    out += "\x1b[K";                     // 清除 cursor 后残留
    // 把光标移到正确位置
    int back = (int)buf_.size() - cursor_;
    if (back > 0) {
        out += "\x1b[" + std::to_string(back) + "D";
    }
    write_fn_(out);
}

} // namespace shell