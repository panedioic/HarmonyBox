export enum AppType {
  WINDOWS = 'windows',
  LINUX = 'linux',
  HARMONY = 'harmony'
}

export enum RuntimeMode {
  GUI = 'gui',
  CLI = 'cli'
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
  /** @deprecated 应用运行时行为由 containerId 关联的容器决定; 该字段仅供旧数据兼容与显示 */
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