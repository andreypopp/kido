export const pathSeparator = /\s|(?=\p{Punctuation})[\p{Script_Extensions=Han}\p{Script_Extensions=Hiragana}\p{Script_Extensions=Katakana}\p{Script_Extensions=Hangul}\p{Script_Extensions=Bopomofo}]|[，．：；！？（）［］｛｝“”‘’…—]/u;
const separator = new RegExp("[\"'=]|" + pathSeparator.source, "u");

// Must agree with pi's own CombinedAutocompleteProvider (extractAtPrefix), since
// the merged list carries one prefix for the agents and the files both.
export function fileToken(before: string): { text: string; quoted: boolean; agent?: string } | undefined {
  const wrappers: Record<string, string> = { "(": ")", "[": "]", "{": "}", "<": ">", "`": "`" };
  const quote = before.lastIndexOf('"');
  if ((before.match(/"/g)?.length ?? 0) % 2 && before[quote - 1] === "@") {
    let start = quote - 1;
    while (wrappers[before[start - 1]]) start--;
    if (start === 0 || separator.test(before[start - 1])) return { text: before.slice(quote - 1), quoted: true };
  }
  let token = before.split(separator).at(-1) ?? "";
  while (wrappers[token[0]] && !token.includes(wrappers[token[0]], 1)) token = token.slice(1);
  return token.startsWith("@") ? { text: token, quoted: false, agent: token.slice(1) } : undefined;
}

export function atToken(before: string): string | undefined {
  return fileToken(before)?.agent;
}

export function slashToken(text: string, pos: number): string | undefined {
  const before = text.slice(0, pos);
  return !before.includes("\n") && /^\s*\/[^\s]*$/.test(before) ? before.trimStart() : undefined;
}
