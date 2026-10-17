/* render-video.mjs — 把 index.html 离线录成 MP4。
 *
 * 不用屏幕录制、不用 MediaRecorder：页面带 ?render=1 时会被外部按固定 fps
 * 调 __renderFrame()，用 1/60 细步长把整条时间线确定性推进再重画一帧；
 * 这里通过 CDP 逐帧 Page.captureScreenshot 拿图（**带 CSS 的扫描线/暗角/辉光**，
 * canvas.toDataURL 拿不到这些层），最后交给 ffmpeg 编码。
 *
 * 音轨也不录，而是页面用 __renderAudio() 拿 OfflineAudioContext 按当时记下的
 * 每次键击参数离线合成 WAV，再由 ffmpeg 合流 —— 这样画面和声音都是确定的。
 *
 * 用法：
 *   node tools/render-video.mjs --fps=15
 *   node tools/render-video.mjs --fps=15 --limit=40      # 只渲 40 帧做试跑
 *   node tools/render-video.mjs --fps=15 --encode=0      # 只渲帧，不调 ffmpeg
 *   node tools/render-video.mjs --audio-only=1           # 只跑时间线取键击轨 + timing.json
 *
 * --audio-only 不截图。录片 99% 的耗时在 Page.captureScreenshot（~540ms/帧），
 * 光跑 __renderFrame 只要几毫秒，所以整条时间线走一遍拿键击只要半分钟。
 *
 * 注意：Node 的 child_process 在本沙箱里不能用 piped stdio（EPERM），
 * 所以 Chrome / ffmpeg 一律用 stdio:"ignore"，只靠文件系统交换数据。
 */
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync, existsSync, statSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..");
const opt = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.replace(/^--/, "").split("=");
  return [m[0], m.length > 1 ? m[1] : "1"];
}));

const FPS = Number(opt.fps || 15);
const W = Number(opt.w || 1600), H = Number(opt.h || 960);
const LIMIT = Number(opt.limit || 0);
const PORT = Number(opt.port || 9555);
const QUALITY = Number(opt.quality || 86);
const CHROME = opt.chrome || "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const WORK = resolve(ROOT, "_video");
const FRAMES = resolve(WORK, "frames");
const OUT = resolve(ROOT, opt.out || "preview/个人电脑发展史.mp4");

const t0 = Date.now();
const el = () => ((Date.now() - t0) / 1000).toFixed(1) + "s";
const log = (...a) => console.log(`[${el()}]`, ...a);

/* ─────────────────── 极简 CDP 客户端 ─────────────────── */
class CDP {
  constructor(ws) {
    this.ws = ws; this.seq = 0; this.pending = new Map();
    ws.addEventListener("message", ev => {
      const msg = JSON.parse(ev.data);
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      msg.error ? p.rej(new Error(msg.error.message)) : p.res(msg.result);
    });
    ws.addEventListener("close", () => {
      for (const p of this.pending.values()) p.rej(new Error("ws closed"));
      this.pending.clear();
    });
  }
  static connect(url) {
    return new Promise((res, rej) => {
      const ws = new WebSocket(url);
      ws.addEventListener("open", () => res(new CDP(ws)));
      ws.addEventListener("error", () => rej(new Error("ws connect failed: " + url)));
    });
  }
  send(method, params) {
    const id = ++this.seq;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params: params || {} }));
    });
  }
  async eval(expr, awaitPromise = false) {
    const r = await this.send("Runtime.evaluate", {
      expression: expr, returnByValue: true, awaitPromise
    });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.text + " " + (r.exceptionDetails.exception || {}).description);
    return r.result.value;
  }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));
const jget = async url => (await fetch(url)).json();

/* ─────────────────── 启动 Chrome ─────────────────── */
rmSync(resolve(WORK, "profile"), { recursive: true, force: true });
rmSync(FRAMES, { recursive: true, force: true });
mkdirSync(FRAMES, { recursive: true });
mkdirSync(resolve(WORK, "profile"), { recursive: true });

