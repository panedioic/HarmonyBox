import { ContainerType } from "./ContainerInfo";

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
  installDir: string;
  installedAt: number;
  config: AppConfig;
  containerId: string;


  constructor(
    id: string = '', name: string = '', icon: string = '📦',
    type: AppType = AppType.LINUX,
    runtimeMode: RuntimeMode = RuntimeMode.GUI,
    execPath: string = '', installDir: string = '',
    installedAt: number = Date.now(),
    config: AppConfig = { envVars: '', args: '' },
    containerId: string = ''
  ) {
    this.id = id; this.name = name; this.icon = icon;
    this.type = type; this.runtimeMode = runtimeMode;
    this.execPath = execPath; this.installDir = installDir;
    this.installedAt = installedAt; this.config = config;
    this.containerId = containerId;
  }
}

export function appTypeLabel(type: AppType): string {
  switch (type) {
    case AppType.WINDOWS: return 'Windows';
    case AppType.LINUX: return 'Linux';
    case AppType.HARMONY: return 'HarmonyOS';
    default: return '未知';
  }
}

export function runtimeModeLabel(mode: RuntimeMode): string {
  return mode === RuntimeMode.GUI ? '图形界面 (GUI)' : '命令行 (CLI)';
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
    case 'win64': return AppType.WINDOWS;
    case 'linux':
    case 'linux32':
    case 'linux64': return AppType.LINUX;
    case 'harmony': return AppType.HARMONY;
    default: return AppType.LINUX;
  }
}

export interface BuiltinAppEntry {
  id: string;
  name: string;
  icon: string;
  desc: string;
  /** 要求的容器类型, 安装时会自动筛选匹配的容器 */
  containerType: ContainerType;
  /** rawfile/apps/ 下的文件名 */
  rawfileName: string;
  /** 主可执行文件相对路径 */
  execRelPath: string;
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
    rawfileName: 'apps/weston-terminl.tar.zst',
    execRelPath: 'weston-terminl',
    runtimeMode: RuntimeMode.GUI,
    config: { envVars: 'LD_PRELOAD=libforkpty_shim.so', args: '' }
  },
  {
    id: 'hello-wine',
    name: 'Hello Wine',
    icon: '🍷',
    desc: '一个简单的 Win32 Hello World 程序。',
    containerType: ContainerType.WINE,
    rawfileName: 'apps/hello-wine.tar.zst',
    execRelPath: 'hello.exe',
    runtimeMode: RuntimeMode.CLI,
    config: { envVars: '', args: '' }
  }
];