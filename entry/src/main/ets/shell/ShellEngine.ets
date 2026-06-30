// entry/src/main/ets/shell/ShellEngine.ets
import { webview } from '@kit.ArkWeb';

export class ShellEngine {
  private buffer: string = '';
  private cursor: number = 0;
  private history: string[] = [];
  private historyIdx: number = -1;
  private prompt: string = 'hbsh$ ';
  private cwd: string = '/';
  private webCtl: webview.WebviewController;

  constructor(ctl: webview.WebviewController) {
    this.webCtl = ctl;
  }

  start(): void {
    this.writeBanner();
    this.writePrompt();
  }

  // 来自 web 的输入
  feed(data: string): void {
    for (let i = 0; i < data.length; i++) {
      this.handleChar(data.charCodeAt(i), data[i]);
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
    this.history.push(trimmed);
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
    this.writeln('available: help clear echo pwd cd ls cat');
  }

  private async cmdCd(args: string[]): Promise<void> {
    // 占位, 下一步接 fs
    this.writeln('cd: not implemented yet');
  }

  private async cmdLs(args: string[]): Promise<void> {
    this.writeln('ls: not implemented yet');
  }

  private async cmdCat(args: string[]): Promise<void> {
    this.writeln('cat: not implemented yet');
  }

  private writeBanner(): void {
    this.writeln('\x1b[1;32m╭─────────────────────────────────╮\x1b[0m');
    this.writeln('\x1b[1;32m│  HarmonyBox Debug Shell  v0.1   │\x1b[0m');
    this.writeln('\x1b[1;32m╰─────────────────────────────────╯\x1b[0m');
    this.writeln('type \x1b[33mhelp\x1b[0m to list commands');
    this.writeln('');
  }

  private writePrompt(): void {
    this.write(this.prompt);
  }

  private clear(): void {
    this.webCtl.runJavaScript('window.termClear()');
  }

  private write(s: string): void {
    // 转义后传进 runJavaScript
    const esc = JSON.stringify(s);
    this.webCtl.runJavaScript(`window.termWrite(${esc})`);
  }

  private writeln(s: string): void {
    this.write(s + '\r\n');
  }
}