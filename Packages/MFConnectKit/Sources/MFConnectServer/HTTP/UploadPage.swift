// 內嵌上傳頁：單一 HTML，CSS / JS 全部內嵌，不載入任何外部資源（CSP 也禁止）。
// 所有動態內容一律用 textContent 寫入，避免 XSS。

enum UploadPage {
    static let html = #"""
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>MFConnect 列印</title>
<style>
:root {
  --bg: #f4f5f7; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: #d9dbe0;
  --accent: #0a66d8; --accent-text: #ffffff; --ok: #1a7f37; --warn: #9a6700; --bad: #c62828;
  --radius: 14px;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #111214; --card: #1c1d20; --text: #f2f2f4; --muted: #a1a1a6; --line: #34363b;
          --accent: #3d8bfd; --ok: #4ac26b; --warn: #d4a72c; --bad: #ff6b6b; }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.5 -apple-system, BlinkMacSystemFont, "PingFang TC", "Noto Sans TC", "Microsoft JhengHei", sans-serif; }
main { max-width: 640px; margin: 0 auto; padding: 16px 16px calc(120px + env(safe-area-inset-bottom)); }
header { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 8px 0 16px; }
h1 { font-size: 22px; margin: 0; }
.sub { color: var(--muted); font-size: 14px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: var(--radius); padding: 16px; margin-bottom: 12px; }
label { display: block; font-size: 14px; color: var(--muted); margin-bottom: 6px; }
input[type=password], input[type=text], input[type=number], select {
  width: 100%; font-size: 16px; padding: 12px; border-radius: 10px; border: 1px solid var(--line);
  background: var(--bg); color: var(--text); min-height: 48px; }
button { font-size: 16px; min-height: 48px; padding: 0 18px; border-radius: 12px; border: 0; cursor: pointer;
  background: var(--accent); color: var(--accent-text); font-weight: 600; }
button.secondary { background: transparent; color: var(--accent); border: 1px solid var(--line); font-weight: 500; }
button.link { background: transparent; color: var(--muted); min-height: 40px; padding: 0 8px; font-weight: 500; }
button:disabled { opacity: .5; cursor: default; }
.row { display: flex; gap: 10px; }
.row > * { flex: 1; }
.drop { border: 2px dashed var(--line); border-radius: var(--radius); padding: 28px 16px; text-align: center;
  background: var(--card); cursor: pointer; transition: border-color .15s, background .15s; }
.drop.over { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 8%, var(--card)); }
.drop strong { display: block; font-size: 18px; margin-bottom: 4px; }
.file-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 8px; margin-bottom: 10px; }
.file-name { font-weight: 600; word-break: break-all; }
.opts { display: grid; grid-template-columns: 1fr 1.6fr 1fr; gap: 8px; }
@media (max-width: 420px) { .opts { grid-template-columns: 1fr 1fr; } .opts .wide { grid-column: span 2; } }
progress { width: 100%; height: 8px; margin-top: 12px; accent-color: var(--accent); }
.status { margin-top: 8px; font-size: 15px; }
.status.ok { color: var(--ok); } .status.warn { color: var(--warn); } .status.bad { color: var(--bad); }
.notice { padding: 12px 14px; border-radius: 12px; font-size: 14px; margin-bottom: 12px; display: none; }
.notice.show { display: block; }
.notice.bad { background: color-mix(in srgb, var(--bad) 12%, var(--card)); color: var(--bad); }
.notice.info { background: color-mix(in srgb, var(--accent) 10%, var(--card)); }
.bar { position: fixed; left: 0; right: 0; bottom: 0; padding: 12px 16px calc(12px + env(safe-area-inset-bottom));
  background: color-mix(in srgb, var(--bg) 92%, transparent); backdrop-filter: blur(10px); border-top: 1px solid var(--line); }
.bar .inner { max-width: 640px; margin: 0 auto; display: flex; gap: 10px; }
.bar button { flex: 1; }
.hidden { display: none !important; }
footer { color: var(--muted); font-size: 12px; text-align: center; margin-top: 24px; }
</style>
</head>
<body>
<main>
  <header>
    <div>
      <h1>MFConnect 列印</h1>
      <div class="sub" id="serverLine">家用列印伺服器</div>
    </div>
    <button class="link hidden" id="logoutBtn" type="button">登出</button>
  </header>

  <div class="notice bad" id="errorBox" role="alert"></div>
  <div class="notice info" id="infoBox"></div>

  <section id="loginView" class="card hidden">
    <form id="loginForm" autocomplete="off">
      <label for="tokenInput">請輸入 token（向列印伺服器的管理者索取）</label>
      <input type="password" id="tokenInput" autocomplete="off" autocapitalize="off" spellcheck="false" required>
      <div style="height:12px"></div>
      <button type="submit" id="loginBtn" style="width:100%">登入</button>
    </form>
    <p class="sub">token 只會存在這個瀏覽器（localStorage），按「登出」即可清除。</p>
  </section>

  <section id="uploadView" class="hidden">
    <div class="drop" id="dropZone" tabindex="0" role="button" aria-label="選擇檔案">
      <strong>點這裡選擇檔案</strong>
      <span class="sub" id="dropHint">或把檔案拖放到這裡・支援 PDF、JPEG、PNG、HEIC</span>
      <input type="file" id="fileInput" multiple class="hidden"
             accept=".pdf,.jpg,.jpeg,.png,.heic,application/pdf,image/jpeg,image/png,image/heic">
    </div>
    <div style="height:12px"></div>
    <div id="fileList"></div>
  </section>

  <footer>僅限家中區網使用・連線未加密（HTTP）</footer>
