import { readFile } from "node:fs/promises";

export async function assemblePage(location: URL): Promise<string> {
  const read = (name: string) => readFile(new URL(name, location), "utf8");
  const [document, style, script] = await Promise.all([
    read("page.html"), read("page.css"), read("page.js"),
  ]);
  return document.replace("<!-- style -->", () => `<style>${style}</style>`).replace("<!-- script -->", () => `<script type="module">${script.replace(/<\/script/gi, "<\\/script")}</script>`);
}
