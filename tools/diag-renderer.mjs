#!/usr/bin/env node
/**
 * Codex Dream Skin · 渲染端取证工具（Windows，由 tools/diag-runtime.ps1 调用）
 * ================================================================
 * 通过 state.json 记录的本机 CDP 端口和 browserId，读取 Codex 页面里的皮肤状态与
 * metrics，用于确认“皮肤掉落”和“生成回答时卡顿”的根因。
 *
 * 用法（需 Node >= 22）：
 *   node diag-renderer.mjs --port 9335 --browser-id <id>                 # 快照
 *   node diag-renderer.mjs --port 9335 --browser-id <id> --sample 20     # 采样 20 秒
 *   node diag-renderer.mjs ... --measure-passes 0                        # 快照时不测部件刷新耗时
 *
 * 边界：
 *   - 只连接 127.0.0.1，且 browserId 必须与 state.json 一致，否则不连接页面；
 *   - 不采集页面文本，只返回计数、耗时和皮肤自身的状态字段；
 *   - --measure-passes 会调用皮肤自己的部件刷新（与页面每次 DOM 变化时执行的是同一个
 *     幂等过程），不改变主题或页面内容；
 *   - 采样模式会临时挂一个 longtask 观察器，采样结束即断开。
 * 输出：单个 JSON 对象，写到 stdout。
 */

import process from "node:process";

const LOOPBACK_HOST = "127.0.0.1";
const BROWSER_ID_PATTERN = /^[A-Za-z0-9._-]{1,200}$/;
const MAX_SAMPLE_SECONDS = 300;
const MAX_MEASURE_PASSES = 20;

function parseArgs(argv) {
  const options = { port: 0, browserId: "", sampleSeconds: 0, measurePasses: 5 };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    const value = argv[index + 1];
    if (name === "--port") options.port = Number(value);
    else if (name === "--browser-id") options.browserId = String(value ?? "");
    else if (name === "--sample") options.sampleSeconds = Number(value);
    else if (name === "--measure-passes") options.measurePasses = Number(value);
    else throw new Error(`Unknown argument: ${name}`);
    index += 1;
  }
  if (!Number.isInteger(options.port) || options.port < 1024 || options.port > 65535) {
    throw new Error("--port must be an integer between 1024 and 65535");
  }
  if (!BROWSER_ID_PATTERN.test(options.browserId)) throw new Error("--browser-id is missing or invalid");
  if (!Number.isFinite(options.sampleSeconds) || options.sampleSeconds < 0 ||
      options.sampleSeconds > MAX_SAMPLE_SECONDS) {
    throw new Error(`--sample must be between 0 and ${MAX_SAMPLE_SECONDS} seconds`);
  }
  if (!Number.isInteger(options.measurePasses) || options.measurePasses < 0 ||
      options.measurePasses > MAX_MEASURE_PASSES) {
    throw new Error(`--measure-passes must be an integer between 0 and ${MAX_MEASURE_PASSES}`);
  }
  return options;
}

