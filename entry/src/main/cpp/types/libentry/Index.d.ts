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

// ============================================================
//  通用类型
// ============================================================
/** 进程事件回调:'out' 携带一行输出,'exit' 携带退出码字符串 */
export type ProcEventCallback = (event: 'out' | 'exit', data: string) => void;
/** 运行模式提示。auto 时按 exePath 末尾是否为 "box64" 自动判定 */
export type RuntimeKindHint = 'auto' | 'native' | 'box64';
/** listProcesses 返回的进程记录 */
export interface ProcessInfo {
  pid: number;
  parentPid: number;
  kind: 'native' | 'box64';
  exePath: string;
  startTimeMs: number;
  /** -1 表示尚未退出 */
  exitCode: number;
  alive: boolean;
}
/** Wayland 客户端 buffer 尺寸 */
export interface WlBufferSize {
  w: number;
  h: number;
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

export const bindXComponentClient: (xcId: string, clientId: string) => void;

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

// ============================================================
//  新统一进程接口 (procmgr)
// ============================================================
/**
 * 启动一个进程,返回 pid (>0) 或 -1。
 *
 * - exePath 末尾为 "box64" 或显式 kindHint='box64' 时,
 *   走 fork + dlopen(libbox64.so) + box64_run 路径
 * - 否则走 fork + execve 路径
 *
 * argv 需包含完整参数 (含 argv[0])。box64 模式下约定:
 *   argv = [box64Path, guestElfPath, ...guestArgs]
 *
 * env 为完整环境变量数组,格式 "KEY=VALUE"。
 *
 * onEvent 为可选事件回调,'out' 收每一行 stdout/stderr,
 * 'exit' 一次性收退出码 (字符串形式)。不传时输出走 hilog。
 */
export function runCommand(
  exePath: string,
  argv: string[],
  env: string[],
  cwd?: string,
  onEvent?: ProcEventCallback,
  kindHint?: RuntimeKindHint
): number;
/**
 * @deprecated 改用 runCommand,内部会按 exePath 自动判定 box64。
 * 此接口仅为迁移期保留,未来版本会移除。
 */
export function runBox64(
  elfPath: string,
  argv: string[],
  env: string[],
  cwd?: string,
  onEvent?: ProcEventCallback | null
): number;
/** SIGTERM,800ms 后仍存活补 SIGKILL。pid <= 0 静默忽略 */
export function terminate(pid: number): void;
/** 拿一份当前进程表快照 */
export function listProcesses(): ProcessInfo[];
/**
 * 启动反向 spawn 通道 (Unix Domain Socket)。
 *
 * 仅当 box64 子进程需要委托主进程帮其启动新进程时才需要调用。
 * 重复调用安全:已启动返回 true。
 *
 * 推荐 sockPath:`${context.filesDir}/.procmgr.sock`
 */
export function startProcMgr(sockPath: string): boolean;
/** 关闭反向 spawn 通道 */
export function stopProcMgr(): void;

// ============ 输入注入 ============

export const sendKey: (clientId: string, code: number, pressed: boolean) => void;

/** 4 个修饰键状态位,顺序: depressed / latched / locked / group。 */
export const sendModifiers: (clientId: string,
  depressed: number, latched: number,
  locked: number, group: number) => void;

export const sendMouseMove: (clientId: string, x: number, y: number) => void;
export const sendMouseButton: (clientId: string, btn: number, pressed: boolean) => void;
export const sendMouseAxis: (clientId: string, dx: number, dy: number) => void;
export const sendMouseHover: (clientId: string, inside: boolean) => void;

// ============ 窗口事件 ============

export const setSizeCallback: (cb: (clientId: string, w: number, h: number) => void) => void;
export const getLatestSize: (clientId: string) => { w: number; h: number };

export const setMoveCallback: (cb: (clientId: string) => void) => void;
export const setMaximizeCallback: (cb: (clientId: string) => void) => void;
export const setUnmaximizeCallback: (cb: (clientId: string) => void) => void;
export const setResizeCallback: (cb: (clientId: string, edges: number) => void) => void;
export const setMinimizeCallback: (cb: (clientId: string) => void) => void;

export const requestClientResize: (
  clientId: string,
  w: number,
  h: number,
  maximized: boolean
) => void;

// ============ 文件系统工具 ============

/** chmod 0755 目录下所有非点开头的条目,返回成功的个数。 */
export const chmodDirFiles: (dir: string) => number;

export const ensureBox64TmpDir: () => boolean;

//
export const setupWinePrefix: (wineprefix: string, wineRoot: string) => boolean;

// ---- shell ----
export interface ShellInitOptions {
  homeDir: string;
  logDir: string;
  cols: number;
  rows: number;
}

export const shellInit: (
  opts: ShellInitOptions,
  outputCb: (data: string) => void
) => boolean;
export const shellInput: (data: string) => void;
export const shellResize: (cols: number, rows: number) => void;
export const shellShutdown: () => void;

export interface ShellInitOptions {
  homeDir: string;
  logDir: string;
  envPersistPath: string;
  cols: number;
  rows: number;
}

export const shellSetSystemEnv: (vars: string[]) => void;

export interface ShellCmdMeta {
  desc: string;
  usage?: string;
  streaming?: boolean;
}

export interface ShellCmdContext {
  name: string;
}

export type ShellCmdHandler = (
  args: string[],
  env: Record<string, string>,
  ctx: ShellCmdContext
) => Promise<number> | number | void;

export const shellRegister:    (name: string, meta: ShellCmdMeta, handler: ShellCmdHandler) => boolean;
export const shellUnregister:  (name: string) => boolean;
export const shellCommandDone: (code: number) => void;
export const shellStreamWrite: (data: string) => void;

export interface TarResult {
  ok: boolean;
  count: number;    // extract 时=已解压项数, create 时=已打包项数
  skipped: number;
  error: string;
}

export const tarExtract: (archive: string, destDir: string) => Promise<TarResult>;
export const tarCreate:  (archive: string, srcDir: string)  => Promise<TarResult>;
export const tarExtractFd: (fd: number, offset: number, length: number, destDir: string) => Promise<TarResult>;
export const tarCreateFd:  (fd: number, srcDir: string) => Promise<TarResult>;

export const setClientConnectCallback: (cb: (clientId: string) => void) => void;
export const setClientDisconnectCallback: (cb: (clientId: string) => void) => void;