</main>

<div class="bar hidden" id="actionBar">
  <div class="inner">
    <button class="secondary" type="button" id="clearBtn">清除已完成</button>
    <button type="button" id="sendAllBtn">傳送</button>
  </div>
</div>

<template id="fileTemplate">
  <div class="card file">
    <div class="file-head">
      <div>
        <div class="file-name"></div>
        <div class="sub file-meta"></div>
      </div>
      <button class="link remove" type="button" aria-label="移除">移除</button>
    </div>
    <div class="opts">
      <div><label>份數</label><input type="number" class="copies" min="1" max="99" value="1" inputmode="numeric"></div>
      <div class="wide"><label>雙面</label>
        <select class="duplex">
          <option value="none">單面</option>
          <option value="long">雙面（長邊翻頁）</option>
          <option value="short">雙面（短邊翻頁）</option>
        </select></div>
      <div><label>色彩</label>
        <select class="color">
          <option value="color">彩色</option>
          <option value="mono">黑白</option>
        </select></div>
    </div>
    <progress class="hidden" max="100" value="0"></progress>
    <div class="status"></div>
  </div>
</template>

<script>
"use strict";
(function () {
  const TOKEN_KEY = "mfconnect.token";
  const DEFAULT_MAX = 50 * 1024 * 1024;
  const STATUS_TEXT = { pendingApproval: "等待核准", queued: "排隊中", printing: "列印中", done: "完成", failed: "失敗", rejected: "已拒絕" };
  const TERMINAL = new Set(["done", "failed", "rejected"]);
  const $ = (id) => document.getElementById(id);

  let token = null;
  let info = null;
  const items = [];

  function storageGet() { try { return localStorage.getItem(TOKEN_KEY); } catch (e) { return null; } }
  function storageSet(v) { try { localStorage.setItem(TOKEN_KEY, v); } catch (e) {} }
  function storageClear() { try { localStorage.removeItem(TOKEN_KEY); } catch (e) {} }

  function showError(msg) { const b = $("errorBox"); b.textContent = msg || ""; b.classList.toggle("show", !!msg); }
  function showInfo(msg) { const b = $("infoBox"); b.textContent = msg || ""; b.classList.toggle("show", !!msg); }

  function formatSize(n) {
    if (n < 1024) return n + " B";
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }

  function errorMessage(status, body) {
    let msg = null;
    try { msg = JSON.parse(body).message; } catch (e) {}
    switch (status) {
      case 401: return "token 錯誤，請重新登入";
      case 413: return msg || "檔案太大";
      case 415: return "格式不支援（只接受 PDF、JPEG、PNG、HEIC）";
      case 429: return msg || "嘗試次數太多，請稍後再試";
      case 503: return msg || "列印佇列已滿，請稍後再試";
      case 0: return "連線中斷（可能檔案太大或網路不穩）";
      default: return msg || ("伺服器錯誤（" + status + "）");
    }
  }

  function api(method, path) {
    return new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open(method, path);
      xhr.setRequestHeader("Authorization", "Bearer " + token);
      xhr.timeout = 15000;
      xhr.onload = () => resolve({ status: xhr.status, body: xhr.responseText });
      xhr.onerror = xhr.ontimeout = () => resolve({ status: 0, body: "" });
      xhr.send();
    });
  }

  // ---------- 登入 ----------
  async function login(candidate, silent) {
    token = candidate;
    $("loginBtn").disabled = true;
    const res = await api("GET", "/api/info");
    $("loginBtn").disabled = false;
    if (res.status === 200) {
      info = JSON.parse(res.body);
      storageSet(token);
      showError("");
      enterUploadView();
      return;
    }
    token = null;
    if (res.status === 401) storageClear();
    if (!silent || res.status !== 401) showError(errorMessage(res.status, res.body));
    enterLoginView();
  }

  function enterLoginView() {
    $("loginView").classList.remove("hidden");
    $("uploadView").classList.add("hidden");
    $("actionBar").classList.add("hidden");
    $("logoutBtn").classList.add("hidden");
    $("serverLine").textContent = "家用列印伺服器";
    showInfo("");
  }

  function enterUploadView() {
    $("loginView").classList.add("hidden");
    $("uploadView").classList.remove("hidden");
    $("actionBar").classList.remove("hidden");
    $("logoutBtn").classList.remove("hidden");
    const max = info.maxUploadBytes || DEFAULT_MAX;
    $("serverLine").textContent = info.serverName + "・單檔上限 " + formatSize(max);
    showInfo(info.requiresApproval ? "此伺服器需要管理者核准後才會列印。" : "");
    updateButtons();
  }

  $("loginForm").addEventListener("submit", (e) => {
    e.preventDefault();
    const v = $("tokenInput").value.trim();
    if (v) login(v, false);
  });

  $("logoutBtn").addEventListener("click", () => {
    storageClear();
    token = null; info = null;
    $("tokenInput").value = "";
    enterLoginView();
  });

  // ---------- 選擇檔案 ----------
  const dropZone = $("dropZone");
  const fileInput = $("fileInput");
  dropZone.addEventListener("click", () => fileInput.click());
  dropZone.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); fileInput.click(); } });
  fileInput.addEventListener("change", () => { addFiles(fileInput.files); fileInput.value = ""; });
  ["dragenter", "dragover"].forEach((t) => dropZone.addEventListener(t, (e) => { e.preventDefault(); dropZone.classList.add("over"); }));
  ["dragleave", "drop"].forEach((t) => dropZone.addEventListener(t, (e) => { e.preventDefault(); dropZone.classList.remove("over"); }));
  dropZone.addEventListener("drop", (e) => { if (e.dataTransfer) addFiles(e.dataTransfer.files); });
  // 避免拖放到頁面其他地方時瀏覽器直接開啟檔案
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => e.preventDefault());

  // 以檔頭判斷格式（只是前端預檢，以伺服器判斷為準）
  function sniff(file) {
    return new Promise((resolve) => {
      const reader = new FileReader();
      reader.onload = () => {
        const b = new Uint8Array(reader.result);
        const s = (i, arr) => arr.every((v, k) => b[i + k] === v);
        if (s(0, [0x25, 0x50, 0x44, 0x46, 0x2d])) return resolve("PDF");
        if (s(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return resolve("PNG");
        if (s(0, [0xff, 0xd8, 0xff])) return resolve("JPEG");
        if (s(4, [0x66, 0x74, 0x79, 0x70])) {
          const brand = String.fromCharCode(b[8], b[9], b[10], b[11]);
          if (["heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1"].includes(brand)) return resolve("HEIC");
        }
        resolve(null);
      };
      reader.onerror = () => resolve(null);
      reader.readAsArrayBuffer(file.slice(0, 16));
    });
  }

  async function addFiles(fileList) {
    if (!fileList) return;
    const max = (info && info.maxUploadBytes) || DEFAULT_MAX;
    for (const file of Array.from(fileList)) {
      const item = createItem(file);
      if (file.size === 0) { setStatus(item, "檔案是空的", "bad"); item.blocked = true; continue; }
      if (file.size > max) { setStatus(item, "檔案太大（上限 " + formatSize(max) + "）", "bad"); item.blocked = true; continue; }
      const kind = await sniff(file);
      if (!kind) { setStatus(item, "格式不支援（只接受 PDF、JPEG、PNG、HEIC）", "bad"); item.blocked = true; continue; }
      item.el.querySelector(".file-meta").textContent = kind + "・" + formatSize(file.size);
      setStatus(item, "準備傳送", "");
    }
    updateButtons();
  }

  function createItem(file) {
    const el = document.getElementById("fileTemplate").content.firstElementChild.cloneNode(true);
    el.querySelector(".file-name").textContent = file.name;
    el.querySelector(".file-meta").textContent = formatSize(file.size);
    const item = { file, el, state: "ready", blocked: false, jobId: null, timer: null };
    el.querySelector(".remove").addEventListener("click", () => {
      if (item.state === "uploading") return;
      if (item.timer) clearTimeout(item.timer);
      el.remove();
      items.splice(items.indexOf(item), 1);
      updateButtons();
    });
    $("fileList").appendChild(el);
    items.push(item);
    return item;
  }

  function setStatus(item, text, tone) {
    const s = item.el.querySelector(".status");
    s.textContent = text;
    s.className = "status" + (tone ? " " + tone : "");
  }

  function readOptions(item) {
    let copies = parseInt(item.el.querySelector(".copies").value, 10);
    if (!(copies >= 1 && copies <= 99)) copies = 1;
    item.el.querySelector(".copies").value = copies;
    return { copies, duplex: item.el.querySelector(".duplex").value, color: item.el.querySelector(".color").value };
  }

  function lockOptions(item, locked) {
    item.el.querySelectorAll("input, select").forEach((x) => { x.disabled = locked; });
  }

  function updateButtons() {
    const pending = items.filter((i) => i.state === "ready" && !i.blocked).length;
    const busy = items.some((i) => i.state === "uploading");
    $("sendAllBtn").disabled = pending === 0 || busy;
    $("sendAllBtn").textContent = pending > 0 ? "傳送 " + pending + " 個檔案" : "傳送";
    $("clearBtn").disabled = !items.some((i) => i.state === "finished" || i.blocked);
  }

  $("clearBtn").addEventListener("click", () => {
    for (const item of items.slice()) {
      if (item.state === "finished" || item.blocked) {
        if (item.timer) clearTimeout(item.timer);
        item.el.remove();
        items.splice(items.indexOf(item), 1);
      }
    }
    updateButtons();
  });

  // ---------- 上傳 ----------
  $("sendAllBtn").addEventListener("click", async () => {
    for (const item of items.filter((i) => i.state === "ready" && !i.blocked)) {
      await upload(item);
      if (!token) break; // 401 之後停止
    }
    updateButtons();
  });

  function upload(item) {
    return new Promise((resolve) => {
      const opts = readOptions(item);
      item.state = "uploading";
      lockOptions(item, true);
      updateButtons();
      const bar = item.el.querySelector("progress");
      bar.classList.remove("hidden");
      bar.value = 0;
      setStatus(item, "上傳中…", "");

      const xhr = new XMLHttpRequest();
      xhr.open("POST", "/api/jobs");
      xhr.setRequestHeader("Authorization", "Bearer " + token);
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      xhr.setRequestHeader("X-Filename", encodeURIComponent(item.file.name));
      xhr.setRequestHeader("X-Copies", String(opts.copies));
      xhr.setRequestHeader("X-Duplex", opts.duplex);
      xhr.setRequestHeader("X-Color", opts.color);
      xhr.setRequestHeader("X-Client", "網頁上傳");
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) {
          bar.value = Math.round((e.loaded / e.total) * 100);
          setStatus(item, "上傳中… " + bar.value + "%", "");
        }
      };
      xhr.onload = () => {
        if (xhr.status === 201) {
          bar.value = 100;
          const res = JSON.parse(xhr.responseText);
          item.jobId = res.id;
          item.state = "polling";
          showStatus(item, res.status, null);
          poll(item);
        } else {
          failUpload(item, xhr.status, xhr.responseText);
        }
        resolve();
      };
      xhr.onerror = () => { failUpload(item, 0, ""); resolve(); };
      xhr.send(item.file);
    });
  }

  function failUpload(item, status, body) {
    item.el.querySelector("progress").classList.add("hidden");
    setStatus(item, "上傳失敗：" + errorMessage(status, body), "bad");
    if (status === 401) {
      item.state = "ready";
      lockOptions(item, false);
      storageClear();
      token = null;
      showError("token 錯誤或已失效，請重新登入");
      enterLoginView();
    } else if (status === 429 || status === 503 || status === 0) {
      item.state = "ready"; // 可以稍後重試
      lockOptions(item, false);
    } else {
      item.state = "finished";
    }
    updateButtons();
  }

  function showStatus(item, status, message) {
    const text = STATUS_TEXT[status] || status;
    const tone = status === "done" ? "ok" : (status === "failed" || status === "rejected") ? "bad" : "warn";
    setStatus(item, text + (message ? "：" + message : ""), tone);
    if (TERMINAL.has(status)) {
      item.state = "finished";
      item.el.querySelector("progress").classList.add("hidden");
      updateButtons();
    }
  }

  async function poll(item) {
    if (!token || item.state !== "polling") return;
    const res = await api("GET", "/api/jobs/" + encodeURIComponent(item.jobId));
    if (res.status === 200) {
      const job = JSON.parse(res.body);
      showStatus(item, job.status, job.message);
      if (TERMINAL.has(job.status)) return;
    } else if (res.status === 401) {
      setStatus(item, "無法查詢狀態：token 已失效", "bad");
      return;
    } else if (res.status === 404) {
      setStatus(item, "工作紀錄已被移除", "bad");
      return;
    }
    item.timer = setTimeout(() => poll(item), 2000);
  }

  // ---------- 啟動 ----------
  // 支援 QR code 帶入 token：http://host:port/#token=xxxx（片段不會送到伺服器）
  const m = location.hash.match(/token=([A-Za-z0-9_\-]+)/);
  if (m) {
    history.replaceState(null, "", location.pathname);
    login(m[1], false);
  } else {
    const saved = storageGet();
    if (saved) login(saved, true); else enterLoginView();
  }
})();
</script>
</body>
</html>
"""#
}
