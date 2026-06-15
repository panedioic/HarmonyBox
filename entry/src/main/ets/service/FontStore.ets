import { fileIo as fs } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export interface FontFile {
  name: string;
  size: number;
  path: string;
}

const FONT_DIR_NAME: string = 'fonts';
const FC_DIR_NAME: string = 'fontconfig';
const FC_CONF_NAME: string = 'fonts.conf';

export class FontStore {
  static getFontDir(ctx: common.Context): string {
    const dir: string = `${ctx.filesDir}/${FONT_DIR_NAME}`;
    try { if (!fs.accessSync(dir)) fs.mkdirSync(dir, true); } catch (e) { /* ignore */ }
    return dir;
  }

  static getFcDir(ctx: common.Context): string {
    const dir: string = `${ctx.filesDir}/${FC_DIR_NAME}`;
    try {
      if (!fs.accessSync(dir)) fs.mkdirSync(dir, true);
      const cache: string = `${dir}/cache`;
      if (!fs.accessSync(cache)) fs.mkdirSync(cache, true);
    } catch (e) { /* ignore */ }
    return dir;
  }

  static getFcConfPath(ctx: common.Context): string {
    return `${FontStore.getFcDir(ctx)}/${FC_CONF_NAME}`;
  }

  static getFcCacheDir(ctx: common.Context): string {
    return `${FontStore.getFcDir(ctx)}/cache`;
  }

  static list(ctx: common.Context): FontFile[] {
    const dir: string = FontStore.getFontDir(ctx);
    const result: FontFile[] = [];
    try {
      const entries: string[] = fs.listFileSync(dir);
      for (const name of entries) {
        const path: string = `${dir}/${name}`;
        try {
          const stat = fs.statSync(path);
          if (!stat.isDirectory()) {
            result.push({ name, size: stat.size, path } as FontFile);
          }
        } catch (e) { /* ignore */ }
      }
    } catch (e) { /* ignore */ }
    result.sort((a: FontFile, b: FontFile): number => a.name.localeCompare(b.name));
    return result;
  }

  /**
   * @throws Already in try catch, ignore warnings.
   */
  static async pickAndAdd(ctx: common.Context): Promise<number> {
    try {
      const p = new picker.DocumentViewPicker();
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 100;
      const uris: string[] = await p.select(opt);
      if (!uris || uris.length === 0) return 0;
      const dir: string = FontStore.getFontDir(ctx);
      let added: number = 0;
      for (const uri of uris) {
        try {
          const segs: string[] = uri.split('/').filter((s: string): boolean => s.length > 0);
          const fname: string = segs[segs.length - 1];
          const dest: string = `${dir}/${fname}`;
          const srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
          try {
            const dstFile = fs.openSync(
              dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
            );
            try { fs.copyFileSync(srcFile.fd, dstFile.fd); added++; }
            finally { fs.closeSync(dstFile.fd); }
          } finally { fs.closeSync(srcFile.fd); }
        } catch (e) { /* ignore */ }
      }
      FontStore.invalidateCache(ctx);
      return added;
    } catch (e) { return 0; }
  }

