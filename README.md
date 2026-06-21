# HarmonyBox

> 在 HarmonyOS 6.0+ 上运行 x86_64 Linux / Windows 应用程序的兼容层启动器。

HarmonyBox 在 HarmonyOS 应用沙箱里跑了一个**完整的 Wayland Compositor**,配合 [box64](https://github.com/ptitSeb/box64) 把 x86_64 的 syscall 翻译给 ARM64 执行;Windows 应用再额外经 [Wine](https://www.winehq.org/) 翻一层。客户端的 buffer 通过 EGL/OpenGL ES 渲染到 `XComponent` 上。最终用户得到的体验是:**点击图标 → 弹出子窗口 → 程序就跑起来了**,和原生鸿蒙应用一样。

> ⚙️ box64 现已作为**动态库** `libbox64.so` 集成,通过 `fork + dlopen + box64_run` 在子进程内调用,避免了对 HNP 二进制部署的依赖。**不通过父进程 dlopen 该库** —— OHOS LSM 可能会因此剥掉所有 fork 后代进程的 `PROT_EXEC` 权限,dynarec 与 mmap RWX 全失败。详见 [HAP execmem 限制](#hap-execmem-限制与so-化路线)。

---

## ✨ 核心特性

- 🪟 **应用库**:列表展示已安装应用,每个应用一个独立子窗口;卡片绿点指示运行状态
- 📦 **安装向导**:选择本地文件夹 → 自动复制到沙箱 → 写注册表
- 🍷 **Wine 集成**:在设置页一键将 wine 目录导入沙箱,自动 chmod,可探测版本,可重建 prefix
- 🧩 **运行时资源管理**:在设置页一键导入 weston / xkbcommon 等运行时资源目录到沙箱,支持安装 / 重新安装 / 卸载
- 📋 **混合模式**:「启动并显示日志」GUI 与 CLI 双窗口联动
- 🪟 **窗口控件**:客户端 CSD 的最小化 / 最大化 / 拖拽 / 调整大小都映射到鸿蒙窗口
- 🔍 **DPI 缩放**:按用户设定整体放大客户端画面,方便高分屏
- 🎛️ **沉浸式开关**:可选显示鸿蒙系统标题栏,让客户端 CSD 自管
- 🅰️ **字体管理**:上传 .ttf/.otf,自动生成 fontconfig 配置注入子进程

---

## 📊 当前状态

### box64 测试矩阵(终端环境)

| 组合 | 状态 |
|------|------|
| box64 x86_64 Linux | ✅ PASS |
| box64 i386 Linux | ✅ PASS |
| wine x86_64 Windows | 🟡 待验证 |

---

## 🏗️ 架构总览

```
┌──────────────────────────────────────────────────────────┐
│                      ArkTS (UI 层)                        │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────┐   │
│  │   Index     │  │  AppRunner   │  │   CliRunner    │   │
│  │ (启动器主页) │  │ (GUI 子窗口)  │  │ (终端子窗口)    │   │
│  └──────┬──────┘  └──────┬───────┘  └────────┬───────┘   │
│         │                │                    │           │
│  ┌──────▼──────────┐  ┌──▼─────────────────────▼──────┐  │
│  │  WaylandService │  │      CliService                │  │
│  │  仅 wayland 相关 │  │   统一启动入口 launchBox64(opts)│  │
│  │  - server 生命   │  │   - 模式 A: 纯 CLI             │  │
│  │  - GUI 槽位       │  │   - 模式 B: 纯 GUI(无日志)      │  │
│  │  - 输入/窗口事件  │  │   - 模式 C: GUI + 日志         │  │
│  │  - waitActive    │  │   - 订阅 / 缓冲 / 终止          │  │
│  └─┬──────────┬────┘  └─────────────┬───────────────────┘ │
│    │          │                      │                     │
│ ┌──▼──┐ ┌─────▼────┐ ┌─────────┐ ┌──▼───────┐ ┌────────┐ │
│ │Wine │ │FontStore │ │LibStore │ │Resource │ │ToolEnv │ │
│ │Svc  │ │(fc-conf) │ │(x64libs)│ │Service  │ │Store   │ │
│ └─────┘ └──────────┘ └─────────┘ └──────────┘ └────────┘ │
└──────────────────┬───────────────────────────────────────┘
                   │ NAPI ABI(libentry.so)
┌──────────────────▼────────────────────────────────────────┐
│                   C++ (Native 层)                          │
│                                                            │
│  ┌─── napi 边界 ────────────────────────────────────────┐ │
│  │  napi_init.cpp       (注册表)                         │ │
│  │  napi_utils.*        (字符串/数组/无参回调通用工具)     │ │
│  │  fs_utils.*          (chmod / EnsureExecutable)       │ │
│  │  process_runner.*    (★ RunBox64/RunCommand/Terminate)│ │
│  │  client_napi.*       (旧 launch* 兼容壳)               │ │
│  │  input_window_napi.* (键鼠/窗口事件)                   │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                            │
│  ┌──────────────────┐  ┌─────────────────────┐            │
│  │  WaylandServer   │  │   PluginManager     │            │
│  │  - wl_compositor │  │   (XComponent 接管)  │            │
│  │  - xdg-shell     │  │                     │            │
│  │  - wl_seat       │  └──────────┬──────────┘            │
│  │  - wl_shm        │             │                        │
│  │  + window_geom   │  ┌──────────▼──────────┐            │
│  │  + max/min/move  │  │     EglRenderer     │            │
│  │    /resize 钩子   │  │  (EGL + GLES3 上屏)  │            │
│  └─────────┬────────┘  └─────────────────────┘             │
└────────────┼───────────────────────────────────────────────┘
             │ fork (在 HAP 子进程内)
             ▼  dlopen libbox64.so + box64_run(argc, argv, env)
       ┌───────────┐         ┌───────────┐
       │   box64   │ ◄────── │   wine    │   ◄── (仅 windows app)
       │ x86_64→A64│         │ ELF + PE  │
       └─────┬─────┘         └─────┬─────┘
             ▼                     ▼
        ┌──────────────────────────────┐
        │  x86_64 Linux 或 Windows App │
        │      (Wayland client)         │
        └──────────────────────────────┘
```

---

## 🛠️ 技术栈

| 层 | 技术 |
|---|---|
| UI | ArkTS / ArkUI(HarmonyOS NEXT API 12+) |
| 跨语言桥接 | NAPI (`libentry.so`) |
| Compositor | Wayland Server(`libwayland-server`) |
| 协议扩展 | xdg-shell-v3(自实现,支持 geometry / max / min / move / resize) |
| 渲染 | EGL + OpenGL ES 3.0 |
| 进程模型 | fork + 子进程 dlopen `libbox64.so` + `box64_run()` + pipe(stdout/err 流式回 JS) |
| 兼容层 | box64(动态库, OHOS musl 兼容 patch) + wine 10.0+ WoW64(沙箱内) |
| 字体 | fontconfig(动态生成 conf) |
| 持久化 | JSON(`filesDir/apps.json` + `tool_env.json`) |

---

## 📁 目录结构

```
HarmonyBox/
├── entry/                              # 鸿蒙 HAP 工程
│   ├── libs/arm64-v8a/                 # 预编译依赖
│   │   ├── libbox64.so                 # box64 动态库 (必须)
│   │   ├── libwayland-server.so        # 适用鸿蒙的 Wayland Server (必须)
│   │   ├── libwayland-client.so
│   │   ├── libwayland-cursor.so
│   │   ├── libwayland-egl.so
│   │   ├── libffi.so                   # （可选）将 x86 的 libffi warp 到鸿蒙原生
│   │   └── libexpat.so                 # （可选）将 x86 的 libexpat warp 到鸿蒙原生
│   │   └── ......
│   ├── src/main/
│   │   ├── ets/
│   │   │   ├── pages/                  # 三个 @Entry 页面
│   │   │   │   ├── Index.ets           # 唯一启动入口
│   │   │   │   ├── AppRunner.ets       # GUI 应用显示页面
│   │   │   │   ├── CliRunner.ets       # Cli 应用显示页面
│   │   │   │   └── DebugPage.ets       # （调试用）
│   │   │   ├── components/             # 可复用的 UI 组件
│   │   │   │   ├── LibraryPage.ets     # 应用库主页。
│   │   │   │   ├── InstallPage.ets     # 安装向导：选类型 → 选目录 → 填路径 → 写注册表。
│   │   │   │   ├── SettingsPage.ets    # 设置页
│   │   │   │   ├── EditAppDialog.ets   # 编辑应用信息对话框。
│   │   │   │   └── Sidebar.ets         # 左侧固定宽 220 的导航栏。
│   │   │   ├── service/                # 业务服务层（全部单例或纯静态类）
│   │   │   │   ├── WaylandService.ets  # Wayland NAPI 的 ArkTS 门面 + GUI 单例槽 + UI prefs 缓存 + 事件分发。
│   │   │   │   ├── CliService.ets      # 统一启动入口 + box64 命令行/环境变量构造 + streaming 输出订阅。
│   │   │   │   ├── InstallService.ets  # 文件夹/文件选择 + URI ↔ 本地路径 + 递归复制 + 安装/卸载。
│   │   │   │   ├── WineService.ets     # Wine 沙箱安装与启动 env 构造。
│   │   │   │   ├── FontStore.ets       # 用户字体管理 + 动态生成 fonts.conf 注入 fontconfig。
│   │   │   │   ├── LibStore.ets        # 用户上传的 x86_64 .so 库管理。
│   │   │   │   ├── ResourceService.ets # 通用运行时资源目录管理（weston / xkbcommon 等）。
│   │   │   │   └── ToolDetector.ets    # HNP 安装的命令行工具探测（box64 / elf-loader / proot）+ wine 状态聚合。
│   │   │   ├── model/                  # 数据模型与持久化
│   │   │   │   ├── AppInfo.ets         # 应用元数据的核心数据类型。
│   │   │   │   ├── AppRegistry.ets     # 注册表的读写门面（无内存缓存，每次 IO）。
│   │   │   │   ├── ToolEnvStore.ets    # 用户偏好的统一持久化（tool_env.json）。
│   │   │   │   └── RunningWindow.ets   # 已打开子窗口的全局单例 Map。
│   │   │   └── common/                 # 公共常量与映射表
│   │   │       ├── Theme.ets           # 全局视觉常量与页面 ID 枚举。
│   │   │       ├── KeyMap.ets          # 鸿蒙键码 → Linux evdev 键码的转换表 + 修饰键状态计算。
│   │   │       └── MouseMap.ets        # ArkUI 鼠标按钮 → Linux evdev 按钮码的转换表。
│   │   ├── cpp/
│   │   │   ├── napi_init.cpp           # NAPI 注册表
│   │   │   ├── napi_utils.*            # 通用工具
│   │   │   ├── fs_utils.*              # chmod / EnsureExecutable
│   │   │   ├── process_runner.*        # RunBox64/RunCommand/Terminate
│   │   │   ├── client_napi.*           # 已 Deprecated 旧 launch* 兼容壳(逐步淘汰)
│   │   │   ├── input_window_napi.*     # 键鼠 + 窗口事件
│   │   │   ├── wayland_server.*        # 适用鸿蒙的 Wayland Server
│   │   │   ├── xdg_shell.cpp           # xdg-shell-v3 协议扩展
│   │   │   ├── plugin_manager.*        # 将 Wayland 渲染至 ArkUI
│   │   │   ├── egl_renderer.*          # 将 Wayland 渲染至 ArkUI
│   │   │   ├── types/libentry/Index.d.ts
│   │   │   └── CMakeLists.txt
│   │   └── module.json5
│   └── build-profile.json5
│
├── build-box64/                        # box64 动态库构建(产出 libbox64.so)
│   ├── build_box64.sh                  # box64 主构建脚本
│   └── patches.sh                      # box64 补丁集
│
├── hpkbuilds/                          # ★ lycium hpkbuild,三方依赖编译配方
│   ├── wayland/                        # libwayland-server / -client / -cursor / -egl
│   ├── libffi/                         # libffi
│   ├── expat/                          # libexpat
│   └── ...                             # 其它(weston / xkbcommon / fontconfig 等可选)
│
├── AppScope/
└── README.md                           # 本文档
```

`build-box64/` 与 `hpkbuilds/` 是构建期工件,不进入 HAP。最终只有产物 `.so` 被拷到 `entry/libs/arm64-v8a/`。

---

## 🚀 构建流程

完整的"从零到 HAP"分三步走:**构建 box64 + 三方库 → 集成进 entry/libs → 编译 HAP**。

### 0. 前置环境

主机:

- Linux x86_64
- HarmonyOS NDK SDK,默认路径 `/workspace/ohos-sdk/linux`
- DevEco Studio 6.0+
- box64 测试程序:`gcc` + `gcc-multilib`,可选 `musl-tools`
- wine 编译:`gcc` + `mingw-w64`(`x86_64-w64-mingw32-gcc`、`i686-w64-mingw32-gcc`)
- lycium 工具链(用于 `hpkbuilds/` 下的三方库构建)

设备:

- HarmonyOS 6.0+, arm64
- 真机调试 (支持 PC / tablet，手机端未验证)

### 1. 构建 libbox64.so

```bash
cd build-box64

# 第一次:克隆上游
git clone https://github.com/ptitSeb/box64.git ./box64
git clone --depth=1 --branch wine-10.0 \
    https://gitlab.winehq.org/wine/wine.git ./wine

# 应用 patch 并编译
bash scripts/build_box64.sh

# 产物: build-box64/out/libbox64.so
```

`patches.sh` 是幂等的:每个 patch 在源码里写入唯一标记,重复执行自动跳过。任一 patch 失败立即退出。完整的 patch 体系(38+ 个,涉及 OHOS musl 兼容、BOX32 i386 支持、HAP execmem 适配等)说明见 [`build-box64/README.md`](build-box64/README.md)。

可选:wine 编译(用于 Windows 应用支持)。

```bash
bash scripts/build_wine_for_box64.sh        # 30~50 分钟
bash scripts/pack_wine_for_device.sh        # 打包 out/wine_device.tgz
```

### 2. 构建三方依赖(lycium hpkbuilds)

`hpkbuilds/` 下放着各三方库的 hpkbuild 配方,通过 lycium 交叉编译为 OHOS arm64-v8a:

```bash
# 以 wayland 为例(其它库流程相同)
cd /workspace/tpc_c_cplus_plus/lycium
./build.sh libwayland              # 产出 libwayland-*.so
```

需要的库清单(对应 `entry/libs/arm64-v8a/` 里除 `libbox64.so` 外的全部):

- `libwayland-server.so` / `libwayland-client.so` / `libwayland-cursor.so` / `libwayland-egl.so`
- `libffi.so`
- `libexpat.so`

### 3. 集成 .so 到 HAP

```bash
# 可以直接运行打包脚本
python ./pack_libs.py
```

> 如果 `entry/libs/arm64-v8a` 中缺关键 .so,CMake 阶段就会 `FATAL_ERROR` 中止。临时绕过把 `entry/src/main/cpp/CMakeLists.txt` 里 `HBOX_PREBUILT_LIBS_DIR` 那段注释掉。

### 4. 编译 HAP

DevEco Studio 打开根目录,**Build → Build Hap(s)/APP(s)**,签名后 Run 到设备。

### 5. Wine 安装(可选,用于运行 Windows 程序)

1. 在 PC/WSL 上准备 wine 目录(可由 `build-box64/scripts/pack_wine_for_device.sh` 产出),结构:
   ```
   wine/
   ├── bin/                       # wine, wineserver, wineboot, ...
   ├── lib/x86_64/                # libgcc_s.so.1
   ├── lib/wine/x86_64-unix/      # ntdll.so 等
   ├── lib/wine/x86_64-windows/   # ntdll.dll 等
   └── share/wine/
   ```
2. 把目录推到设备某个可读位置(应用沙箱外都行)
3. HarmonyBox → 设置 → Wine → **安装 Wine** → 选该目录
4. 完成后设置页展示 `wine-10.0` 之类的版本号
5. 第一次跑 Windows 应用前可在调试页点 **重建 prefix** 让 wineboot 初始化干净的 prefix

> wine 必须包含 `lib/wine/x86_64-unix/winewayland.drv.so`,否则没法在 Wayland compositor 上输出。调试页有「wayland 检查」按钮可一键确认。

### 6. 运行时资源安装(weston / xkbcommon 等)

部分 wine / 客户端依赖额外的运行时资源(weston 嵌套合成器、xkbcommon 键盘映射库等),通过 **运行时资源** 入口管理:

1. 在 PC/WSL 上准备资源目录,推到设备
2. HarmonyBox → 设置 → **运行时资源** → 找到对应条目 → **安装** → 选目录
3. 系统会整树拷贝到 `filesDir/<name>/`(沙箱内)

资源类型不做版本号探测。新资源条目可直接在 `SettingsPage` 的 `refreshResources()` 里追加,底层 `ResourceService.pickAndInstall(ctx, name)` / `uninstall(ctx, name)` 已通用化。

### 7. x86_64 共享库 / 字体

设置页 → **X86_64 共享库** 上传应用依赖的 `.so`,路径自动拼到 `BOX64_LD_LIBRARY_PATH`。

设置页 → **字体** 上传 `.ttf/.otf`。HarmonyBox 动态生成 `fonts.conf`,启动子进程时通过 `FONTCONFIG_FILE` 注入。需要中文上传 Noto CJK。

---

## 🎮 使用说明

### 安装应用

1. 启动 HarmonyBox
2. 左侧菜单选择 **安装应用**
3. 选择应用类型:**Windows / Linux / 鸿蒙原生**
4. 选择 GUI 或 CLI 模式
5. 点击 **选择文件夹** 挑一个包含主程序的目录
6. 填写主可执行文件相对路径、应用名称、图标 emoji、可选环境变量与启动参数
7. 点 **开始安装**

### 启动应用

- 左键单击应用卡片:直接启动;窗口被最小化(隐藏)时自动恢复
- 右键应用卡片:**启动应用** / **启动并显示日志** / **编辑信息** / **查看路径** / **删除应用**

### 启动模式

`CliService.launchBox64(opts)` 用 `gui` + `streaming` 两个 bool 组合出三种合法模式:

| 模式 | gui |  用途 | 行为 |
|---|---|---|---|
| **A 纯 CLI** | false | 纯命令行应用启动 | 只开 CliRunner 终端窗口,实时显示 stdout/stderr,进程退出后窗口标题变 "已退出 (code)" |
| **B 纯 GUI** | true | GUI 普通启动 | 只开 AppRunner 图形窗口,无日志窗口;进程退出靠 callback 触发 `WaylandService.fireGuiExit` 自动关窗 |
| **C GUI + 日志** | true | GUI 带日志启动 | 同时开 CliRunner(日志) 与 AppRunner(画面),任一关闭对方跟着关 |

(`gui=false && streaming=false` 直接拒绝。)

三种模式底层统一走 `wl.runBox64(elfPath, argv, env, cwd, callback)`,callback 把 `(event, data)` 路由到 `CliService.handleStreamEvent`。

### 窗口控制

| 操作 | 行为 |
|---|---|
| 客户端 CSD 拖标题栏 | 调用 `startMoving` 拖动鸿蒙窗口 |
| 客户端最大化按钮 | 模拟最大化(resize + move 到屏幕可用区) |
| 客户端最小化按钮 | 隐藏子窗口;卡片仍带绿点;点卡片恢复 |
| 客户端关闭按钮 | 客户端进程退出 → 鸿蒙窗口自动关闭 |
| 拖客户端边框 | onMouse 接管,实时 resize host + 节流 configure 通知客户端重画 |

---

## 🔬 内部细节

### Wayland Compositor 协议覆盖

最小可用集合:`wl_compositor` v4 / `wl_surface` / `wl_shm` / `xdg_wm_base` v3 / `xdg_surface` / `xdg_toplevel`(set\_title / app\_id / max / min / move / resize 全部转发到 ArkTS) / `wl_seat` v5 / `wl_pointer` v5 / `wl_keyboard`。

特殊处理:

- **主 surface 锁定**:第一个提交 buffer 的 surface 绑定为 `mainSurface_`,其它 surface(cursor / popup)走 fast path,仅释放 buffer + 回 frame callback,不参与渲染
- **window geometry 裁剪**:通过 `set_window_geometry` 上报的子矩形裁掉客户端 CSD 阴影,鼠标坐标平移回 surface 系
- **首帧通知 + 尺寸通知**:fire `state=active` 与 `(w,h)` 让 ArkTS 创建并 resize 鸿蒙子窗口
- **idle dispatch**:从 ArkTS 线程下发 `xdg_toplevel.configure` 通过 `wl_event_loop_add_idle` 切到 wayland 主循环,避免线程争抢

### EGL 渲染管线

```
TakeLatestFrame() ──► std::vector<uint8_t> (BGRA, w, h)
       ▼
glTexImage2D(GL_RGBA)         ── shader 内 .bgra swizzle 修正
       ▼
glViewport(0, 0, vpW, vpH)    ── XComponent 实际像素
       ▼
glDrawArrays(quad)            ── letterbox 居中
       ▼
eglSwapBuffers                ── ~60 fps (usleep 16667)
```

### 进程启动链(box64 / wine)

所有 launch 都走 `proc::RunBox64`,父进程不感知 box64 实现,只负责:

1. **fork** 出 HAP 直系子进程
2. 子进程 unmap 父进程低 4GB 的 `[anon:ark*]` 段(让出 0x400000 给 ET\_EXEC 加载)
3. 子进程 `setenv` 应用 env(`LD_LIBRARY_PATH` / `XDG_RUNTIME_DIR` / `BOX64_*` 等)
4. 子进程 `dlopen("libbox64.so")` 然后 `dlsym("box64_run")`
5. 子进程调用 `box64_run(argc, argv, environ)`,从此交给 box64 dynarec
6. stdout/stderr 通过 pipe + tsfn 回到 ArkTS callback `(event, data) => void`,event 取值 `"out"` / `"exit"`

```
ArkTS App.type == WINDOWS
  └─► CliService.launchBox64({ useWine: true, gui: true, streaming: ... })
        argv = [ "box64"(标签), wine, exe, ...args ]
        env  = BOX64_LD_LIBRARY_PATH = appDir : x64libs : wine/lib/x86_64 : wine/lib/wine/x86_64-unix
               WINEPREFIX            = filesDir/wineprefix
               WINELOADER            = wine/bin/wine
               WINESERVER            = wine/bin/wineserver
               WAYLAND_DISPLAY/XDG_RUNTIME_DIR    (仅 GUI 模式注入)
               FONTCONFIG_FILE       = filesDir/fontconfig/fonts.conf
        └─► fork + dlopen libbox64.so + box64_run
              └─► (callback 流式回 JS,由 CliService 路由到 buffer/订阅者)
```

### HAP execmem 限制与 .so 化路线

HarmonyBox V3 阶段最关键的工程决定。**必读**。

#### 实验观测的 OHOS 内核 LSM 行为

```
HAP 主进程 (debug_hap)
  ├─ 出生时有 execmem (anon mmap RWX = OK)
  ├─ fork() ──► 子进程: execmem 继承 ✓
  │     └─ fork() ──► 孙: 继承 ✓ (实测 7 级深度全部 OK)
  │
  └─ execve(任何 ELF) ──► 进程自己: execmem 重新颁发 ✓
                          └─ fork() ──► 子: execmem 丢失 ✗
                                ├─ anon RWX = EINVAL
                                ├─ RW + mprotect RWX = EINVAL
                                └─ R-X 直接 = EINVAL
```

通过专门的 jitprobe HAP + 原生 fork\_chain\_test 二进制做的对照实验:

| 父进程怎么来 | 父 RWX | fork 子 RWX |
| --- | --- | --- |
| HAP 直接拉起 (jitprobe NAPI) | OK | OK |
| HAP fork 后代任意层 | OK | OK (无限层) |
| HAP execCapture → execve(box64) | OK | **EINVAL** |
| HAP NAPI execve 原生 HNP 二进制 | OK | **EINVAL** |
| HAP NAPI posix\_spawn(HNP) | OK | **EINVAL** |
| HAP NAPI fexecve(HNP) | OK | **EINVAL** |
| HAP NAPI fork+dlopen(任意 .so) | OK | **EINVAL** |
| 终端 (hishell\_hap 域) box64 | OK | OK |

关键事实:

- 限制不是 SELinux domain(父子都 `debug_hap`)
- 不是 NoNewPrivs / Seccomp / CapEff / MDWE,在 `/proc/self/status` 完全不暴露
- 只要父进程发生过一次"加载新 ELF"(execve 任何变体或 dlopen),从此 fork 子都丢 execmem
- box64 内部任何代码改动都救不了

#### .so 化路线

```
HAP main process (debug_hap, 有 execmem, fork 链全程保留)
  │
  ├── NAPI: runBox64(elfPath, argv, env, cwd, cb)
  │
  └── fork()  (子仍有 execmem)
       │
       └── child:
            unmap 低 4GB [anon:ark*]
            setenv ...
            dlopen("libbox64.so")    ← 必须在 fork 之后, HAP main 不能 dlopen
            box64_run(argc, argv, environ)
                 │
                 │  box64 内部 spawn x86 ELF (wineserver/wine 子进程) 时
                 │  必须用 fork-not-exec, 不能 dlopen 新 .so
                 ▼
                 fork() → grandchild → 直接调用 box64 内部入口
                                        (libbox64.so 已在地址空间, 仍有 execmem)
```

关键约束(违反就回到 EINVAL 死循环):

1. **HAP 主进程绝不 dlopen libbox64.so** —— 不仅可能会污染 HAP 自己的 signal handler / atexit / ArkTS 引擎状态,还会触发 execmem 失效,HAP 后续 fork 也会丢
2. **必须在 fork 子进程里 dlopen** —— 子进程是独立地址空间,污染不影响 HAP
3. **box64 内部 fork-not-exec 不要 dlopen** —— libbox64.so 在 fork 那一刻已经在地址空间里(fork 复制内存),直接函数调用即可
4. **wine CreateProcess 在 OHOS 上必须 in-process** —— wine 启动 Windows 子进程时内部会 fork+execve(wine, child.exe),execve 会丢 execmem,需 wine 侧 patch(尚未完成)

### 沙箱目录布局

```
{filesDir}/
├── apps.json
├── tool_env.json              # UiPrefs + box64 env
├── wl-sock                    # Wayland Unix socket
├── x64libs/                   # 用户上传 x86_64 .so
├── fonts/                     # 用户上传 ttf/otf
├── fontconfig/{fonts.conf,cache/}
├── wine/                      # 安装的 wine 根目录
├── wineprefix/                # WINEPREFIX
├── weston/                    # 通过运行时资源安装(可选)
├── xkbcommon/                 # 通过运行时资源安装(可选)
└── apps/
    └── app_*/
```

### NAPI 接口

完整签名见 `entry/src/main/cpp/types/libentry/Index.d.ts`,核心摘要:

```typescript
// === 新一代低层进程 API(主路径) ===
runBox64(
  elfPath: string,
  argv: string[],
  env: string[],
  cwd?: string,
  cb?: (event: string, data?: string) => void   // event: "out" | "exit"
): number;                                       // 返回 pid (>0) 或 -1

runCommand(
  exe: string,
  argv: string[],
  env: string[],
  cwd?: string,
  cb?: (event: string, data?: string) => void
): number;

terminate(pid: number): void;                    // SIGTERM + 800ms 后 SIGKILL

// === Wayland server / 单例客户端 ===
startWaylandServer(sockPath: string): boolean;
setStateCallback(cb: (state: string) => void): void;
setSizeCallback(cb: (w: number, h: number) => void): void;
getLatestSize(): { w: number; h: number };

// === 窗口控件钩子 ===
setMoveCallback(cb): void;
setMinimizeCallback(cb): void;
setMaximizeCallback(cb): void;
setUnmaximizeCallback(cb): void;
setResizeCallback(cb: (edges: number) => void): void;
requestClientResize(w: number, h: number, maximized: boolean): void;

// === 输入 ===
sendKey / sendModifiers / sendMouseMove / sendMouseButton / sendMouseAxis / sendMouseHover

// === 文件系统工具 ===
chmodDirFiles(dir: string): number;             // wine 安装时给 bin/ +x

// === 旧 API(标记淘汰)===
launchClient / stopClient / stopAll
launchCli    / stopCli    / setCliCallback
execCapture
```

ArkTS 侧上层封装:

- `CliService.launchBox64(opts)` —— 唯一启动入口,根据 `gui` / `streaming` 选模式
- `WaylandService.claimSlot/releaseSlot/waitActive` —— GUI 单例槽与首帧握手
- `WaylandService.fireGuiExit(appId)` —— B 模式从 callback 路由 exit 信号
- `ResourceService.pickAndInstall/uninstall/probe` —— 通用运行时资源管理

---

## ⚠️ 已知限制

| 项 | 说明 |
|---|---|
| **HAP 父进程禁 dlopen libbox64** | 任何对 `libbox64.so` 的父进程级 dlopen 都会让 OHOS LSM 剥掉 PROT_EXEC,代码已通过子进程 dlopen 规避;请勿在 NAPI 入口或常驻线程 dlopen 该库 |
| **wine CreateProcess 多进程** | wine 启动 Windows 子进程内部会 fork+execve,execve 会丢 execmem;需要 wine 侧 patch 改 in-process child(尚未完成) |
| GUI 单实例 | Compositor 当前一次只能承载一个 GUI 客户端,通过 `WaylandService.claimSlot` 拒绝并发 |
| Wine 必须自带 wayland driver | 没有 `winewayland.drv.so` 的 wine 包跑不了图形应用 |
| 输入法 | 暂不支持 `text-input-v3` |
| 剪贴板 | 暂不支持 `wl_data_device` |
| 音频 | 没有桥接 PulseAudio / PipeWire |
| 终端输入 | CLI 窗口为只读,stdin 双向通道未做 |
| 子窗口 minimize | 无法进 dock,按隐藏处理 |
| Wine 共享 prefix | 当前所有 Windows 应用共用一个 prefix,长期会互相污染 |
| 运行时资源不做完整性校验 | weston / xkbcommon 等只整树拷贝,坏目录会到运行时才报错 |
| BOX32 bring-up patch 残留 | patch 28 bump+LIFO allocator(256MB 上限)、patch 35 iomap(1024 槽 marker)非生产实现,长跑或大并发要扩容 |
| static 链接 | 不支持静态链接 guest |

---

## 🗺️ Roadmap

已完成:

- [x] 鸿蒙窗口随 Wayland buffer 自适应尺寸
- [x] 客户端 CSD 移动 / 最小化 / 最大化 / 拖拽 resize
- [x] DPI 缩放 / 字体管理 / Wine 集成 / 调试诊断页
- [x] BOX32 allocator (patch 28)
- [x] i386 glibc dynamic 14/14 PASS (patch 33-35)
- [x] wine-10.0 编译 + 终端 `wine --version`
- [x] **box64 .so 化改造**(patch 50-52),HAP 内 fork+dlopen+box64_run 跑通
- [x] 进程启动统一为 `runBox64` + per-call callback
- [x] WaylandService / CliService 职责拆分,三种启动模式归一
- [x] 通用运行时资源安装(weston / xkbcommon 等)

短期 P0:

- [ ] HAP 内 `wineboot --init` 跑通
- [ ] HAP 内 `wine notepad.exe` / `wine cmd.exe /c echo` smoke
- [ ] 跑真实小程序(busybox / bash / 简单 ncurses)smoke test
- [ ] 删除废弃诊断 patch (37/41/46-49)
- [ ] 资源安装时校验关键文件(weston `bin/weston`、xkbcommon `lib/libxkbcommon.so` 等)
- [ ] 资源版本号探测(读 VERSION 文件或执行 --version)
- [ ] 修复 SIGCHLD 残留,reader 线程拿真实 exit code
- [ ] 删除旧 NAPI(`launchClient` / `launchCli` / `execCapture`)

中期 P1:

- [ ] BOX32 allocator 换真 freelist (dlmalloc 类)
- [ ] iomap 换真 hash 表,扩容到无上限
- [ ] obstack / mutex \_\_kind 按 musl 真实 layout 实现
- [ ] 真 ucontext 支持
- [ ] **wine CreateProcess in-process 改造(wine 侧 patch)**
- [ ] 多 GUI 实例并发
- [ ] 应用级独立 wineprefix
- [ ] winecfg / regedit / explorer 快捷入口
- [ ] winetricks 集成
- [ ] `wl_data_device` 剪贴板桥接
- [ ] `text-input-v3` 输入法支持
- [ ] CLI 终端 stdin 双向(pty)
- [ ] 音频后端(pipewire-pulse)

长期 P2:

- [ ] AOT 缓存
- [ ] 64-bit static 启动崩溃定位与修复
- [ ] Steam 32-bit 客户端启动验证
- [ ] 应用图标自动从 ELF/desktop/PE 提取
- [ ] 配置面板:运行时修改环境/参数
- [ ] GPU 支持

---

## 🐛 调试技巧

### hilog 过滤

```bash
hdc hilog -r ; hdc hilog | grep -E "WL_Server|WL_EGL|WLXdg|WL_HBox|HBOX_"
```

各模块 TAG / ArkTS 前缀:

| TAG | 含义 |
|---|---|
| `WL_Server` | Wayland server 主流程 |
| `WLXdg` | xdg-shell 协议处理 |
| `WL_EGL` | EGL/OpenGL 渲染 |
| `WL_Plugin` | XComponent 回调 |
| `WL_HBox` | NAPI / process_runner / box64 stdout 转发 |
| `HBOX_GUI_*` | xdg-shell 钩子触发链路(move/min/max/resize) |
| `HBOX_WIN_RESIZE_*` | 窗口 resize / configure 协调 |

### box64 主要环境变量

```bash
BOX64_LOG=2                     # 详细启动日志
BOX64_DYNAREC_LOG=1             # dynarec 翻译日志
BOX64_SHOWSEGV=1                # SIGSEGV 时打印寄存器+回溯
BOX64_TRACE_FILE=/path/trace    # 翻译指令 trace
BOX64_LD_LIBRARY_PATH=/path     # guest .so 搜索路径
BOX64_PREFER_WRAPPED=0          # 关闭 native wrap,强走 dynarec
```

### App 内调试页

按【使用说明】里的 **调试诊断页**,能覆盖 90% 的环境/wine/wayland 问题。

### 常见症状速查

| 症状 | 可能原因 |
|---|---|
| `cannot allocate ... bridge` | HAP execmem 限制(父进程 dlopen 过 .so 或经 execve 上来) |
| `is not a 32bits value (caller=0x...)` | BOX32 高地址泄漏点(看 patch 32 警告) |
| `OHOS box32: low-4GB heap exhausted` | patch 28 256MB 堆耗尽,需扩容 |
| 渲染黑边 | shader swizzle 问题,临时把 fragment shader 改 `if (c.rgb≈0) green` 验证 |
| HAP 子进程 hilog 看不到 | hilog 客户端 socket 在 fork 子进程不可用,改写文件 |
| HAP hilog 全是 `<private>` | 默认脱敏,改 `%{public}s` |

### 渲染色诊断

把 fragment shader 临时改成把纯黑染绿,可快速判断黑边来源:

```glsl
vec4 c = texture(uTex, vUV);
if (c.r < 0.02 && c.g < 0.02 && c.b < 0.02) oColor = vec4(0,1,0,1);
else oColor = c.bgra;
```

---

## 🤝 开发约定

- ArkTS 严格模式;遵循鸿蒙官方 ESLint(避免对象字面量当类型用,必须显式 interface)
- C++ 4 空格缩进,文件末尾换行
- 新增 NAPI 接口同步更新 `Index.d.ts`
- Wayland 协议变更同时更新 server 实现和 `xdg-shell-server-protocol.h`
- Commit message 用 Conventional Commits(`feat:`, `fix:`, `refactor:`, `build:`)
- 关键链路日志加 `HBOX_<模块>_<阶段>_<状态>` 前缀
- **绝不在父进程 dlopen `libbox64.so`**;只能在 `proc::RunBox64` fork 出来的子进程里 dlopen
- 新增运行时资源条目时,优先复用 `ResourceService` 通用机制
- box64 patch 修改后必须 `--reset-source`,或者升 patch mark 版本号
- 新增 box64 my32_ wrapper 时按 generator 规则带 `,noE` 注释,改 `rebuild_wrappers_32.py` 而不是直接改生成产物 `wrapper32.c`

### 一键提交(Windows)

CMD: `git add . && git commit -m "your message" && git push`

PowerShell: `git add . ; git commit -m "your message" ; git push`

---

## 📜 License

仓库内文件除非另有声明,按用户内部使用授权。本项目对 box64 / wine 的修改(`build-box64/scripts/patches.sh` / `musl_compat.c` / `fork_not_exec.c` / 构建脚本)使用 MIT License。第三方组件遵循各自原始许可证:

- box64 – MIT
- libwayland / xdg-shell protocol – MIT
- Wine – LGPL 2.1+
- musl-fts / musl-obstack – Void Linux 维护,各自 License

---

## 🙏 致谢

- [box64](https://github.com/ptitSeb/box64) – x86_64 → ARM64 翻译层(上游)
- [Box64 for HarmonyOS](https://github.com/panedioic/Box64forHarmonyOS) – 鸿蒙适配版(动态库形态参考)
- [Wine](https://gitlab.winehq.org/wine/wine) – Windows 兼容层(上游 wine-10.0)
- [Wayland](https://wayland.freedesktop.org/) – 现代显示协议
- [musl-fts](https://github.com/void-linux/musl-fts) / [musl-obstack](https://github.com/void-linux/musl-obstack) – Void Linux 维护的 musl 兼容库
- [Termony](https://github.com/TermonyHQ/Termony) – 鸿蒙终端工具链
- [HarmonyOS-Haps](https://github.com/Zitann/HarmonyOS-Haps) – 鸿蒙应用安装方法
- HarmonyOS NDK / NAPI 团队