import wl from 'libentry.so';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { WineService, WineStatus } from './WineService';

export interface ToolStatus {
  id: string;
  name: string;
  url: string;
  installed: boolean;
  path: string;
  version: string;
}

interface ToolSpec {
  id: string;
  name: string;
  url: string;
  candidatePaths: string[];
  versionArgs: string[];
  parseFirstLine: boolean;
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
    id: 'elf-loader',
    name: 'elf-loader (Termony)',
    url: 'https://github.com/TermonyHQ/Termony',
    candidatePaths: [
      '/data/service/hnp/bin/elf-loader'
    ],
    versionArgs: [],
    parseFirstLine: true
  },
  {
    id: 'proot',
    name: 'proot (Termony)',
    url: 'https://github.com/TermonyHQ/Termony',
    candidatePaths: ['/data/service/hnp/bin/proot'],
    versionArgs: ['--version'],
    parseFirstLine: true
  }
];

const HAPS_LINK_INFO: ToolStatus = {
  id: 'haps-howto',
  name: '鸿蒙应用安装方法',
  url: 'https://github.com/Zitann/HarmonyOS-Haps',
  installed: true, path: '', version: ''
};

export class ToolDetector {
  static getHapsHowto(): ToolStatus { return HAPS_LINK_INFO; }
  static getSpecs(): ToolSpec[] { return SPECS; }

  static probeOne(spec: ToolSpec): ToolStatus {
    let foundPath: string = '';
    for (const p of spec.candidatePaths) {
      try { if (fs.accessSync(p)) { foundPath = p; break; } } catch (e) { /* ignore */ }
    }
    return {
      id: spec.id, name: spec.name, url: spec.url,
      installed: foundPath.length > 0,
      path: foundPath,
      version: foundPath.length > 0 ? '...' : ''
    } as ToolStatus;
  }

  static probeAll(): ToolStatus[] {
    return SPECS.map((s: ToolSpec): ToolStatus => ToolDetector.probeOne(s));
  }

  // wine 是单独的状态(沙箱里安装)
  static probeWine(ctx: common.Context): ToolStatus {
    const w: WineStatus = WineService.probe(ctx);
    return {
      id: 'wine',
      name: 'wine',
      url: '',
      installed: w.installed,
      path: w.binPath,
      version: w.version
    } as ToolStatus;
  }

  static async fetchVersion(
    context: common.UIAbilityContext, spec: ToolSpec, path: string
  ): Promise<string> {
    return "暂不支持";
  }
}