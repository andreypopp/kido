import { readFile } from "node:fs/promises";
import type { MetricsMode } from "./koa-records.ts";

export async function assemblePage(location: URL, instance: string, metrics?: MetricsMode): Promise<string> {
  const read = (name: string) => readFile(new URL(name, location), "utf8");
  const [document, style, script] = await Promise.all([
    read("page.html"), read("page.css"), read("page.js"),
  ]);
  const meta = `<meta name="koa-instance" content="${instance}">${metrics ? `<meta name="koa-metrics" content="${metrics}">` : ""}`;
  return document.replace("<head>", () => `<head>${meta}`).replace("<!-- style -->", () => `<style>${style}</style>`).replace("<!-- script -->", () => `<script type="module">${script.replace(/<\/script/gi, "<\\/script")}</script>`);
}
