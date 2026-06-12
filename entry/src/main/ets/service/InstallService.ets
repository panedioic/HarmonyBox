import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export class InstallService {
  // 选择源文件夹,返回 URI
  static async pickFolder(): Promise<string | null> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      // 文件夹选择(部分设备可能不支持,不支持时退化为文件选择)
      try {
        options.selectMode = picker.DocumentSelectMode.FOLDER;
      } catch (e) {
        console.warn('FOLDER mode not available, fallback to file');
      }
      const uris: string[] = await documentPicker.select(options);
      return uris && uris.length > 0 ? uris[0] : null;
    } catch (e) {
      console.error(`pickFolder failed: ${JSON.stringify(e)}`);
      return null;
    }
  }

  // URI -> 本地路径
  static uriToPath(uri: string): string {
    try {
      return new fileUri.FileUri(uri).path;
    } catch (e) {
      console.error(`uriToPath failed: ${JSON.stringify(e)}`);
      return '';
    }
  }

  // 从 URI 取末段名作为默认名
  static folderNameFromUri(uri: string): string {
    const path = InstallService.uriToPath(uri);
    if (!path) {
      return '未命名';
    }
    const parts: string[] = path.split('/').filter((p: string) => p.length > 0);
    return parts.length > 0 ? parts[parts.length - 1] : '未命名';
  }

  // 递归复制目录
  static copyDirRec(srcPath: string, destPath: string): void {
    try {
      if (!fs.accessSync(destPath)) {
        fs.mkdirSync(destPath, true);
      }
      const entries: string[] = fs.listFileSync(srcPath);
      for (const entry of entries) {
        const src: string = `${srcPath}/${entry}`;
        const dest: string = `${destPath}/${entry}`;
        const stat = fs.statSync(src);
        if (stat.isDirectory()) {
          InstallService.copyDirRec(src, dest);
        } else {
          fs.copyFileSync(src, dest);
        }
      }
    } catch (e) {
      console.error(`copyDirRec failed at ${srcPath}: ${JSON.stringify(e)}`);
      throw new Error(`复制失败: ${(e as Error).message || ''}`);
    }
  }

  // 安装到 filesDir/apps/{appId}
  static installFromUri(
    context: common.Context,
    sourceUri: string,
    appId: string
  ): string {
    const appsRoot: string = `${context.filesDir}/apps`;
    try {
      if (!fs.accessSync(appsRoot)) {
        fs.mkdirSync(appsRoot, true);
      }
      const targetDir: string = `${appsRoot}/${appId}`;
      if (fs.accessSync(targetDir)) {
        throw new Error(`目录已存在: ${targetDir}`);
      }
      const srcPath: string = InstallService.uriToPath(sourceUri);
      if (!srcPath) {
        throw new Error('无法解析源路径');
      }
      InstallService.copyDirRec(srcPath, targetDir);
      return `apps/${appId}`;
    } catch (e) {
      console.error(`installFromUri failed: ${JSON.stringify(e)}`);
      throw new Error((e as Error).message || '安装失败');
    }
  }

  // 递归删除沙箱目录
  static uninstall(context: common.Context, installDir: string): void {
    if (!installDir) {
      return;
    }
    const fullPath: string = `${context.filesDir}/${installDir}`;
    try {
      if (fs.accessSync(fullPath)) {
        fs.rmdirSync(fullPath);
      }
    } catch (e) {
      console.error(`uninstall failed at ${fullPath}: ${JSON.stringify(e)}`);
      throw new Error(`删除目录失败: ${(e as Error).message || ''}`);
    }
  }
}