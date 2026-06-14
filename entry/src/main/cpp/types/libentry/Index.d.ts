export interface ExecResult {
  code: number;
  stdout: string;
}

export const startWaylandServer: (sockPath: string) => boolean;
export const stopClient: () => void;
export const stopAll: () => void;
export const setStateCallback: (cb: (state: string) => void) => void;
export const execCapture: (exePath: string, argv: string[], libPath: string) => Promise<ExecResult>;
export const stopCli: (pid: number) => void;
export const setCliCallback: (cb: (pid: number, event: string, data: string) => void) => void;

export const launchClient: (
  exePath: string, argv: string[], sockPath: string,
  libPath: string, extraEnv: string[]
) => number;

export const launchCli: (
  exePath: string, argv: string[], libPath: string,
  cwd: string, extraEnv: string[]
) => number;