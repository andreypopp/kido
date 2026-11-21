import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import type { MetricsMode } from "./koa-records.ts";

export type PageSource = { document: string; style: string; script: string; hash: string };

export async function readPage(location: URL): Promise<PageSource> {
  const read = async (): Promise<PageSource> => {
    const bytes = await Promise.all(["page.html", "page.css", "page.js"].map(name => readFile(new URL(name, location))));
    const hash = createHash("sha256");
    for (const part of bytes) hash.update(String(part.length) + ":").update(part);
    const [document = "", style = "", script = ""] = bytes.map(part => part.toString("utf8"));
    return { document, style, script, hash: hash.digest("hex") };
  };
  const first = await read(), second = await read();
  if (first.hash !== second.hash) throw new Error("the page changed during the read");
  return second;
}

export function assemblePage({ document, style, script }: PageSource, instance: string, metrics?: MetricsMode): string {
  const meta = `<meta name="koa-instance" content="${instance}">${metrics ? `<meta name="koa-metrics" content="${metrics}">` : ""}`;
  return document.replace("<head>", () => `<head>${meta}`).replace("<!-- style -->", () => `<style>${style}</style>`).replace("<!-- script -->", () => `<script type="module">${script.replace(/<\/script/gi, "<\\/script")}</script>`);
}
