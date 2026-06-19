// HarmonyBox 原生模块声明
// 对应 entry/src/main/cpp/napi_init.cpp 中导出的方法

export interface WlSize {
  w: number;
  h: number;
}

export interface ExecResult {
  code: number;
  stdout: string;
}

// ============ Wayland server / GUI client ============

/** 启动内置 Wayland server,sockPath 必须可写。 */
export const startWaylandServer: (sockPath: string) => boolean;

/**
 * 旧路径:启动单实例 GUI 客户端(box64 或 native)。
 * 内部会自动拼 XDG_RUNTIME_DIR / WAYLAND_DISPLAY / LD_LIBRARY_PATH 等。
 * @returns 子进程 pid (>0) 或 -1
 */
export const launchClient: (
  exe: string,
  argv: string[],
  sockPath: string,
  libPath: string,
  extraEnv: string[]
) => number;

/** 终止当前单实例 GUI 客户端,server 保留。 */
export const stopClient: () => void;

/** 终止 GUI 客户端并停止 Wayland server。 */
export const stopAll: () => void;

/** 注册 GUI 客户端状态变化回调,目前会收到 "active" / "exited"。 */
export const setStateCallback: (cb: (state: string) => void) => void;

// ============ 旧 CLI / exec API ============

/**
 * 一次性收集子进程 stdout+stderr。最多 8KB。
 * @returns Promise<{ code, stdout }>
 */
export const execCapture: (
  exe: string,
  argv: string[],
  libPath: string,
  extraEnv: string[]
) => Promise<ExecResult>;

/**
 * 启动 CLI 子进程,行式输出通过 setCliCallback 上报。
 * @returns pid (>0) 或 -1
 */
export const launchCli: (
  exe: string,
  argv: string[],
  libPath: string,
  cwd: string,
  extraEnv: string[]
) => number;

/** 向指定 pid 发送 SIGTERM。 */
export const stopCli: (pid: number) => void;

/**
 * 注册 CLI 事件回调。
 * - ev = "out": 一行 stdout/stderr,data 是行内容
 * - ev = "exit": 进程退出,data 是退出码字符串
 */
export const setCliCallback: (
  cb: (pid: number, ev: string, data: string) => void
) => void;

// ============ 新一代低层 process runner ============

/**
 * 用 libbox64.so + dlopen 在子进程内运行 x86_64 ELF。
 * - argv 是执行目标文件的参数列表。其中：
 *   argv[0] 必须为 "box64", argv[1] 为 elf path, argv[2..] = guest args。
 *   传空数组时自动用 ["box64", elfPath]。
 *   后续也许会考虑只需要传目标参数即可。
 * - env 是完整 "KEY=VAL" 列表,调用方自己组(LD_LIBRARY_PATH /
 *   XDG_RUNTIME_DIR / BOX64_* 等都在 ArkTS 拼)。
 * - cwd 可选,空串 = 不 chdir。
 * - stdout/stderr 自动转发到 hilog,前缀 [box64:pid]。
 * - 不触发 setStateCallback,不做单实例跟踪;调用方自己管 pid。
 * @returns pid (>0) 或 -1
 */
export const runBox64: (
  elfPath: string,
  argv: string[],
  env: string[],
  cwd?: string,
  cb?: (event: string, data: string) => void
) => number;

/**
 * 通用 native 进程启动(execve)。stdout/stderr 转发到 hilog,前缀 [cmd:pid]。
 * argv 为空时自动用 [exe]。cwd 可选。
 * @returns pid (>0) 或 -1
 */
export const runCommand: (
  exe: string,
  argv: string[],
  env: string[],
  cwd?: string,
  cb?: (event: string, data: string) => void
) => number;

/**
 * 终止指定 pid:先 SIGTERM,800ms 后还活着补 SIGKILL。
 * pid <= 0 静默忽略。注意:此调用立即返回,进程实际退出是异步的。
 */
export const terminate: (pid: number) => void;

// ============ 输入注入 ============

export const sendKey: (evdevCode: number, pressed: boolean) => void;

/** 4 个修饰键状态位,顺序: depressed / latched / locked / group。 */
export const sendModifiers: (
  depressed: number,
  latched: number,
  locked: number,
  group: number,
  callback?: (event: string,) => number
) => void;

export const sendMouseMove: (x: number, y: number) => void;
export const sendMouseButton: (button: number, pressed: boolean) => void;
export const sendMouseAxis: (dx: number, dy: number) => void;
export const sendMouseHover: (inside: boolean) => void;

// ============ 窗口事件 ============

export const setSizeCallback: (cb: (w: number, h: number) => void) => void;
export const getLatestSize: () => WlSize;

export const setMoveCallback: (cb: () => void) => void;
export const setMaximizeCallback: (cb: () => void) => void;
export const setUnmaximizeCallback: (cb: () => void) => void;
export const setMinimizeCallback: (cb: () => void) => void;

/** edges 是 xdg_toplevel.resize_edge 位掩码: top=1, bottom=2, left=4, right=8。 */
export const setResizeCallback: (cb: (edges: number) => void) => void;

/** 主动告诉客户端目标 buffer 尺寸。 */
export const requestClientResize: (
  bufW: number,
  bufH: number,
  maximized: boolean
) => void;

// ============ 文件系统工具 ============

/** chmod 0755 目录下所有非点开头的条目,返回成功的个数。 */
export const chmodDirFiles: (dir: string) => number;