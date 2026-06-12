import wl from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export interface ToolStatus {
  id: string;
  name: string;
  url: string;            // 安装/参考链接,空字符串表示暂未实现
  installed: boolean;
  path: string;
  version: string;        // 已安装时显示;探测中显示 '...'
}

interface ToolSpec {
  id: string;
  name: string;
  url: string;
  candidatePaths: string[];
  versionArgs: string[];   // 跑 exe -v / --version 时的参数,空数组跳过版本探测
  parseFirstLine: boolean; // 多数工具版本只看第一行
}

const SPECS: ToolSpec[] = [
  {
    id: 'box64',
    name: 'box64',
    url: 'https://github.com/panedioic/Box64forHarmonyOS',
    candidatePaths: ['/data/service/hnp/bin/box64'],
    versionArgs: ['-v'],
    parseFirstLine: true
  },
  {
    id: 'box86',
    name: 'box86',
    url: '',
    candidatePaths: ['/data/service/hnp/bin/box86'],
    versionArgs: ['-v'],
    parseFirstLine: true
  },
  {
    id: 'wine',
    name: 'wine',
    url: '',
    candidatePaths: [
      '/data/service/hnp/bin/wine',
      '/data/service/hnp/bin/wine64'
    ],
    versionArgs: ['--version'],
    parseFirstLine: true
  },
  {
    id: 'elf-loader',
    name: 'elf-loader (Termony)',
    url: 'https://github.com/TermonyHQ/Termony',
    candidatePaths: [
      '/data/service/hnp/bin/elf-loader',
      '/data/service/hnp/bin/termony'
    ],
    versionArgs: [],
    parseFirstLine: true
  }
];

const HAPS_LINK_INFO: ToolStatus = {
  id: 'haps-howto',
  name: '鸿蒙应用安装方法',
  url: 'https://github.com/Zitann/HarmonyOS-Haps',
  installed: true,
  path: '',
  version: ''
};

export class ToolDetector {
  static getHapsHowto(): ToolStatus {
    return HAPS_LINK_INFO;
  }

  static getSpecs(): ToolSpec[] {
    return SPECS;
  }

  // 仅文件级探测,不跑命令
  static probeOne(spec: ToolSpec): ToolStatus {
    let foundPath: string = '';
    for (const p of spec.candidatePaths) {
      try {
        if (fs.accessSync(p)) {
          foundPath = p;
          break;
        }
      } catch (e) { /* ignore */ }
    }
    return {
      id: spec.id,
      name: spec.name,
      url: spec.url,
      installed: foundPath.length > 0,
      path: foundPath,
      version: foundPath.length > 0 ? '...' : ''
    } as ToolStatus;
  }

  static probeAll(): ToolStatus[] {
    return SPECS.map((s: ToolSpec): ToolStatus => ToolDetector.probeOne(s));
  }

  // 已确认安装的工具,异步取版本
  static async fetchVersion(
    context: common.UIAbilityContext,
    spec: ToolSpec,
    path: string
  ): Promise<string> {
    if (spec.versionArgs.length === 0) {
      return '已安装';
    }
    const libPath: string = context.applicationInfo.nativeLibraryPath ?? '';
    try {
      const argv: string[] = [path];
      for (const a of spec.versionArgs) {
        argv.push(a);
      }
      const r = await wl.execCapture(path, argv, libPath);
      const text: string = (r.stdout || '').trim();
      if (!text) {
        return r.code === 0 ? '已安装' : `已安装 (exit ${r.code})`;
      }
      const firstLine: string = spec.parseFirstLine
        ? text.split('\n')[0].trim()
        : text;
      // 截断防止过长
      return firstLine.length > 80 ? firstLine.substring(0, 80) + '…' : firstLine;
    } catch (e) {
      console.error(`fetchVersion ${spec.id} failed: ${JSON.stringify(e)}`);
      return '已安装 (版本读取失败)';
    }
  }
}