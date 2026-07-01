#ifndef HBOX_SHELL_ENV_H
#define HBOX_SHELL_ENV_H

#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace shell {

class ShellEnv {
public:
    // persist_path 为空表示不做持久化
    void Init(const std::string& persist_path);

    // 由 ArkTS 注入的初始 env (BOX64_LD_LIBRARY_PATH 等)
    // 会与持久化文件里的用户 env 合并, 用户 shell vars 覆盖之
    void SetSystemVar(const std::string& key, const std::string& val);

    // 由 ArkTS 声明只读 (用户无法 export/unset)
    void AddReadonly(const std::string& key);

    // 返回值:
    //   0 = ok, 1 = readonly 拒绝, 2 = 持久化写失败 (仍然 in-memory 生效)
    int Set(const std::string& key, const std::string& val, bool persistent);
    int Unset(const std::string& key, bool persistent);

    bool Has(const std::string& key) const;
    std::string Get(const std::string& key) const;
    bool IsReadonly(const std::string& key) const;
    bool IsPersistent(const std::string& key) const;

    // (key, value, {readonly, persistent}) 排序输出
    struct Entry {
        std::string key;
        std::string val;
        bool readonly;
        bool persistent;
    };
    std::vector<Entry> All() const;

    // 供 spawn 使用: 合并 system + shell vars, 生成 "KEY=VAL" 数组
    // shell vars 覆盖同名 system var
    std::vector<std::string> BuildEnvArray() const;

private:
    void LoadPersist();
    bool SavePersist();

    std::string persist_path_;
    std::unordered_map<std::string, std::string> system_vars_;
    std::unordered_map<std::string, std::string> shell_vars_;
    std::unordered_set<std::string> persistent_keys_;
    std::unordered_set<std::string> readonly_keys_;
};

} // namespace shell

#endif