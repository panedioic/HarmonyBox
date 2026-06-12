export enum AppType {
  WIN32 = 'win32',
  WIN64 = 'win64',
  LINUX32 = 'linux32',
  LINUX64 = 'linux64',
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
  type: AppType;
  runtimeMode: RuntimeMode;
  execPath: string;
  installDir: string;
  installedAt: number;
  config: AppConfig;

  constructor(
    id: string = '',
    name: string = '',
    icon: string = '📦',
    type: AppType = AppType.LINUX64,
    runtimeMode: RuntimeMode = RuntimeMode.GUI,
    execPath: string = '',
    installDir: string = '',
    installedAt: number = Date.now(),
    config: AppConfig = { envVars: '', args: '' }
  ) {
    this.id = id;
    this.name = name;
    this.icon = icon;
    this.type = type;
    this.runtimeMode = runtimeMode;
    this.execPath = execPath;
    this.installDir = installDir;
    this.installedAt = installedAt;
    this.config = config;
  }
}

export function appTypeLabel(type: AppType): string {
  switch (type) {
    case AppType.WIN32: return '32位 Windows';
    case AppType.WIN64: return '64位 Windows';
    case AppType.LINUX32: return '32位 Linux';
    case AppType.LINUX64: return '64位 Linux';
    case AppType.HARMONY: return '鸿蒙原生';
    default: return '未知';
  }
}

export function runtimeModeLabel(mode: RuntimeMode): string {
  return mode === RuntimeMode.GUI ? '图形界面 (GUI)' : '命令行 (CLI)';
}

export function isTypeSupported(type: AppType): boolean {
  return type === AppType.LINUX64;
}