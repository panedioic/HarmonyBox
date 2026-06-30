// entry/src/main/ets/shell/ShellEngine.ets
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PathResolver } from './PathResolver';

export class ShellEngine {
  private buffer: string = '';
  private cursor: number = 0;
  private history: string[] = [];
  private historyIdx: number = -1;
  private prompt: string = 'hbsh$ ';
  private cwd: string = '/';
  private webCtl: webview.WebviewController;
  private escState: number = 0;       // 0=normal, 1=got ESC, 2=got ESC [
  private historySaved: string = '';  // 上下历史时保存当前编辑中的行
  private ctx: common.UIAbilityContext;
  private homeDir: string;

  constructor(ctl: webview.WebviewController, ctx: common.UIAbilityContext) {
    this.webCtl = ctl;
    this.ctx = ctx;
    this.homeDir = ctx.filesDir;
    this.cwd = ctx.filesDir;
  }

  start(): void {
    this.writeBanner();
    this.writePrompt();
  }

  // 来自 web 的输入
  feed(data: string): void {
    for (let i = 0; i < data.length; i++) {
      this.handleByte(data.charCodeAt(i), data[i]);
    }
  }

  private handleChar(code: number, ch: string): void {
    if (code === 13) {                      // Enter
      this.write('\r\n');
      this.runLine(this.buffer);
      this.buffer = '';
      this.cursor = 0;
      this.historyIdx = -1;
    } else if (code === 127 || code === 8) { // Backspace
      if (this.cursor > 0) {
        this.buffer = this.buffer.slice(0, this.cursor - 1) +
          this.buffer.slice(this.cursor);
        this.cursor--;
        this.redrawLine();
      }
    } else if (code === 3) {                // Ctrl+C
      this.write('^C\r\n');
      this.buffer = '';
      this.cursor = 0;
      this.writePrompt();
    } else if (code === 12) {               // Ctrl+L
      this.clear();
      this.writePrompt();
      this.write(this.buffer);
    } else if (code >= 32 && code < 127) {  // 可打印
      this.buffer = this.buffer.slice(0, this.cursor) + ch +
        this.buffer.slice(this.cursor);
      this.cursor++;
      this.redrawLine();
    }
    // 方向键、history 等留到第二轮
  }

  private redrawLine(): void {
    // 简化版: 整行重画。后面可优化只重画 cursor 之后
    this.write('\r\x1b[K' + this.prompt + this.buffer);
    // 把光标移回 cursor 位置
    const back = this.buffer.length - this.cursor;
    if (back > 0) this.write(`\x1b[${back}D`);
  }

  private async runLine(line: string): Promise<void> {
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      this.writePrompt();
      return;
    }
    if (this.history.length === 0 ||
      this.history[this.history.length - 1] !== trimmed) {
      this.history.push(trimmed);
      if (this.history.length > 500) this.history.shift();
    }
    const parts = trimmed.split(/\s+/);
    const name = parts[0];
    const args = parts.slice(1);

