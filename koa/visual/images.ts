import type { Browser } from "playwright";

export async function image(browser: Browser, width: number, height: number, a: number, b: number, label: string): Promise<Buffer> {
  const page = await browser.newPage();
  try {
    const base64 = await page.evaluate(({ width, height, a, b, label }) => {
      const canvas = document.createElement("canvas");
      canvas.width = width; canvas.height = height;
      const context = canvas.getContext("2d");
      if (!context) throw Error("Canvas 2D is unavailable");
      const color = (value: number) => `#${value.toString(16).padStart(6, "0")}`;
      const gradient = context.createLinearGradient(0, 0, width, height);
      gradient.addColorStop(0, color(a)); gradient.addColorStop(1, color(b));
      context.fillStyle = gradient; context.fillRect(0, 0, width, height);
      context.fillStyle = "rgba(255,255,255,.82)";
      context.beginPath(); context.roundRect(width * .08, height * .14, width * .84, height * .72, Math.min(width, height) * .03); context.fill();
      for (const [x, y, w, h, alpha] of [[.12,.75,.5,.05,.55],[.12,.66,.76,.04,.3],[.12,.58,.7,.04,.3]]) {
        context.fillStyle = `rgba(51,51,51,${alpha})`;
        context.beginPath(); context.roundRect(width*x, height*(1-y-h), width*w, height*h, 3); context.fill();
      }
      context.fillStyle = color(a); context.globalAlpha = .35;
      context.beginPath(); context.roundRect(width*.12, height*.46, width*.76, height*.3, 4); context.fill();
      context.globalAlpha = .85; context.fillStyle = "white";
      context.font = `${Math.max(10, height*.045)}px ui-monospace, SFMono-Regular, Menlo, monospace`;
      context.textAlign = "center"; context.textBaseline = "middle";
      context.fillText(label, width / 2, height * .945);
      return canvas.toDataURL("image/png").split(",")[1];
    }, { width, height, a, b, label });
    return Buffer.from(base64, "base64");
  } finally { await page.close(); }
}