log("launching chrome …");
const chrome = spawn(CHROME, [
  "--headless=new", "--no-first-run", "--no-default-browser-check",
  "--no-sandbox", "--disable-gpu-sandbox", "--disable-dev-shm-usage",
  "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
  "--hide-scrollbars", "--force-device-scale-factor=1", "--mute-audio",
  `--window-size=${W},${H}`,
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${resolve(WORK, "profile")}`,
  "about:blank"
], { stdio: "ignore" });

let killer = chrome;
function shutdown() {
  try { spawnSync("taskkill", ["/PID", String(killer.pid), "/T", "/F"], { stdio: "ignore" }); } catch { }
}

let list = null;
for (let i = 0; i < 120 && !list; i++) {
  await sleep(250);
  try { list = await jget(`http://127.0.0.1:${PORT}/json/list`); } catch { }
}
if (!list) { shutdown(); throw new Error("devtools port never opened"); }

const page = list.find(t => t.type === "page");
if (!page) { shutdown(); throw new Error("no page target"); }
const cdp = await CDP.connect(page.webSocketDebuggerUrl);
await cdp.send("Page.enable");
await cdp.send("Runtime.enable");

const url = pathToFileURL(resolve(ROOT, "index.html")).href + "?render=1";
log("navigate →", url);
await cdp.send("Page.navigate", { url });

let ready = false;
for (let i = 0; i < 240 && !ready; i++) {
  await sleep(250);
  try { ready = await cdp.eval("document.readyState==='complete' && typeof window.__renderFrame==='function'"); } catch { }
}
if (!ready) {
  const err = await cdp.eval("(window.__ERR__||[]).join(' | ')").catch(() => "");
  shutdown();
  throw new Error("page never became ready. JS errors: " + err);
}

const view = await cdp.eval("[innerWidth,innerHeight]");
/* --window-size 在 headless=new 里给的是外框尺寸，实际视口会小一圈；
   必须用 Emulation 强制成设计尺寸，否则录出来是 1576×805。 */
if (view[0] !== W || view[1] !== H) {
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: W, height: H, deviceScaleFactor: 1, mobile: false
  });
  await sleep(700);
}
const view2 = await cdp.eval("[innerWidth,innerHeight]");
log("viewport", view2, "| total sec", await cdp.eval("__TOTAL_SEC()"));
if (view2[0] !== W || view2[1] !== H) log(`!! viewport mismatch, expect ${W}x${H}`);

const totalSec = await cdp.eval("__TOTAL_SEC()");
const totalFrames = LIMIT || (await cdp.eval(`__TOTAL_FRAMES(${FPS})`));

/* ─────────────────── 只截一张结束卡（成片要拼在片尾） ───────────────────
 * 正片跑到最后一帧时 S.ended 还没置真，所以成片里没有结束卡；
 * 这里以 ?render=1&end=1 打开，画一帧就拿图 —— 此时 RENDER_MODE 为真，
 * 结束卡不会画「R 重播 / SPACE 暂停」这类只对交互版有意义的提示。 */
if (opt["endcard"]) {
  await cdp.send("Page.navigate", { url: url.replace("?render=1", "?render=1&end=1") });
  let ok = false;
  for (let i = 0; i < 240 && !ok; i++) {
    await sleep(250);
    try { ok = await cdp.eval("document.readyState==='complete' && typeof window.__renderFrame==='function'"); } catch { }
  }
  await sleep(600);
  await cdp.eval(`__renderFrame(${FPS})`);
  const shot = await cdp.send("Page.captureScreenshot", {
    format: "png", fromSurface: true, captureBeyondViewport: false
  });
  const outP = resolve(ROOT, opt["endcard"]);
  mkdirSync(dirname(outP), { recursive: true });
  writeFileSync(outP, Buffer.from(shot.data, "base64"));
  const vp = await cdp.eval("[innerWidth,innerHeight]");
  shutdown();
  log("endcard →", outP, statSync(outP).size, "bytes, viewport", vp);
  process.exit(0);
}

/* ─────────────────── 只取音轨（不截图） ─────────────────── */
if (opt["audio-only"] === "1") {
  const meta = JSON.parse(await cdp.eval(
    "JSON.stringify(STAGES.map(s=>({n:s.n,year:s.year,tag:s.tag,cn:s.cn,dur:s.dur})))"));
  let acc = 0;
  const stages = meta.map(s => { const o = { ...s, start: +acc.toFixed(4) }; acc += s.dur; return o; });
  writeFileSync(resolve(WORK, "timing.json"),
    JSON.stringify({ fps: FPS, total: +totalSec.toFixed(4), stages }, null, 1));
  mkdirSync(WORK, { recursive: true });
  log(`timeline: ${stages.length} stages, ${totalSec.toFixed(2)}s`);

  const tA = Date.now();
  for (let i = 0; i < totalFrames; i++) {
    await cdp.eval(`__renderFrame(${FPS})`);
    if (i % 500 === 0) log(`audio pass ${i}/${totalFrames}  ${((Date.now() - tA) / (i + 1)).toFixed(1)}ms/f`);
  }
  log("click events recorded:", await cdp.eval("__CLICK_COUNT()"));
  const b64 = await cdp.eval("__renderAudio()", true);
  const wavP = resolve(WORK, "audio.wav");
  writeFileSync(wavP, Buffer.from(b64, "base64"));
  log("audio.wav", (statSync(wavP).size / 1048576).toFixed(1) + " MB");
  shutdown();
  await sleep(300);
  log("done (audio only)");
  process.exit(0);
}