async function fetchCdpJson(port, resource, timeoutMs = 2000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`http://${LOOPBACK_HOST}:${port}${resource}`, { signal: controller.signal });
    if (!response.ok) throw new Error(`CDP ${resource} returned HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}

function loopbackDebuggerUrl(value, port) {
  const url = new URL(String(value ?? ""));
  if (url.protocol !== "ws:" || url.hostname !== LOOPBACK_HOST || Number(url.port) !== port ||
      url.username || url.password || url.search || url.hash) {
    throw new Error("CDP returned a non-loopback debugger URL");
  }
  return url;
}

function browserIdFromVersion(version, port) {
  const url = loopbackDebuggerUrl(version?.webSocketDebuggerUrl, port);
  const match = /^\/devtools\/browser\/([^/]+)$/.exec(url.pathname);
  if (!match || !BROWSER_ID_PATTERN.test(match[1])) throw new Error("CDP browser identity is invalid");
  return match[1];
}

function isAppPageTarget(item, port) {
  if (item?.type !== "page" || typeof item.id !== "string" || !String(item.url ?? "").startsWith("app:")) {
    return false;
  }
  try {
    const url = loopbackDebuggerUrl(item.webSocketDebuggerUrl, port);
    return url.pathname === `/devtools/page/${item.id}`;
  } catch {
    return false;
  }
}

class CdpClient {
  constructor(webSocketUrl) {
    this.webSocketUrl = webSocketUrl;
    this.nextId = 1;
    this.pending = new Map();
    this.ws = null;
  }

  async open(timeoutMs = 3000) {
    this.ws = new WebSocket(this.webSocketUrl);
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("CDP WebSocket open timed out")), timeoutMs);
      this.ws.addEventListener("open", () => { clearTimeout(timeout); resolve(); }, { once: true });
      this.ws.addEventListener("error", () => {
        clearTimeout(timeout);
        reject(new Error("CDP WebSocket open failed"));
      }, { once: true });
    });
    this.ws.addEventListener("message", (event) => {
      let message;
      try { message = JSON.parse(String(event.data)); } catch { return; }
      const entry = this.pending.get(message?.id);
      if (!entry) return;
      this.pending.delete(message.id);
      clearTimeout(entry.timeout);
      if (message.error) entry.reject(new Error(`${message.error.message} (${message.error.code})`));
      else entry.resolve(message.result);
    });
    this.ws.addEventListener("close", () => {
      for (const entry of this.pending.values()) {
        clearTimeout(entry.timeout);
        entry.reject(new Error("CDP WebSocket closed"));
      }
      this.pending.clear();
    });
    return this;
  }

  send(method, params, timeoutMs) {
    const id = this.nextId;
    this.nextId += 1;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timeout });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression, timeoutMs) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    }, timeoutMs);
    if (result?.exceptionDetails) {
      const detail = result.exceptionDetails.exception?.description ?? result.exceptionDetails.text;
      throw new Error(`Renderer evaluation failed: ${detail}`);
    }
    return result?.result?.value;
  }

  close() {
    try { this.ws?.close(); } catch {}
  }
}

// 页面侧表达式只读取皮肤自己的状态字段与计数，不读取任何页面文本。
function snapshotExpression(measurePasses) {
  return `(() => {
    const state = window.__CODEX_DREAM_SKIN_STATE__;
    const root = document.documentElement;
    const result = {
      origin: location.protocol + "//" + location.host + location.pathname,
      readyState: document.readyState,
      visibility: document.visibilityState,
      domNodes: document.getElementsByTagName("*").length,
      disabled: Boolean(window.__CODEX_DREAM_SKIN_DISABLED__),
      rootActive: root?.getAttribute("data-dream-skin") === "active",
      earlyGeneration: window.__CODEX_DREAM_SKIN_EARLY_GENERATION__ ?? null,
      earlyApplied: window.__CODEX_DREAM_SKIN_EARLY_APPLIED__ ?? null,
      installed: Boolean(state),
    };
    if (!state) return result;
    let sheetAttached = false;
    try {
      sheetAttached = state.styleMode === "adopted"
        ? [...document.adoptedStyleSheets].includes(state.styleSheet)
        : Boolean(state.styleNode && document.getElementById("codex-dream-skin-style") === state.styleNode);
    } catch {}
    const video = state.videoLayer;
    Object.assign(result, {
      version: state.version ?? null,
      themeId: state.themeId ?? null,
      revision: state.revision ?? null,
      styleMode: state.styleMode ?? null,
      sheetAttached,
      mediaType: state.mediaType ?? null,
      imageReady: Boolean(state.imageReady),
      imageError: state.imageError ? String(state.imageError) : null,
      videoError: state.videoError ? String(state.videoError) : null,
      videoReady: Boolean(video && video.readyState >= 1 && video.videoWidth > 0),
      videoPaused: video ? Boolean(video.paused) : null,
      scope: state.scope ? {
        state: state.scope.state,
        level: state.scope.level,
        missingL1: state.scope.missingL1 ?? [],
      } : null,
      partNodes: document.querySelectorAll("[data-ds-part]").length,
      surfaceNodes: document.querySelectorAll("[data-ds-surface]").length,
      metrics: { ...(state.metrics ?? {}) },
    });
    const runs = ${measurePasses};
    if (runs > 0 && typeof state.ensure === "function") {
      const durations = [];
      for (let index = 0; index < runs; index += 1) {
        const startedAt = performance.now();
        state.ensure({ root: false, scope: true, parts: true });
        durations.push(performance.now() - startedAt);
      }
      result.partPassMs = {
        runs,
        avg: Number((durations.reduce((sum, value) => sum + value, 0) / runs).toFixed(3)),
        max: Number(Math.max(...durations).toFixed(3)),
      };
    }
    return result;
  })()`;
}

function sampleExpression(sampleMs) {
  return `(async () => {
    const state = window.__CODEX_DREAM_SKIN_STATE__;
    const before = state ? { ...(state.metrics ?? {}) } : null;
    const longTasks = [];
    let observer = null;
    try {
      observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) longTasks.push(entry.duration);
      });
      observer.observe({ type: "longtask", buffered: false });
    } catch {
      observer = null;
    }
    const domBefore = document.getElementsByTagName("*").length;
    const visibilityBefore = document.visibilityState;
    const startedAt = performance.now();
    await new Promise((resolve) => setTimeout(resolve, ${sampleMs}));
    observer?.disconnect();
    const seconds = (performance.now() - startedAt) / 1000;
    const current = window.__CODEX_DREAM_SKIN_STATE__;
    const replaced = current !== state;
    const after = current && !replaced ? { ...(current.metrics ?? {}) } : null;
    const perSecond = {};
    const deltas = {};
    if (before && after) {
      for (const [key, value] of Object.entries(after)) {
        if (typeof value !== "number" || typeof before[key] !== "number" || key === "firstEnsureMs") continue;
        deltas[key] = value - before[key];
        perSecond[key] = Number(((value - before[key]) / seconds).toFixed(2));
      }
    }
    return {
      seconds: Number(seconds.toFixed(2)),
      installed: Boolean(state),
      replaced,
      visibilityBefore,
      visibilityAfter: document.visibilityState,
      domBefore,
      domAfter: document.getElementsByTagName("*").length,
      deltas,
      perSecond,
      longTaskObserver: Boolean(observer),
      longTasks: {
        count: longTasks.length,
        totalMs: Number(longTasks.reduce((sum, value) => sum + value, 0).toFixed(1)),
        maxMs: Number((longTasks.length ? Math.max(...longTasks) : 0).toFixed(1)),
      },
    };
  })()`;
}

async function main() {
  if (typeof WebSocket !== "function") throw new Error(`Node.js 22+ is required (current ${process.version})`);
  const options = parseArgs(process.argv.slice(2));
  const report = {
    tool: "diag-renderer",
    mode: options.sampleSeconds > 0 ? "sample" : "snapshot",
    port: options.port,
    expectedBrowserId: options.browserId,
    actualBrowserId: null,
    identity: "unknown",
    targets: [],
  };

  try {
    report.actualBrowserId = browserIdFromVersion(await fetchCdpJson(options.port, "/json/version"), options.port);
  } catch (error) {
    report.identity = "unreachable";
    report.error = error.message;
    return report;
  }
  if (report.actualBrowserId !== options.browserId) {
    // 端口上已是另一个浏览器实例（例如 Codex 重启过），不连接其页面。
    report.identity = "mismatch";
    return report;
  }
  report.identity = "verified";

  const list = await fetchCdpJson(options.port, "/json/list");
  const targets = Array.isArray(list) ? list.filter((item) => isAppPageTarget(item, options.port)) : [];
  const sampleMs = Math.round(options.sampleSeconds * 1000);
  const expression = sampleMs > 0 ? sampleExpression(sampleMs) : snapshotExpression(options.measurePasses);
  const timeoutMs = sampleMs + 10000;

  // 多个页面并行采样，保证采样窗口一致。
  report.targets = await Promise.all(targets.map(async (target) => {
    const entry = { id: target.id, page: String(target.url).split(/[?#]/)[0] };
    let client;
    try {
      client = await new CdpClient(target.webSocketDebuggerUrl).open();
      entry.result = await client.evaluate(expression, timeoutMs);
    } catch (error) {
      entry.error = error.message;
    } finally {
      client?.close();
    }
    return entry;
  }));
  return report;
}

try {
  process.stdout.write(`${JSON.stringify(await main())}\n`);
} catch (error) {
  process.stdout.write(`${JSON.stringify({ tool: "diag-renderer", fatal: error.message })}\n`);
  process.exitCode = 1;
}
