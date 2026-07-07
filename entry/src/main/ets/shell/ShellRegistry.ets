import wl from 'libentry.so';

export interface ShellCmdMeta {
  desc: string;
  usage?: string;
  streaming?: boolean;
}

export interface ShellIO {
  write(s: string): void;      // 尾部不自动补换行
  writeln(s: string): void;    // 补 \r\n
  err(s: string): void;        // 红字 + \r\n
}

export type ShellCmdHandler = (
  args: string[],
  env: Record<string, string>,
  io: ShellIO
) => Promise<number> | number;

class ShellIOImpl implements ShellIO {
  write(s: string): void {
    if (s.length > 0) wl.shellStreamWrite(s);
  }
  writeln(s: string): void {
    wl.shellStreamWrite(s + '\r\n');
  }
  err(s: string): void {
    wl.shellStreamWrite('\x1b[31m' + s + '\x1b[0m\r\n');
  }
}

const io: ShellIO = new ShellIOImpl();

export class ShellRegistry {
  static register(name: string, meta: ShellCmdMeta, handler: ShellCmdHandler): boolean {
    const wrapper = (args: string[], env: Record<string, string>): void => {
      const finish = (code: number): void => {
        wl.shellCommandDone(code);
      };
      try {
        const r = handler(args, env, io);
        if (r instanceof Promise) {
          r.then((code: number): void => { finish(typeof code === 'number' ? code : 0); })
            .catch((e: Error): void => {
              io.err('handler error: ' + (e && e.message ? e.message : String(e)));
              finish(1);
            });
        } else {
          finish(typeof r === 'number' ? r : 0);
        }
      } catch (e) {
        const msg: string = (e as Error)?.message ?? String(e);
        io.err('handler threw: ' + msg);
        finish(1);
      }
    };
    return wl.shellRegister(name, meta, wrapper);
  }

  static unregister(name: string): boolean {
    return wl.shellUnregister(name);
  }
}