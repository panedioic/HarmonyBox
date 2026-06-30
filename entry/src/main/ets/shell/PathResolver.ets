import { fileIo as fs } from '@kit.CoreFileKit';

export class PathResolver {
  static resolve(cwd: string, home: string, input: string): string {
    if (!input || input.length === 0) return cwd;
    // ~ 展开
    if (input === '~') return home;
    if (input.startsWith('~/')) input = home + input.substring(1);
    // 绝对路径
    let abs: string;
    if (input.startsWith('/')) {
      abs = input;
    } else {
      abs = cwd + '/' + input;
    }
    return PathResolver.normalize(abs);
  }

  // 规范化: 处理 . 和 .. 和重复斜杠
  static normalize(p: string): string {
    const parts = p.split('/');
    const out: string[] = [];
    for (const seg of parts) {
      if (seg === '' || seg === '.') continue;
      if (seg === '..') {
        if (out.length > 0) out.pop();
        continue;
      }
      out.push(seg);
    }
    return '/' + out.join('/');
  }

  // 给 ls / pwd 展示用, 把 home 替换成 ~
  static display(p: string, home: string): string {
    if (p === home) return '~';
    if (p.startsWith(home + '/')) return '~' + p.substring(home.length);
    return p;
  }
}