  static remove(ctx: common.Context, name: string): boolean {
    const path: string = `${FontStore.getFontDir(ctx)}/${name}`;
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
        FontStore.invalidateCache(ctx);
        return true;
      }
    } catch (e) { /* ignore */ }
    return false;
  }

  static clear(ctx: common.Context): number {
    const list = FontStore.list(ctx);
    let n = 0;
    for (const f of list) if (FontStore.remove(ctx, f.name)) n++;
    return n;
  }

  // 字体变更后必须清掉缓存,否则 fontconfig 会继续使用旧的 .cache-N
  static invalidateCache(ctx: common.Context): void {
    const cacheDir: string = FontStore.getFcCacheDir(ctx);
    try {
      if (!fs.accessSync(cacheDir)) return;
      const entries: string[] = fs.listFileSync(cacheDir);
      for (const name of entries) {
        try { fs.unlinkSync(`${cacheDir}/${name}`); } catch (e) { /* ignore */ }
      }
    } catch (e) { /* ignore */ }
  }

  // 启动子进程前调用,生成或更新 fonts.conf,返回路径供 FONTCONFIG_FILE 使用
  static ensureConfig(ctx: common.Context): string {
    const fontDir: string = FontStore.getFontDir(ctx);
    const cacheDir: string = FontStore.getFcCacheDir(ctx);
    const confPath: string = FontStore.getFcConfPath(ctx);

    // 列出实际上传的字体,方便确认是否落地
    const list: FontFile[] = FontStore.list(ctx);
    console.info(`[FontStore] fontDir=${fontDir}, ${list.length} files`);
    for (const f of list) {
      console.info(`[FontStore]   ${f.name} (${FontStore.formatSize(f.size)})`);
    }

    const xml: string =
      `<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>${fontDir}</dir>
  <cachedir>${cacheDir}</cachedir>

  <!-- 兼容沙箱里可能存在的发行版 conf.d -->
  <include ignore_missing="yes">/etc/fonts/conf.d</include>
  <include ignore_missing="yes">/usr/share/fontconfig/conf.avail</include>

  <!-- ★ 关键:weston-terminal 用 cairo toy API,请求 family 是 'mono',
       不是 'monospace'。必须把它显式改写过去,否则不命中我们的 alias。 -->
  <match target="pattern">
    <test name="family"><string>mono</string></test>
    <edit name="family" mode="assign" binding="strong"><string>monospace</string></edit>
  </match>
  <match target="pattern">
    <test name="family"><string>sans</string></test>
    <edit name="family" mode="assign" binding="strong"><string>sans-serif</string></edit>
  </match>

  <alias>
    <family>monospace</family>
    <prefer>
      <family>DejaVu Sans Mono</family>
      <family>Liberation Mono</family>
      <family>Ubuntu Mono</family>
      <family>Noto Sans Mono CJK SC</family>
      <family>Noto Sans Mono</family>
    </prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>DejaVu Sans</family>
      <family>Liberation Sans</family>
      <family>Ubuntu</family>
      <family>Noto Sans CJK SC</family>
      <family>Noto Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>DejaVu Serif</family>
      <family>Liberation Serif</family>
      <family>Noto Serif CJK SC</family>
      <family>Noto Serif</family>
    </prefer>
  </alias>

  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting"   mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba"      mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
  </match>
</fontconfig>
`;

    FontStore.writeFile(confPath, xml);

    // ★ 多路径冗余:fontconfig 不同版本/编译选项查的位置不同
    const home: string = `${ctx.filesDir}`;
    FontStore.ensureDir(`${home}/.config`);
    FontStore.ensureDir(`${home}/.config/fontconfig`);
    FontStore.writeFile(`${home}/.config/fontconfig/fonts.conf`, xml);
    FontStore.writeFile(`${home}/.fonts.conf`, xml);

    return confPath;
  }

  static buildEnv(ctx: common.Context): string[] {
    const conf: string = FontStore.ensureConfig(ctx);
    const home: string = `${ctx.filesDir}`;
    return [
      `FONTCONFIG_FILE=${conf}`,
      `FONTCONFIG_PATH=${FontStore.getFcDir(ctx)}`,
      `FC_CACHEDIR=${FontStore.getFcCacheDir(ctx)}`,
      `XDG_CONFIG_HOME=${home}/.config`,
      `XDG_DATA_HOME=${home}/.local/share`,
      `XDG_CACHE_HOME=${home}/.cache`,
    ];
  }

  private static ensureDir(path: string): void {
    try { if (!fs.accessSync(path)) fs.mkdirSync(path, true); } catch (e) { /* ignore */ }
  }

  private static writeFile(path: string, content: string): void {
    try {
      const file = fs.openSync(
        path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
      );
      try { fs.writeSync(file.fd, content); }
      finally { fs.closeSync(file.fd); }
    } catch (e) { /* ignore */ }
  }

  static formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
  }
}