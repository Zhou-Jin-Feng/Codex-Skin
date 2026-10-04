import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { probeVideoDecode } from "../runtime/video-decode-probe.mjs";
import { readImageMetadata, readImageAnimation } from "../runtime/image-metadata.mjs";
import { validateVideoFile } from "../windows/scripts/video-decode-probe.mjs";

const hevc = Buffer.from(await fs.readFile(new URL("../tests/fixtures/hevc-32x32-2fps.mp4.base64", import.meta.url), "utf8"), "base64");
assert.equal(readImageAnimation(hevc, ".mp4").codec, "hvc1");
assert.equal(readImageMetadata(hevc, ".mp4").width, 32);
const hev1 = Buffer.from(hevc);
hev1.write("hev1", hev1.indexOf("hvc1", hev1.indexOf("stsd")));
assert.equal(readImageAnimation(hev1, ".mp4").codec, "hev1");
const broken = Buffer.from(hevc);
broken[broken.indexOf("hvcC") + 4] = 0;
assert.equal(readImageMetadata(broken, ".mp4"), null, "Malformed HEVC configuration must be rejected");
const missingSets = Buffer.from(hevc);
missingSets[missingSets.indexOf("hvcC") + 4 + 22] = 0;
assert.equal(readImageMetadata(missingSets, ".mp4"), null);

const probeOutcomes = ["frame", "error", "timeout", "disconnect", "navigation",
  "hidden-frame", "hidden-timeout", "visible-first-frame"];
