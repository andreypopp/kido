import { readFile } from "node:fs/promises";

export async function assemblePage(location: URL): Promise<string> {
  const read = (name: string) => readFile(new URL(name, location), "utf8");
  const [document, style, marked, remend, markdown, page] = await Promise.all([
    read("koa-page.html"), read("koa-page.css"), read("vendor/marked.js"), read("vendor/remend.js"), read("koa-markdown.js"), read("koa-page.js"),
  ]);
  const identifier = (name: string) => name.replaceAll("-", "_") + "Module";
  const module = (source: string, name: string) => {
    const functions: string[] = [];
    const body = source.replace(/^import (.+?) from ['"](?:.*\/)?([^/'"]+)\.js['"];?$/gm, (_, bindings: string, dependency: string) => `const ${bindings} = ${identifier(dependency)}${bindings.startsWith("{") ? "" : ".default"};`)
      .replace(/^export function (\w+)/gm, (_, name: string) => { functions.push(name); return `function ${name}`; })
      .replace(/export\s*\{([^}]+)\};?\s*(?:\/\/# sourceMappingURL=[^\n]*\s*)?$/, (_, list: string) => "return {" + list.split(",").map(entry => { const [local, , exported] = entry.trim().split(/\s+/); return `${exported ?? local}:${local}`; }).join(",") + "};");
    return `const ${identifier(name)} = (() => {${body}\n${functions.length ? "return {" + functions.join(",") + "};" : ""}\n})();`;
  };
  const script = module(marked, "marked") + "\n" + module(remend, "remend") + "\n" + module(markdown, "koa-markdown") + "\n" + module(page, "koa-page");
  return document.replace("<!-- style -->", () => `<style>${style}</style>`).replace("<!-- script -->", () => `<script type="module">${script.replace(/<\/script/gi, "<\\/script")}</script>`);
}
