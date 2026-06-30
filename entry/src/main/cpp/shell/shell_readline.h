#ifndef HBOX_SHELL_READLINE_H
#define HBOX_SHELL_READLINE_H

#include <functional>
#include <string>
#include <vector>

namespace shell {

// 回调: readline 产生输出时调用
using ReadlineWriteFn = std::function<void(const std::string&)>;

// 回调: 一行完成时调用 (trimmed line)
using ReadlineCommitFn = std::function<void(const std::string&)>;

class ShellReadline {
public:
    void Init(ReadlineWriteFn write_fn, ReadlineCommitFn commit_fn);
    void Feed(const std::string& data);
    void SetPrompt(const std::string& prompt, int visible_len);
    void ShowPrompt();
    void Reset();  // 清空当前编辑状态，不输出

private:
    void HandleByte(unsigned char b);
    void HandleEscSeq(char final_ch);
    void InsertChar(char ch);
    void Backspace();
    void DeleteForward();
    void CursorLeft();
    void CursorRight();
    void CursorHome();
    void CursorEnd();
    void KillToEnd();
    void KillToStart();
    void SwapChars();       // Ctrl+T
    void ClearScreen();
    void Cancel();          // Ctrl+C
    void Submit();          // Enter
    void HistoryPrev();
    void HistoryNext();
    void RedrawLine();

    ReadlineWriteFn write_fn_;
    ReadlineCommitFn commit_fn_;

    // 行编辑状态
    std::string buf_;
    int cursor_ = 0;

    // prompt (含 ANSI，不算进光标位置)
    std::string prompt_;
    int prompt_visible_len_ = 0;

    // 转义状态机: 0=normal, 1=ESC, 2=ESC[, 3=ESC[3(等~)
    int esc_state_ = 0;
    std::string esc_param_;  // 中间参数字符（数字、分号）

    // 历史
    std::vector<std::string> history_;
    int history_idx_ = -1;
    std::string history_saved_;
    static constexpr int kMaxHistory = 500;
};

} // namespace shell

#endif