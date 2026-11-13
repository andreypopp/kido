import { writeSync } from 'node:fs';
import { parseArgs, getPackageDir } from '@earendil-works/pi-coding-agent';
import { startupResult } from './koa-args.ts';

export default function () {
  const result = startupResult(parseArgs(JSON.parse(process.env.KOA_STARTUP_ARGS ?? '[]')));
  writeSync(3, JSON.stringify({ ...result, packageRoot: getPackageDir() }) + '\n');
  process.exit('error' in result ? 1 : 0);
}