log(`rendering ${totalFrames} frames @ ${FPS}fps  (${(totalSec / 60).toFixed(1)} min of film)`);

/* ─────────────────── 逐帧渲染 + 截图 ─────────────────── */
const pad = n => String(n).padStart(5, "0");
const tRender = Date.now();
for (let i = 0; i < totalFrames; i++) {
  const st = await cdp.eval(`__renderFrame(${FPS})`);
  const shot = await cdp.send("Page.captureScreenshot", {
    format: "jpeg", quality: QUALITY, fromSurface: true, captureBeyondViewport: false
  });
  writeFileSync(resolve(FRAMES, `f${pad(i)}.jpg`), Buffer.from(shot.data, "base64"));
  if (i % 25 === 0 || i === totalFrames - 1) {
    const done = i + 1, rate = (Date.now() - tRender) / done;
    const left = ((totalFrames - done) * rate) / 1000;
    log(`frame ${done}/${totalFrames}  stage ${st.stage + 1}${st.ended ? " (end card)" : ""}  ` +
        `${rate.toFixed(0)}ms/f  eta ${(left / 60).toFixed(1)}min`);
  }
}

/* ─────────────────── 合成音轨 ─────────────────── */
/* --audio=0 跳过 OfflineAudioContext 合成：几千次键击的离线音轨在无头 Chrome 里
   可能跑上半小时（实测 32 分钟没出来），而键击的时间点完全由 POST 打字进度决定，
   稿子不改的话可以复用上一版成片的音轨。 */
if (opt.audio === "0") {
  log("skip audio (--audio=0)");
} else {
  const clicks = await cdp.eval("__CLICK_COUNT()");
  log(`click events recorded: ${clicks}`);
  const wavPath = resolve(WORK, "audio.wav");
  try {
    const b64 = await cdp.eval("__renderAudio()", true);
    writeFileSync(wavPath, Buffer.from(b64, "base64"));
    log("audio.wav", (statSync(wavPath).size / 1048576).toFixed(1) + " MB");
  } catch (e) {
    log("!! audio render failed:", e.message, "— 视频将没有音轨");
  }
}

shutdown();
await sleep(400);
log("chrome closed, frames on disk:", statSync(resolve(FRAMES, `f${pad(totalFrames - 1)}.jpg`)).size, "bytes last");

/* ─────────────────── ffmpeg 编码 ─────────────────── */
if (opt.encode === "0") {
  log("skip encode. frames in", FRAMES);
  process.exit(0);
}

const wavPath2 = resolve(WORK, "audio.wav");
const hasAudio = existsSync(wavPath2);
const ffArgs = [
  "-y", "-hide_banner", "-loglevel", "error",
  "-framerate", String(FPS), "-i", resolve(FRAMES, "f%05d.jpg")
];
if (hasAudio) ffArgs.push("-i", wavPath2);
ffArgs.push(
  "-c:v", "libx264", "-preset", "slow", "-crf", String(opt.crf || 20),
  "-pix_fmt", "yuv420p", "-profile:v", "high", "-level", "4.1",
  "-movflags", "+faststart",
  "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"
);
if (hasAudio) ffArgs.push("-c:a", "aac", "-b:a", "160k", "-shortest");
ffArgs.push(OUT);

mkdirSync(dirname(OUT), { recursive: true });
log("ffmpeg →", OUT);
const ff = spawnSync("ffmpeg", ffArgs, { stdio: "inherit" });
if (ff.status !== 0) throw new Error("ffmpeg exited " + ff.status);
log("done:", OUT, (statSync(OUT).size / 1048576).toFixed(1) + " MB", "in", el());
