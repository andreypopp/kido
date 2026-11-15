export default async function* (source) {
  for await (const { type, data } of source) {
    if (data?.nesting !== 0) continue;
    if (type === "test:start") yield `START ${data.name}\n`;
    else if (type === "test:pass" || type === "test:fail") yield `END ${type === "test:pass" ? "ok" : "FAIL"} ${data.name}\n`;
  }
}
