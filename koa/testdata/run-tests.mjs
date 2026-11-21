import { run } from "node:test";
import { spec } from "node:test/reporters";
import startReporter from "./start-reporter.mjs";

const tests = run({ files: process.argv.slice(2), concurrency: 4, timeout: 60000 });
tests.on("test:fail", () => { process.exitCode = 1; });
tests.pipe(new spec()).pipe(process.stdout, { end: false });
tests.compose(startReporter).pipe(process.stdout, { end: false });
