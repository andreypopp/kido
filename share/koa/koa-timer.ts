import { errorText } from "../pi/text.ts";

export function later(fn: () => void, ms: number): NodeJS.Timeout {
  return setTimeout(() => {
    try { fn(); } catch (error) { process.stderr.write(`koa: ${errorText(error)}\n`); }
  }, ms);
}
