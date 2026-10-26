const { spawnSync } = require('node:child_process');
const path = require('node:path');
const esbuild = require('esbuild');

const root = path.resolve(__dirname, '..');
try {
  esbuild.buildSync({ entryPoints: [path.join(root, 'public/app.js')], bundle: true, format: 'iife', target: 'es2020', outfile: path.join(root, 'public/assets/app.js') });
} catch (error) {
  reportFailure('Frontend build failed', error.message);
}
const builderArgs = process.argv.slice(2);
if (!builderArgs.includes('--publish')) builderArgs.push('--publish', 'never');
const result = spawnSync(process.execPath, [require.resolve('electron-builder/cli.js'), ...builderArgs], { cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const output = `${result.stdout || ''}${result.stderr || ''}`;
if (output) process.stdout.write(output);
if (result.error || result.status !== 0) reportFailure('Desktop packaging failed', result.error?.message || output.slice(-3500) || `process exited with code ${result.status}`);

function reportFailure(title, detail) {
  const escaped = String(detail).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
  console.error(`::error title=${title}::${escaped}`);
  process.exit(1);
}
