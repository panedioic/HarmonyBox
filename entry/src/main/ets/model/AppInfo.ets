import { ContainerType, ContainerInfo } from "./ContainerInfo";

/** @deprecated 由容器类型推导, 不再使用 */
export enum AppType {
  WINDOWS = 'windows',
  LINUX = 'linux',
  HARMONY = 'harmony'
}

/** @deprecated 未来移除, 当前仍用于启动判断 */
export enum RuntimeMode {
  GUI = 'gui',
  CLI = 'cli'
}

export enum LaunchMode {
  GUI = 'gui',   // 默认: 直接拉起 AppRunnerAbility, 展示 loading, 等 wayland
  CLI = 'cli'    // 先拉起 CliRunnerAbility, wayland 连上后再拉 AppRunnerAbility
}

/** 可执行文件路径类型 */
export enum ExecPathType {
  APP_RELATIVE       = 'app',        // 相对应用安装目录 (默认)
  CONTAINER_RELATIVE = 'container',  // 相对容器根目录, 如 wine/bin/wine
  ABSOLUTE           = 'absolute',   // 系统绝对路径, 如 /system/bin/sh
  BARE               = 'bare'        // 不拼接前缀, 交给 wine/PATH 解析, 如 notepad
}

export interface AppConfig {
  envVars: string;
  args: string;
}

@Observed
export class AppInfo {
  id: string;
  name: string;
  icon: string;
  type: AppType;
  runtimeMode: RuntimeMode;
  execPath: string;
  execPathType: ExecPathType;
  installDir: string;
  installedAt: number;
  config: AppConfig;
  containerId: string;

  constructor(
    id: string = '', name: string = '', icon: string = '📦',
    type: AppType = AppType.LINUX,
    runtimeMode: RuntimeMode = RuntimeMode.GUI,
    execPath: string = '',
    execPathType: ExecPathType = ExecPathType.APP_RELATIVE,
    installDir: string = '',
    installedAt: number = Date.now(),
    config: AppConfig = { envVars: '', args: '' },
    containerId: string = ''
  ) {
    this.id = id; this.name = name; this.icon = icon;
    this.type = type; this.runtimeMode = runtimeMode;
    this.execPath = execPath;
    this.execPathType = execPathType;
    this.installDir = installDir;
    this.installedAt = installedAt; this.config = config;
    this.containerId = containerId;
  }
}

// =============================================================
//  Labels
// =============================================================
export function appTypeLabel(type: AppType): string {
  switch (type) {
    case AppType.WINDOWS: return 'Windows';
    case AppType.LINUX:   return 'Linux';
    case AppType.HARMONY: return 'HarmonyOS';
    default:              return '未知';
  }
}

export function runtimeModeLabel(mode: RuntimeMode): string {
  return mode === RuntimeMode.GUI ? '图形界面 (GUI)' : '命令行 (CLI)';
}

export function execPathTypeLabel(t: ExecPathType): string {
  switch (t) {
    case ExecPathType.APP_RELATIVE:       return '应用目录';
    case ExecPathType.CONTAINER_RELATIVE: return '容器目录';
    case ExecPathType.ABSOLUTE:           return '绝对路径';
    case ExecPathType.BARE:               return '容器内命令';
    default:                              return '未知';
  }
}

export function execPathTypeHint(t: ExecPathType): string {
  switch (t) {
    case ExecPathType.APP_RELATIVE:
      return '相对于应用安装目录, 如 bin/app';
    case ExecPathType.CONTAINER_RELATIVE:
      return '相对于容器根目录, 如 wine/bin/wine';
    case ExecPathType.ABSOLUTE:
      return '绝对路径, 如 /system/bin/sh';
    case ExecPathType.BARE:
      return '不拼接前缀, 由 wine/PATH 解析, 如 notepad';
    default:
      return '';
  }
}

/** @deprecated 现由容器决定支持性 */
export function isTypeSupported(type: AppType): boolean {
  return type === AppType.LINUX || type === AppType.WINDOWS;
}