    try {
      await this.dispatch(name, args);
    } catch (e) {
      this.writeln(`\x1b[31merror: ${(e as Error).message}\x1b[0m`);
    }
    this.writePrompt();
  }

  private async dispatch(name: string, args: string[]): Promise<void> {
    switch (name) {
      case 'help':  return this.cmdHelp();
      case 'clear': return this.clear();
      case 'echo':  this.writeln(args.join(' ')); return;
      case 'pwd':   this.writeln(this.cwd); return;
      case 'cd':    return this.cmdCd(args);
      case 'ls':    return this.cmdLs(args);
      case 'cat':   return this.cmdCat(args);
      default:
        this.writeln(`\x1b[31mhbsh: command not found: ${name}\x1b[0m`);
    }
  }

  private cmdHelp(): void {
    const lines = [
      '\x1b[1;33mAvailable commands:\x1b[0m',
      '  \x1b[36mhelp\x1b[0m              show this help',
      '  \x1b[36mclear\x1b[0m             clear the screen',
      '  \x1b[36mecho\x1b[0m <text>       print text',
      '  \x1b[36mpwd\x1b[0m               print working directory',
      '  \x1b[36mcd\x1b[0m [dir]          change directory (default: ~)',
      '  \x1b[36mls\x1b[0m [-a] [-l] [p]  list directory',
      '  \x1b[36mcat\x1b[0m <file>        print file contents',
      '',
      '\x1b[1;33mShortcuts:\x1b[0m',
      '  Ctrl+C   cancel current input',
      '  Ctrl+L   clear screen',
      '  Ctrl+A/E move to start/end of line',
      '  Ctrl+U/K delete to start/end of line',
      '  ↑/↓      history',
      '  ←/→      cursor move',
    ];
    for (const l of lines) this.writeln(l);
  }

  private async cmdCd(args: string[]): Promise<void> {
    const target = args.length === 0 ? this.homeDir
      : PathResolver.resolve(this.cwd, this.homeDir, args[0]);
    try {
      if (!fs.accessSync(target)) {
        this.writeln(`\x1b[31mcd: no such directory: ${target}\x1b[0m`);
        return;
      }
      const st = fs.statSync(target);
      if (!st.isDirectory()) {
        this.writeln(`\x1b[31mcd: not a directory: ${target}\x1b[0m`);
        return;
      }
      this.cwd = target;
    } catch (e) {
      this.writeln(`\x1b[31mcd: ${(e as Error).message}\x1b[0m`);
    }
  }

  private async cmdLs(args: string[]): Promise<void> {
    let showAll = false;
    let longFmt = false;
    const targets: string[] = [];
    for (const a of args) {
      if (a === '-a' || a === '--all') showAll = true;
      else if (a === '-l') longFmt = true;
      else if (a === '-la' || a === '-al') { showAll = true; longFmt = true; }
      else targets.push(a);
    }
    if (targets.length === 0) targets.push(this.cwd);
    for (let i = 0; i < targets.length; i++) {
      const arg = targets[i];
      const path = PathResolver.resolve(this.cwd, this.homeDir, arg);
      if (targets.length > 1) {
        if (i > 0) this.writeln('');
        this.writeln(`${PathResolver.display(path, this.homeDir)}:`);
      }
      await this.lsOne(path, showAll, longFmt);
    }
  }

  private async lsOne(path: string, showAll: boolean, longFmt: boolean): Promise<void> {
    try {
      if (!fs.accessSync(path)) {
        this.writeln(`\x1b[31mls: not found: ${path}\x1b[0m`);
        return;
      }
      const st = fs.statSync(path);
      if (!st.isDirectory()) {
        // 单文件
        if (longFmt) this.writeln(this.formatLong(path, st));
        else this.writeln(this.colorEntry(path.split('/').pop() ?? path, st));
        return;
      }
      let entries = fs.listFileSync(path);
      if (!showAll) entries = entries.filter(e => !e.startsWith('.'));
      entries.sort();
      if (entries.length === 0) return;
      if (longFmt) {
        for (const e of entries) {
          try {
            const st2 = fs.statSync(path + '/' + e);
            this.writeln(this.formatLong(e, st2));
          } catch {
            this.writeln(`?  ${e}`);
          }
        }
      } else {
        // 简单多列: 终端宽度按 80 估算
        const colored: string[] = [];
        const widths: number[] = [];
        for (const e of entries) {
          let st2: fs.Stat | null = null;
          try { st2 = fs.statSync(path + '/' + e); } catch {}
          colored.push(this.colorEntry(e, st2));
          widths.push(e.length);
        }
        this.writeColumns(colored, widths, 80);
      }
    } catch (e) {
      this.writeln(`\x1b[31mls: ${(e as Error).message}\x1b[0m`);
    }
  }

  private writeColumns(items: string[], widths: number[], termCols: number): void {
    if (items.length === 0) return;
    let maxW = 0;
    for (const w of widths) if (w > maxW) maxW = w;
    const colW = maxW + 2;
    const cols = Math.max(1, Math.floor(termCols / colW));
    for (let i = 0; i < items.length; i++) {
      const padding = colW - widths[i];
      this.write(items[i]);
      if ((i + 1) % cols === 0 || i === items.length - 1) {
        this.write('\r\n');
      } else {
        this.write(' '.repeat(Math.max(1, padding)));
      }
    }
  }

  private colorEntry(name: string, st: fs.Stat | null): string {
    if (!st) return name;
    if (st.isDirectory()) return `\x1b[1;34m${name}\x1b[0m`;
    if (st.isSymbolicLink && st.isSymbolicLink()) return `\x1b[36m${name}\x1b[0m`;
    // 可执行权限位 (mode 低位 0o111)
    if ((st.mode & 0o111) !== 0) return `\x1b[1;32m${name}\x1b[0m`;
    return name;
  }

  private formatLong(name: string, st: fs.Stat): string {
    const isDir = st.isDirectory();
    const type = isDir ? 'd' : '-';
    const m = st.mode;
    const perm =
      ((m & 0o400) ? 'r' : '-') + ((m & 0o200) ? 'w' : '-') + ((m & 0o100) ? 'x' : '-') +
        ((m & 0o040) ? 'r' : '-') + ((m & 0o020) ? 'w' : '-') + ((m & 0o010) ? 'x' : '-') +
        ((m & 0o004) ? 'r' : '-') + ((m & 0o002) ? 'w' : '-') + ((m & 0o001) ? 'x' : '-');
    const size = String(st.size).padStart(10);
    const colored = this.colorEntry(name, st);
    return `${type}${perm}  ${size}  ${colored}`;
  }

  private async cmdCat(args: string[]): Promise<void> {
    if (args.length === 0) {
      this.writeln('cat: missing file operand');
      return;
    }
    for (const a of args) {
      const path = PathResolver.resolve(this.cwd, this.homeDir, a);
      try {
        if (!fs.accessSync(path)) {
          this.writeln(`\x1b[31mcat: ${a}: no such file\x1b[0m`);
          continue;
        }
        const st = fs.statSync(path);
        if (st.isDirectory()) {
          this.writeln(`\x1b[31mcat: ${a}: is a directory\x1b[0m`);
          continue;
        }
        // 大文件保护
        if (st.size > 4 * 1024 * 1024) {
          this.writeln(`\x1b[33mcat: ${a}: file too large (${st.size} bytes), use head/tail\x1b[0m`);
          continue;
        }
        const text = fs.readTextSync(path);
        // 把 LF 转成 CRLF, xterm 才正确换行
        this.write(text.replace(/\r?\n/g, '\r\n'));
        if (!text.endsWith('\n')) this.write('\r\n');
      } catch (e) {
        this.writeln(`\x1b[31mcat: ${a}: ${(e as Error).message}\x1b[0m`);
      }
    }
  }

  private writeBanner(): void {
    this.writeln('\x1b[1;32m╭─────────────────────────────────╮\x1b[0m');
    this.writeln('\x1b[1;32m│  HarmonyBox Debug Shell  v0.1   │\x1b[0m');
    this.writeln('\x1b[1;32m╰─────────────────────────────────╯\x1b[0m');
    this.writeln('type \x1b[33mhelp\x1b[0m to list commands');
    this.writeln('');
  }

  private writePrompt(): void {
    const shown = PathResolver.display(this.cwd, this.homeDir);
    // 缩短超长路径: 超过 30 字符时只显示最后两级
    let p = shown;
    if (p.length > 30) {
      const parts = p.split('/').filter(s => s.length > 0);
      if (parts.length > 2) p = '.../' + parts.slice(-2).join('/');
    }
    const promptStr = `\x1b[1;36mhbsh\x1b[0m:\x1b[1;34m${p}\x1b[0m$ `;
    this.prompt = promptStr;
    this.write(promptStr);
  }

  private clear(): void {
    this.webCtl.runJavaScript('window.termClear()');
  }

  private write(s: string): void {
    // 转义后传进 runJavaScript
    const esc = JSON.stringify(s);
    this.webCtl.runJavaScript(`window.termWrite(${esc})`).catch(() => {
      // TODO: Implement error handling.
    });
  }

  private writeln(s: string): void {
    this.write(s + '\r\n');
  }

  private handleByte(code: number, ch: string): void {
    // 转义序列状态机
    if (this.escState === 1) {
      if (ch === '[') { this.escState = 2; return; }
      this.escState = 0;
      return;
    }
    if (this.escState === 2) {
      this.escState = 0;
      switch (ch) {
        case 'A': this.historyPrev(); return;
        case 'B': this.historyNext(); return;
        case 'C': this.cursorRight(); return;
        case 'D': this.cursorLeft(); return;
        case 'H': this.cursorHome(); return;
        case 'F': this.cursorEnd(); return;
        case '3':
          // Delete 键是 ESC [ 3 ~, 简化版直接吞掉下一个 ~
          this.escState = 3;
          return;
      }
      return;
    }
    if (this.escState === 3) {
      this.escState = 0;
      if (ch === '~') this.deleteForward();
      return;
    }
    if (code === 27) { this.escState = 1; return; }  // ESC

    // 普通字符
    if (code === 13) {                         // Enter
      this.write('\r\n');
      this.runLine(this.buffer);
      this.buffer = '';
      this.cursor = 0;
      this.historyIdx = -1;
    } else if (code === 127 || code === 8) {   // Backspace
      if (this.cursor > 0) {
        this.buffer = this.buffer.slice(0, this.cursor - 1) +
          this.buffer.slice(this.cursor);
        this.cursor--;
        this.redrawLine();
      }
    } else if (code === 3) {                   // Ctrl+C
      this.write('^C\r\n');
      this.buffer = '';
      this.cursor = 0;
      this.historyIdx = -1;
      this.writePrompt();
    } else if (code === 12) {                  // Ctrl+L
      this.webCtl.runJavaScript('window.termClear()').catch(() => {
        // TODO: Implement error handling.
      });
      this.writePrompt();
      this.write(this.buffer);
      const back = this.buffer.length - this.cursor;
      if (back > 0) this.write(`\x1b[${back}D`);
    } else if (code === 1) {                   // Ctrl+A
      this.cursorHome();
    } else if (code === 5) {                   // Ctrl+E
      this.cursorEnd();
    } else if (code === 21) {                  // Ctrl+U: 删到行首
      this.buffer = this.buffer.slice(this.cursor);
      this.cursor = 0;
      this.redrawLine();
    } else if (code === 11) {                  // Ctrl+K: 删到行尾
      this.buffer = this.buffer.slice(0, this.cursor);
      this.redrawLine();
    } else if (code >= 32 && code < 127) {
      this.buffer = this.buffer.slice(0, this.cursor) + ch +
        this.buffer.slice(this.cursor);
      this.cursor++;
      this.redrawLine();
    }
  }

  private cursorLeft(): void {
    if (this.cursor > 0) {
      this.cursor--;
      this.write('\x1b[D');
    }
  }
  private cursorRight(): void {
    if (this.cursor < this.buffer.length) {
      this.cursor++;
      this.write('\x1b[C');
    }
  }
  private cursorHome(): void {
    if (this.cursor > 0) {
      this.write(`\x1b[${this.cursor}D`);
      this.cursor = 0;
    }
  }
  private cursorEnd(): void {
    const d = this.buffer.length - this.cursor;
    if (d > 0) {
      this.write(`\x1b[${d}C`);
      this.cursor = this.buffer.length;
    }
  }
  private deleteForward(): void {
    if (this.cursor < this.buffer.length) {
      this.buffer = this.buffer.slice(0, this.cursor) +
        this.buffer.slice(this.cursor + 1);
      this.redrawLine();
    }
  }
  private historyPrev(): void {
    if (this.history.length === 0) return;
    if (this.historyIdx === -1) {
      this.historySaved = this.buffer;
      this.historyIdx = this.history.length - 1;
    } else if (this.historyIdx > 0) {
      this.historyIdx--;
    } else return;
    this.buffer = this.history[this.historyIdx];
    this.cursor = this.buffer.length;
    this.redrawLine();
  }
  private historyNext(): void {
    if (this.historyIdx === -1) return;
    if (this.historyIdx < this.history.length - 1) {
      this.historyIdx++;
      this.buffer = this.history[this.historyIdx];
    } else {
      this.historyIdx = -1;
      this.buffer = this.historySaved;
      this.historySaved = '';
    }
    this.cursor = this.buffer.length;
    this.redrawLine();
  }
}