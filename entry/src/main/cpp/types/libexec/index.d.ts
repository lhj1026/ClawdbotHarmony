/**
 * Native exec module - runs shell commands via popen().
 */

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

/**
 * Execute a shell command and return the result synchronously.
 * @param command - The shell command to execute.
 * @returns ExecResult with stdout, stderr, and exitCode.
 */
export const execCmd: (command: string) => ExecResult;
