export enum ContainerType {
  WINE  = 'wine',
  LINUX = 'linux'
}

export function containerTypeLabel(t: ContainerType): string {
  if (t === ContainerType.WINE)  return 'Wine';
  if (t === ContainerType.LINUX) return 'Linux';
  return t;
}

// 容器目录里 container.json 的内容
export interface ContainerConfig {
  name:        string;
  type:        ContainerType;
  version:     string;        // wine 版本 / linux 发行版
  arch:        string;        // 64-bit / 32-bit
  description: string;
  envVars:     Array<string>;
  createdAt:   number;

  // wine specific
  winePrefix?: string;        // 相对容器根目录, e.g. "prefix"
  wineBin?:    string;        // e.g. "wine/bin"

  // linux specific (predict)
  rootfs?:     string;
}

export interface ContainerInfo {
  id:        string;          // 目录名
  path:      string;          // 绝对路径
  config:    ContainerConfig;
  running:   boolean;
  startTime: number;          // 0 = 未启动
  pid:       number;          // 0 = 未启动
}

export function defaultContainerConfig(): ContainerConfig {
  return {
    name: '',
    type: ContainerType.WINE,
    version: '',
    arch: '64-bit',
    description: '',
    envVars: [],
    createdAt: 0
  } as ContainerConfig;
}