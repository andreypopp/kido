export async function deadline<T>(label: string, seconds: number, task: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try { return await Promise.race([task, new Promise<never>((_, reject) => { timer = setTimeout(() => reject(Error(`Deadline: ${label}`)), seconds * 1000); })]); }
  finally { clearTimeout(timer); }
}