// 老存档迁移
export function migrateAppType(t: string): AppType {
  switch (t) {
    case 'windows': return AppType.WINDOWS;
    case 'win32':
    case 'win64':   return AppType.WINDOWS;
    case 'linux':
    case 'linux32':
    case 'linux64': return AppType.LINUX;
    case 'harmony': return AppType.HARMONY;
    default:        return AppType.LINUX;
  }
}

export function migrateExecPathType(t: string): ExecPathType {
  switch (t) {
    case 'app':       return ExecPathType.APP_RELATIVE;
    case 'container': return ExecPathType.CONTAINER_RELATIVE;
    case 'absolute':  return ExecPathType.ABSOLUTE;
    case 'bare':      return ExecPathType.BARE;
    default:          return ExecPathType.APP_RELATIVE;
  }
}

// =============================================================
//  Path Resolver
// =============================================================
/**
 * 根据 execPathType 解析出用于 exec 的路径.
 * @param app         应用信息
 * @param container   所属容器 (BARE / APP_RELATIVE / ABSOLUTE 时可为 null)
 * @param filesDir    ctx.filesDir, 用于 APP_RELATIVE 拼绝对路径
 */
export function resolveExecPath(
  app: AppInfo,
  container: ContainerInfo | null,
  filesDir: string
): string {
  const p: string = app.execPath;
  switch (app.execPathType) {
    case ExecPathType.APP_RELATIVE:
      return `${filesDir}/${app.installDir}/${p}`;
    case ExecPathType.CONTAINER_RELATIVE:
      if (!container) return p;
      return `${container.path}/${p}`;
    case ExecPathType.ABSOLUTE:
      return p;
    case ExecPathType.BARE:
      return p;
    default:
      return `${filesDir}/${app.installDir}/${p}`;
  }
}

// =============================================================
//  Builtin Apps
// =============================================================
export interface BuiltinAppEntry {
  id: string;
  name: string;
  icon: string;
  desc: string;
  /** 要求的容器类型, 安装时会自动筛选匹配的容器 */
  containerType: ContainerType;
  /** rawfile/apps/ 下的文件名; BARE 应用可留空 */
  rawfileName: string;
  /** 主可执行文件路径 (语义由 execPathType 决定) */
  execRelPath: string;
  /** 路径类型 */
  execPathType: ExecPathType;
  /** 运行模式 */
  runtimeMode: RuntimeMode;
  /** 预设的启动配置 */
  config: AppConfig;
}

export const BUILTIN_APPS: BuiltinAppEntry[] = [
  {
    id: 'weston-terminal',
    name: '终端',
    icon: '📝',
    desc: '基于 Weston 的终端模拟器，不过由于鸿蒙权限限制，只有窗口，并不能真的操作终端。',
    containerType: ContainerType.LINUX,
    rawfileName: 'apps/weston-terminal.tar.zst',
    execRelPath: 'weston-terminl',
    execPathType: ExecPathType.APP_RELATIVE,
    runtimeMode: RuntimeMode.GUI,
    config: { envVars: 'LD_PRELOAD=libforkpty_shim.so', args: '' }
  },
  {
    id: 'wine-notepad',
    name: 'Wine 记事本 (诊断)',
    icon: '📄',
    desc: 'Wine 内置的记事本 (notepad.exe)。不过当前 Wine 容器存在 bug，因此无法启动。',
    containerType: ContainerType.WINE,
    rawfileName: '',  // 不需要 rawfile
    execRelPath: 'notepad',
    execPathType: ExecPathType.BARE,
    runtimeMode: RuntimeMode.GUI,
    config: { envVars: '', args: '' }
  },
  {
    id: 'wine-cmd-test',
    name: 'Wine CMD 测试',
    icon: '🔧',
    desc: '执行 cmd /c echo, 用于测试非图形界面应用是否能正常运行。启动后应该在日志窗口看到输出并很快退出。',
    containerType: ContainerType.WINE,
    rawfileName: '',
    execRelPath: 'cmd',
    execPathType: ExecPathType.BARE,
    runtimeMode: RuntimeMode.CLI,                          // ★ CLI 模式, 直接开日志窗
    config: {
      envVars: '',
      args: '/c echo Hello from Wine cmd && echo box64=%PROCESSOR_ARCHITECTURE%'
    }
  },
];