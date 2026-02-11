/**
 * Handles exec.run commands from the gateway.
 * Executes shell commands on the device via native popen().
 */
import { execCmd, ExecResult } from 'libexec.so';
import { LogService } from '../../common/LogService';

const TAG = 'ExecCap';

interface ExecParams {
  command: string;
  timeoutMs?: number;
}

export class ExecCapability {
  private log: LogService = LogService.getInstance();

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    if (!paramsJson || paramsJson.length === 0) {
      return JSON.stringify({ ok: false, error: 'No params provided' });
    }

    let params: ExecParams;
    try {
      params = JSON.parse(paramsJson) as ExecParams;
    } catch {
      return JSON.stringify({ ok: false, error: 'Invalid JSON params' });
    }

    let command = params.command;
    if (!command || command.length === 0) {
      return JSON.stringify({ ok: false, error: 'No command provided' });
    }

    this.log.info(TAG, `Executing command: ${command}`);

    try {
      let result: ExecResult = execCmd(command);
      this.log.info(TAG, `Command finished: exitCode=${result.exitCode} stdoutLen=${result.stdout.length}`);

      let output: string = JSON.stringify({
        ok: true,
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      });

      // Limit total response size to avoid WebSocket overflow
      if (output.length > 100000) {
        output = JSON.stringify({
          ok: true,
          exitCode: result.exitCode,
          stdout: result.stdout.substring(0, 50000) + '\n...[truncated]',
          stderr: result.stderr.substring(0, 5000),
        });
      }

      return output;
    } catch (err) {
      let msg = (err as Error).message ?? String(err);
      this.log.error(TAG, `Command failed: ${msg}`);
      return JSON.stringify({ ok: false, error: msg });
    }
  }
}