for (const outcome of probeOutcomes) {
  const nodes = [];
  const timers = new Map();
  const revoked = [];
  const calls = [];
  let frameCallback;
  let timerId = 0;
  const hiddenPage = outcome.startsWith("hidden-");
  const context = {
    window: {},
    document: {
      visibilityState: hiddenPage ? "hidden" : "visible",
      body: { append(...elements) { nodes.push(...elements); } },
      createElement(tag) {
        return { tag, style: {}, files: [], setAttribute() {}, removeAttribute() {}, load() {}, pause() {},
          remove() { nodes.splice(nodes.indexOf(this), 1); },
          requestVideoFrameCallback(callback) { frameCallback = callback; return 1; },
          cancelVideoFrameCallback() {},
          play() {
            const decodeFirstFrame = () => {
              Object.assign(this, { readyState: 4, videoWidth: 32, videoHeight: 32, webkitDecodedFrameCount: 1 });
              this.onloadeddata?.();
            };
            queueMicrotask(() => {
              if (outcome === "frame") frameCallback(0, { width: 32, height: 32, presentedFrames: 1 });
              else if (outcome === "error") this.onerror();
              else if (outcome === "hidden-frame") decodeFirstFrame();
              else {
                // A visible page must still wait for a presented frame.
                if (outcome === "visible-first-frame") decodeFirstFrame();
                for (const callback of [...timers.values()]) callback();
              }
            });
            // Chromium rejects play() for video-only media in a hidden page.
            return hiddenPage ? Promise.reject(new Error("AbortError")) : Promise.resolve();
          },
        };
      },
    },
    setTimeout(callback) { timers.set(++timerId, callback); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    URL: { createObjectURL() { return "blob:probe"; }, revokeObjectURL(url) { revoked.push(url); } },
  };
  const session = {
    async send(method, params) {
      calls.push({ method, params });
      if (method === "Runtime.evaluate") {
        vm.runInNewContext(params.expression, context);
        return { result: { objectId: "private-input" } };
      }
      if (method === "DOM.setFileInputFiles") {
        if (outcome === "disconnect") throw new Error("CDP socket closed");
        nodes.find(node => node.tag === "input").files = [{ name: "snapshot.mp4", size: 100, type: "video/mp4" }];
      }
      return {};
    },
    async evaluate(expression) {
      if (outcome === "navigation" && expression.endsWith("?.start()")) return undefined;
      return vm.runInNewContext(expression, context);
    },
  };
  if (outcome === "frame") assert.equal((await probeVideoDecode(session, "private/snapshot.mp4")).pass, true);
  else if (outcome === "hidden-frame") {
    const result = await probeVideoDecode(session, "private/snapshot.mp4");
    assert.equal(result.pass, true, "A hidden window passes on a decoded first frame");
    assert.equal(result.reason, "decoded-frame-hidden");
  } else if (outcome === "hidden-timeout") {
    await assert.rejects(probeVideoDecode(session, "private/snapshot.mp4"), /Codex 窗口在后台.*hidden-timeout/);
  } else if (outcome === "visible-first-frame") {
    await assert.rejects(probeVideoDecode(session, "private/snapshot.mp4"), /decode-timeout/);
  } else await assert.rejects(probeVideoDecode(session, "private/snapshot.mp4"), /Codex|CDP/);
  assert.equal(nodes.length, 0, `${outcome}: probe DOM must be removed`);
  assert.equal(Object.keys(context.window).length, 0);
  assert.equal(timers.size, 0);
  assert.equal(revoked.length, ["disconnect", "navigation"].includes(outcome) ? 0 : 1);
  assert.ok(calls.some(call => call.method === "Runtime.releaseObject"));
  assert.equal(calls.some(call => call.method !== "DOM.setFileInputFiles" && JSON.stringify(call).includes("private/snapshot.mp4")), false);
}

const temp = await fs.mkdtemp(path.join(os.tmpdir(), "dream-hevc-preflight-"));
try {
  const file = path.join(temp, "video.mp4");
  await fs.writeFile(file, hevc);
  await assert.rejects(validateVideoFile(file, path.join(temp, "missing-state.json")), /先启动 Codex/);
} finally { await fs.rm(temp, { recursive: true, force: true }); }
for (const platform of ["windows", "macos"]) {
  const { applyLoadedToSession, earlyPayloadFor } = await import(`../${platform}/scripts/injector.mjs`);
  assert.equal(earlyPayloadFor('"dreamskin-file:video/mp4"', "video-revision"), "void 0;",
    "Video themes must not run before the decode preflight");
  const evaluated = [];
  const session = {
    async send(method) { return method === "Runtime.evaluate" ? { result: { objectId: "input" } } : {}; },
    async evaluate(expression) {
      evaluated.push(expression);
      return expression.endsWith("?.start()") ? { pass: false, reason: "decode-error" } : undefined;
    },
  };
  await assert.rejects(applyLoadedToSession(session, {
    payload: "REPLACE_CURRENT_THEME", mediaFilePath: "video.mp4", theme: { artMetadata: { video: true } },
  }), /Codex/);
  assert.equal(evaluated.includes("REPLACE_CURRENT_THEME"), false,
    `${platform}: rejected video must not replace the current theme`);
}
const cacheRoot = await fs.mkdtemp(path.join(os.tmpdir(), "dream-decode-cache-"));
process.env.CODEX_DREAM_SKIN_VIDEO_DECODE_CACHE = path.join(cacheRoot, "video-decode-v1.json");
try {
  const { probeVideoDecodeOnce } = await import("../windows/scripts/injector.mjs");
  let starts = 0;
  let product = "Chrome/154.0.8037.98";
  let decodeResult = { pass: true, reason: "decoded-frame", width: 32, height: 18 };
  const session = {
    async send(method) {
      if (method === "Browser.getVersion") return { product, revision: "@test" };
      return method === "Runtime.evaluate" ? { result: { objectId: "input" } } : {};
    },
    async evaluate(expression) {
      if (!expression.endsWith("?.start()")) return undefined;
      starts += 1;
      return decodeResult;
    },
  };
  const snapshot = path.join(cacheRoot, `${"a".repeat(64)}.mp4`);
  assert.equal((await probeVideoDecodeOnce(session, snapshot)).reason, "decoded-frame");
  assert.deepEqual(await probeVideoDecodeOnce(session, snapshot), { pass: true, reason: "cached", width: 32, height: 18 });
  assert.equal(starts, 1, "A passed check must be reused for the same browser build and bytes");
  product = "Chrome/155.0.0.1";
  await probeVideoDecodeOnce(session, snapshot);
  assert.equal(starts, 2, "A different browser build must check again");
  decodeResult = { pass: false, reason: "decode-error" };
  const other = path.join(cacheRoot, `${"b".repeat(64)}.mp4`);
  await assert.rejects(probeVideoDecodeOnce(session, other), /Codex/);
  await assert.rejects(probeVideoDecodeOnce(session, other), /Codex/);
  assert.equal(starts, 4, "A failed check must never be remembered");
  await assert.rejects(probeVideoDecodeOnce(session, path.join(cacheRoot, "video.mp4")), /Codex/);
  assert.equal(starts, 5, "Media without a digest name is always checked");
  await fs.writeFile(process.env.CODEX_DREAM_SKIN_VIDEO_DECODE_CACHE, "{not json");
  decodeResult = { pass: true, reason: "decoded-frame", width: 32, height: 18 };
  assert.equal((await probeVideoDecodeOnce(session, snapshot)).reason, "decoded-frame",
    "An unreadable cache falls back to probing");
} finally {
  delete process.env.CODEX_DREAM_SKIN_VIDEO_DECODE_CACHE;
  await fs.rm(cacheRoot, { recursive: true, force: true });
}
console.log("PASS: HEVC structure, decoded-frame gating, hidden-window first-frame decoding, failure/timeout/navigation cleanup, disconnected rejection, and the decode result cache.");
