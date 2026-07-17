import { mkdtemp, open, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const command = process.argv.slice(2);

const reportEnvironmentNames = [
  'WORKFLOW_REPORT_API',
  'WORKFLOW_REPORT_TOKEN',
];

function redact(output) {
  let summary = output;
  for (const [name, value] of Object.entries(process.env)) {
    if (value && value.length >= 4 && /(?:token|secret|password|key|pat|envelope|release_id|build_id|internal_version|sha|ref)/i.test(name)) {
      summary = summary.split(value).join('[REDACTED]');
    }
  }

  return summary
    .replace(/(?:authorization:\s*(?:basic|bearer)\s+|(?:ghp_|github_pat_)[A-Za-z0-9_]+)[^\s'"`]+/gi, '[REDACTED]')
    .replace(/\b(?:run|release|build)[ _-]?id\s*[:=]\s*[^\s,]+/gi, '[REDACTED]')
    .replace(/\b(?:commit|sha|ref)\s*[:=]\s*[^\s,]+/gi, '[REDACTED]');
}

async function reportFailure(logPath, status) {
  const report = Object.fromEntries(reportEnvironmentNames.map((name) => [name, process.env[name]]));
  const runId = process.env.GITHUB_RUN_ID;
  if (!Object.values(report).every(Boolean) || !runId) return;

  try {
    const log = await readFile(logPath, 'utf8');
    const summary = redact(log.split(/\r?\n/).filter(Boolean).slice(-100).join('\n')).slice(-12000);
    await fetch(report.WORKFLOW_REPORT_API, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${report.WORKFLOW_REPORT_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        run_id: runId,
        status: 'failed',
        exit_code: status,
        summary,
      }),
      signal: AbortSignal.timeout(10000),
    });
  } catch {
    // Reporting must not replace the original command failure.
  }
}

if (command[0] !== '--' || command.length < 2) {
  process.stderr.write('Quiet command failed.\n');
  process.exitCode = 1;
} else {
  let logDirectory;
  let logPath;
  let status = 1;

  try {
    logDirectory = await mkdtemp(join(process.env.RUNNER_TEMP || tmpdir(), 'run-quiet-'));
    logPath = join(logDirectory, 'command.log');
    const log = await open(logPath, 'w');
    try {
      status = await new Promise((resolve) => {
        const child = spawn(command[1], command.slice(2), {
          env: process.env,
          stdio: ['inherit', log.fd, log.fd],
        });
        child.once('error', () => resolve(1));
        child.once('exit', (code) => resolve(code ?? 1));
      });
    } finally {
      await log.close();
    }
  } catch {
    status = 1;
  } finally {
    if (status !== 0 && logPath) await reportFailure(logPath, status);
    if (logDirectory) {
      try {
        await rm(logDirectory, { force: true, recursive: true });
      } catch {
        status = 1;
      }
    }
  }

  if (status !== 0) {
    process.stderr.write(`Quiet command failed with exit code ${status}. Detailed output was discarded.\n`);
    process.exitCode = status;
  }
}
