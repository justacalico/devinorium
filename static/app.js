/* Devinorium frontend — vanilla JS SPA. No build step.
   Talks to the JSON API + multipart endpoints. */

"use strict";

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const state = {
  user: null,
  threads: [],
  activeThreadId: null,
  groups: [],
  models: [],
  pendingAttachments: [],
  filesPath: [],
};

/* ---------- HTTP helpers ---------- */

async function api(method, path, opts = {}) {
  const init = { method, headers: opts.headers || {}, credentials: "same-origin" };
  if (opts.body !== undefined && !(opts.body instanceof FormData)) {
    init.headers["content-type"] = "application/json";
    init.body = typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body);
  } else if (opts.body instanceof FormData) {
    init.body = opts.body;
  }
  const res = await fetch(path, init);
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) {
    const msg = (data && data.error) || res.statusText || "request failed";
    const err = new Error(msg);
    err.status = res.status;
    err.data = data;
    throw err;
  }
  return data;
}

function show(viewId) {
  $$(".view").forEach((v) => v.classList.add("hidden"));
  $("#" + viewId).classList.remove("hidden");
}

function showError(elId, msg) {
  const el = $("#" + elId);
  el.textContent = msg;
  el.classList.remove("hidden");
}

/* ---------- Custom dialogs (replace browser confirm/prompt) ---------- */

function customConfirm(title, message, okLabel = "Delete") {
  return new Promise((resolve) => {
    const dlg = $("#confirm-dialog");
    $("#confirm-title").textContent = title;
    $("#confirm-message").textContent = message;
    const okBtn = $("#confirm-ok");
    const cancelBtn = $("#confirm-cancel");
    okBtn.textContent = okLabel;
    dlg.classList.remove("hidden");

    function cleanup() {
      dlg.classList.add("hidden");
      okBtn.removeEventListener("click", onOk);
      cancelBtn.removeEventListener("click", onCancel);
      dlg.removeEventListener("click", onScrim);
    }
    function onOk() { cleanup(); resolve(true); }
    function onCancel() { cleanup(); resolve(false); }
    function onScrim(e) { if (e.target === dlg) onCancel(); }
    okBtn.addEventListener("click", onOk);
    cancelBtn.addEventListener("click", onCancel);
    dlg.addEventListener("click", onScrim);
  });
}

function customPrompt(title, label, defaultValue = "") {
  return new Promise((resolve) => {
    const dlg = $("#prompt-dialog");
    $("#prompt-title").textContent = title;
    $("#prompt-label").textContent = label;
    const input = $("#prompt-input");
    input.value = defaultValue;
    const okBtn = $("#prompt-ok");
    const cancelBtn = $("#prompt-cancel");
    dlg.classList.remove("hidden");
    input.focus();
    input.select();

    function cleanup() {
      dlg.classList.add("hidden");
      okBtn.removeEventListener("click", onOk);
      cancelBtn.removeEventListener("click", onCancel);
      input.removeEventListener("keydown", onKey);
      dlg.removeEventListener("click", onScrim);
    }
    function onOk() { cleanup(); resolve(input.value); }
    function onCancel() { cleanup(); resolve(null); }
    function onKey(e) {
      if (e.key === "Enter") { e.preventDefault(); onOk(); }
      if (e.key === "Escape") { e.preventDefault(); onCancel(); }
    }
    function onScrim(e) { if (e.target === dlg) onCancel(); }
    okBtn.addEventListener("click", onOk);
    cancelBtn.addEventListener("click", onCancel);
    input.addEventListener("keydown", onKey);
    dlg.addEventListener("click", onScrim);
  });
}

/* ---------- Auth ---------- */

async function checkSession() {
  try {
    const me = await api("GET", "/api/auth/me");
    state.user = me;
    return true;
  } catch {
    return false;
  }
}

async function doLogin(e) {
  e.preventDefault();
  $("#login-error").classList.add("hidden");
  const form = e.target;
  const body = {
    username: form.username.value.trim(),
    password: form.password.value,
  };
  if (form.totp && form.totp.value.trim()) body.totp = form.totp.value.trim();
  try {
    const res = await api("POST", "/api/auth/login", { body });
    if (res.totp_required) {
      $("#totp-field").classList.remove("hidden");
      form.totp?.focus();
      showError("login-error", "Enter your 6-digit TOTP code.");
      return;
    }
    await enterApp();
  } catch (err) {
    showError("login-error", err.message);
  }
}

async function doRegister(e) {
  e.preventDefault();
  $("#register-error").classList.add("hidden");
  const form = e.target;
  try {
    await api("POST", "/api/auth/register", {
      body: {
        invite: form.invite.value.trim(),
        username: form.username.value.trim(),
        password: form.password.value,
      },
    });
    // Auto-login after register.
    const loginRes = await api("POST", "/api/auth/login", {
      body: { username: form.username.value.trim(), password: form.password.value },
    });
    if (loginRes.totp_required) throw new Error("Unexpected TOTP on new account");
    await enterApp();
  } catch (err) {
    showError("register-error", err.message);
  }
}

async function doLogout() {
  try { await api("POST", "/api/auth/logout"); } catch {}
  state.user = null;
  show("login-view");
}

async function enterApp() {
  const ok = await checkSession();
  if (!ok) { show("login-view"); return; }
  show("app-view");
  $("#user-name").textContent = state.user.username;
  $("#user-avatar").textContent = state.user.username.charAt(0).toUpperCase();
  await loadModels();
  await loadThreads();
}

/* ---------- Thread groups ---------- */

async function loadGroups() {
  try {
    state.groups = await api("GET", "/api/thread-groups");
  } catch (err) {
    console.error("loadGroups", err);
  }
}

async function createGroup(threadIds, name) {
  const body = { thread_ids: threadIds };
  if (name) body.name = name;
  return await api("POST", "/api/thread-groups", { body });
}

async function renameGroup(id, name) {
  return await api("PATCH", `/api/thread-groups/${id}`, { body: { name } });
}

async function deleteGroup(id) {
  return await api("DELETE", `/api/thread-groups/${id}`);
}

async function moveThreadToGroup(threadId, groupId) {
  return await api("PATCH", `/api/threads/${threadId}`, {
    body: { thread_group_id: groupId },
  });
}

/* ---------- Models ---------- */

async function loadModels() {
  try {
    state.models = await api("GET", "/api/models");
    const sel = $("#model-select");
    sel.innerHTML = state.models.map((m) => `<option value="${m.id}">${escapeHtml(m.label)}</option>`).join("");
  } catch (err) {
    console.error("loadModels", err);
  }
}

/* ---------- Threads ---------- */

async function loadThreads() {
  try {
    const [threads, groups] = await Promise.all([
      api("GET", "/api/threads"),
      api("GET", "/api/thread-groups"),
    ]);
    state.threads = threads;
    state.groups = groups;
    renderThreadList();
  } catch (err) {
    console.error("loadThreads", err);
  }
}

function renderThreadList() {
  const list = $("#thread-list");
  const ungrouped = state.threads.filter((t) => !t.thread_group_id);
  const grouped = state.groups.map((g) => ({
    ...g,
    threads: state.threads.filter((t) => t.thread_group_id === g.id),
  })).filter((g) => g.threads.length > 0);

  if (!state.threads.length) {
    list.innerHTML = '<div class="m3-label-medium" style="padding:16px;text-align:center">No threads yet</div>';
    return;
  }

  let html = "";

  // Ungrouped threads section.
  if (ungrouped.length) {
    html += '<div class="thread-group-section" data-drop-ungrouped>';
    html += '<div class="thread-group-label m3-label-medium">Ungrouped</div>';
    html += ungrouped.map((t) => threadItemHtml(t)).join("");
    html += '</div>';
  }

  // Grouped threads.
  for (const g of grouped) {
    html += `<div class="thread-group-section" data-group-id="${g.id}">`;
    html += `<div class="thread-group-header" data-group-id="${g.id}">`;
    html += `<svg class="icon-sm thread-group-chevron"><use href="#icon-menu"/></svg>`;
    html += `<span class="thread-group-name">${escapeHtml(g.name)}</span>`;
    html += `<span class="thread-group-del" data-group-del="${g.id}" title="Delete group (Shift+click to skip confirmation)"><svg class="icon-xs"><use href="#icon-trash"/></svg></span>`;
    html += `</div>`;
    html += `<div class="thread-group-items" data-group-id="${g.id}">`;
    html += g.threads.map((t) => threadItemHtml(t)).join("");
    html += `</div>`;
    html += `</div>`;
  }

  list.innerHTML = html;
  wireThreadItems();
  wireDragAndDrop();
  wireGroupActions();
}

function threadItemHtml(t) {
  return `
    <div class="thread-item ${t.id === state.activeThreadId ? "active" : ""}" data-id="${t.id}" draggable="true">
      <svg class="icon-sm"><use href="#icon-chat"/></svg>
      <span class="thread-title-text">${escapeHtml(t.title)}</span>
      <span class="thread-del" data-del="${t.id}" title="Delete (Shift+click to skip confirmation)"><svg class="icon-sm"><use href="#icon-trash"/></svg></span>
    </div>`;
}

function wireThreadItems() {
  $$(".thread-item").forEach((el) => {
    el.addEventListener("click", (e) => {
      const delBtn = e.target.closest(".thread-del");
      if (delBtn) {
        e.stopPropagation();
        deleteThread(delBtn.dataset.del, e.shiftKey);
      } else {
        openThread(el.dataset.id);
      }
    });
    // Drag start.
    el.addEventListener("dragstart", (e) => {
      e.dataTransfer.setData("text/plain", el.dataset.id);
      el.classList.add("dragging");
    });
    el.addEventListener("dragend", () => {
      el.classList.remove("dragging");
    });
  });
}

function wireDragAndDrop() {
  // Drop on another thread item → create or join a group.
  $$(".thread-item").forEach((el) => {
    el.addEventListener("dragover", (e) => {
      e.preventDefault();
      el.classList.add("drag-over");
    });
    el.addEventListener("dragleave", () => {
      el.classList.remove("drag-over");
    });
    el.addEventListener("drop", async (e) => {
      e.preventDefault();
      e.stopPropagation();
      el.classList.remove("drag-over");
      const draggedId = e.dataTransfer.getData("text/plain");
      const targetId = el.dataset.id;
      if (draggedId === targetId) return;

      // Find the group of the target thread.
      const targetThread = state.threads.find((t) => t.id === targetId);
      const draggedThread = state.threads.find((t) => t.id === draggedId);

      if (targetThread.thread_group_id) {
        // Target is in a group → add dragged thread to same group.
        await moveThreadToGroup(draggedId, targetThread.thread_group_id);
      } else if (draggedThread.thread_group_id) {
        // Dragged is in a group, target is not → move target into dragged's group.
        await moveThreadToGroup(targetId, draggedThread.thread_group_id);
      } else {
        // Neither is grouped → create a new group with both.
        await createGroup([draggedId, targetId]);
      }
      await loadThreads();
    });
  });

  // Drop on "Ungrouped" section → remove from group.
  $$("[data-drop-ungrouped]").forEach((el) => {
    el.addEventListener("dragover", (e) => {
      e.preventDefault();
      el.classList.add("drag-over");
    });
    el.addEventListener("dragleave", () => {
      el.classList.remove("drag-over");
    });
    el.addEventListener("drop", async (e) => {
      e.preventDefault();
      el.classList.remove("drag-over");
      const draggedId = e.dataTransfer.getData("text/plain");
      await moveThreadToGroup(draggedId, null);
      await loadThreads();
    });
  });

  // Drop on a group header → add to that group.
  $$(".thread-group-header").forEach((el) => {
    el.addEventListener("dragover", (e) => {
      e.preventDefault();
      el.classList.add("drag-over");
    });
    el.addEventListener("dragleave", () => {
      el.classList.remove("drag-over");
    });
    el.addEventListener("drop", async (e) => {
      e.preventDefault();
      e.stopPropagation();
      el.classList.remove("drag-over");
      const draggedId = e.dataTransfer.getData("text/plain");
      const groupId = Number(el.dataset.groupId);
      await moveThreadToGroup(draggedId, groupId);
      await loadThreads();
    });
  });
}

function wireGroupActions() {
  // Group header click → rename or delete.
  $$(".thread-group-header").forEach((el) => {
    el.addEventListener("click", async (e) => {
      const delBtn = e.target.closest(".thread-group-del");
      if (delBtn) {
        e.stopPropagation();
        const gid = Number(delBtn.dataset.groupDel);
        if (e.shiftKey || await customConfirm("Delete group", "Delete this group? Threads will become ungrouped.")) {
          deleteGroup(gid).then(() => loadThreads());
        }
        return;
      }
      // Click on group name → rename.
      const nameSpan = e.target.closest(".thread-group-name");
      if (nameSpan) {
        const gid = Number(el.dataset.groupId);
        const newName = await customPrompt("Rename group", "Group name", nameSpan.textContent);
        if (newName && newName.trim()) {
          renameGroup(gid, newName.trim()).then(() => loadThreads());
        }
      }
    });
  });
}

async function newThread() {
  try {
    const body = { title: "New thread" };
    const model = $("#model-select").value;
    if (model) body.model = model;
    const perm = $("#permission-select").value;
    if (perm) body.permission_mode = perm;
    const t = await api("POST", "/api/threads", { body });
    state.threads.unshift(t);
    await openThread(t.id);
    renderThreadList();
  } catch (err) {
    alert("Failed to create thread: " + err.message);
  }
}

async function openThread(id) {
  state.activeThreadId = id;
  renderThreadList();
  // Close sidebar on mobile when a thread is opened.
  $("#sidebar").classList.remove("open");
  $("#sidebar-scrim").classList.remove("visible");
  try {
    const data = await api("GET", `/api/threads/${id}`);
    $("#thread-title").textContent = data.thread.title;
    $("#model-select").value = data.thread.model;
    $("#permission-select").value = data.thread.permission_mode;
    renderMessages(data.messages);
  } catch (err) {
    console.error("openThread", err);
  }
}

async function deleteThread(id, skipConfirm = false) {
  if (!skipConfirm && !await customConfirm("Delete thread", "Delete this thread? This cannot be undone.")) return;
  try {
    await api("DELETE", `/api/threads/${id}`);
    state.threads = state.threads.filter((t) => t.id !== id);
    if (state.activeThreadId === id) {
      state.activeThreadId = null;
      $("#thread-title").textContent = "Select or create a thread";
      renderMessages([]);
    }
    renderThreadList();
  } catch (err) {
    alert("Delete failed: " + err.message);
  }
}

function renderMessages(messages) {
  const box = $("#messages");
  box.innerHTML = "";
  if (!messages.length) {
    box.innerHTML = '<div class="m3-body-medium" style="text-align:center;color:var(--md-on-surface-variant);padding:48px">Start the conversation by sending a message below.</div>';
    return;
  }
  for (const m of messages) {
    box.appendChild(renderMessage(m));
  }
  box.scrollTop = box.scrollHeight;
}

function renderMessage(m) {
  const div = document.createElement("div");
  div.className = `message ${m.role}`;
  const iconId = m.role === "user" ? "icon-person" : m.role === "assistant" ? "icon-bot" : "icon-warning";
  const roleLabel = m.role === "user" ? "You" : m.role === "assistant" ? "Assistant" : "Error";
  let attHtml = "";
  if (m.attachments && Array.isArray(m.attachments) && m.attachments.length) {
    attHtml = '<div class="msg-attachments">' +
      m.attachments.map((a) => `<span class="msg-attachment-chip"><svg class="icon-xs"><use href="#icon-paperclip"/></svg> ${escapeHtml(a.filename)}</span>`).join("") +
      "</div>";
  }
  div.innerHTML = `
    <div class="msg-avatar"><svg class="icon-sm"><use href="#${iconId}"/></svg></div>
    <div class="msg-body">
      <div class="msg-role">${escapeHtml(roleLabel)}</div>
      <div class="msg-content">${formatContent(m.content)}</div>
      ${attHtml}
    </div>`;
  return div;
}

function formatContent(text) {
  // Minimal markdown-ish: code blocks ```...``` and inline `code`.
  const parts = [];
  let rest = text;
  const fence = /```(\w*)\n?([\s\S]*?)```/g;
  let last = 0;
  let m;
  while ((m = fence.exec(text)) !== null) {
    if (m.index > last) parts.push(escapeHtml(text.slice(last, m.index)));
    parts.push(`<pre><code>${escapeHtml(m[2])}</code></pre>`);
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push(escapeHtml(text.slice(last)));
  return parts.join("").replace(/`([^`]+)`/g, "<code>$1</code>");
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

/* ---------- Composer / send ---------- */

const promptInput = $("#prompt-input");
promptInput?.addEventListener("input", () => {
  promptInput.style.height = "auto";
  promptInput.style.height = Math.min(promptInput.scrollHeight, 160) + "px";
});

$("#file-input")?.addEventListener("change", (e) => {
  for (const file of e.target.files) {
    state.pendingAttachments.push(file);
  }
  renderPendingAttachments();
  e.target.value = "";
});

function renderPendingAttachments() {
  const box = $("#composer-attachments");
  box.innerHTML = state.pendingAttachments
    .map((f, i) => `<span class="att-chip"><svg class="icon-xs"><use href="#icon-paperclip"/></svg> ${escapeHtml(f.name)} <span class="att-remove" data-i="${i}"><svg class="icon-xs"><use href="#icon-close"/></svg></span></span>`)
    .join("");
  $$(".att-remove").forEach((el) => {
    el.addEventListener("click", () => {
      state.pendingAttachments.splice(Number(el.dataset.i), 1);
      renderPendingAttachments();
    });
  });
}

$("#composer")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  if (!state.activeThreadId) {
    alert("Create or select a thread first.");
    return;
  }
  const prompt = promptInput.value.trim();
  if (!prompt) return;
  const sendBtn = $("#send-btn");
  sendBtn.disabled = true;
  sendBtn.innerHTML = '<svg class="icon-sm icon-spin"><use href="#icon-loading"/></svg>';

  // Append a provisional user message.
  const box = $("#messages");
  const provisional = renderMessage({ role: "user", content: prompt, attachments: state.pendingAttachments.map((f) => ({ filename: f.name })) });
  box.appendChild(provisional);
  box.scrollTop = box.scrollHeight;
  promptInput.value = "";
  promptInput.style.height = "auto";

  const fd = new FormData();
  fd.append("prompt", prompt);
  for (const f of state.pendingAttachments) fd.append("file", f, f.name);
  state.pendingAttachments = [];
  renderPendingAttachments();

  try {
    const res = await api("POST", `/api/threads/${state.activeThreadId}/send`, { body: fd });
    // Replace provisional with the persisted user message + assistant reply.
    provisional.remove();
    box.appendChild(renderMessage(res.user_message));
    box.appendChild(renderMessage(res.assistant_message));
    box.scrollTop = box.scrollHeight;
    // Refresh thread list (title may have updated).
    await loadThreads();
  } catch (err) {
    provisional.remove();
    box.appendChild(renderMessage({ role: "error", content: err.message }));
    box.scrollTop = box.scrollHeight;
  } finally {
    sendBtn.disabled = false;
    sendBtn.innerHTML = '<svg class="icon-sm"><use href="#icon-send"/></svg>';
  }
});

/* ---------- File manager ---------- */

let filesCurrentPath = [];

async function openFilesPanel() {
  $("#files-panel").classList.remove("hidden");
  document.querySelector(".app-layout").classList.add("files-open");
  filesCurrentPath = [];
  await loadFiles();
}

function closeFilesPanel() {
  $("#files-panel").classList.add("hidden");
  document.querySelector(".app-layout").classList.remove("files-open");
}

async function loadFiles() {
  const path = filesCurrentPath.join("/");
  const qs = path ? `?path=${encodeURIComponent(path)}` : "";
  try {
    const entries = await api("GET", `/api/files${qs}`);
    renderFiles(entries);
    renderBreadcrumb();
  } catch (err) {
    $("#files-list").innerHTML = `<div class="error-text" style="padding:12px">${escapeHtml(err.message)}</div>`;
  }
}

function renderBreadcrumb() {
  const el = $("#files-breadcrumb");
  const parts = ["root", ...filesCurrentPath];
  el.innerHTML = parts
    .map((p, i) => {
      if (i === 0) return `<span class="crumb" data-i="-1">${p}</span>`;
      return ` / <span class="crumb" data-i="${i - 1}">${escapeHtml(p)}</span>`;
    })
    .join("");
  $$(".crumb").forEach((c) => {
    c.addEventListener("click", () => {
      const i = Number(c.dataset.i);
      filesCurrentPath = i < 0 ? [] : filesCurrentPath.slice(0, i + 1);
      loadFiles();
    });
  });
}

function renderFiles(entries) {
  const list = $("#files-list");
  if (!entries.length) {
    list.innerHTML = '<div class="m3-body-medium" style="padding:16px;color:var(--md-on-surface-variant)">Empty folder</div>';
    return;
  }
  list.innerHTML = entries
    .map((e) => {
      const iconId = e.is_dir ? "icon-folder" : fileIcon(e.name);
      const sizeStr = e.is_dir ? "" : formatSize(e.size);
      return `
        <div class="file-entry" data-name="${escapeHtml(e.name)}" data-dir="${e.is_dir}">
          <svg class="file-icon"><use href="#${iconId}"/></svg>
          <span class="file-name">${escapeHtml(e.name)}</span>
          <span class="file-size">${sizeStr}</span>
          <span class="file-actions">
            <button data-act="view" data-name="${escapeHtml(e.name)}" title="View"><svg class="icon-sm"><use href="#icon-eye"/></svg></button>
            <button data-act="del" data-name="${escapeHtml(e.name)}" title="Delete (Shift+click to skip confirmation)"><svg class="icon-sm"><use href="#icon-trash"/></svg></button>
          </span>
        </div>`;
    })
    .join("");
  $$(".file-entry").forEach((el) => {
    el.addEventListener("click", (e) => {
      const btn = e.target.closest("button[data-act]");
      if (btn) {
        e.stopPropagation();
        const act = btn.dataset.act;
        const name = btn.dataset.name;
        if (act === "del") deleteFile(name, e.shiftKey);
        else if (act === "view") viewFile(name);
        return;
      }
      if (el.dataset.dir === "true") {
        filesCurrentPath.push(el.dataset.name);
        loadFiles();
      } else {
        viewFile(el.dataset.name);
      }
    });
  });
}

function fileIcon(name) {
  const ext = name.split(".").pop().toLowerCase();
  if (["png", "jpg", "jpeg", "gif", "webp", "svg"].includes(ext)) return "icon-image";
  if (["md", "txt", "log"].includes(ext)) return "icon-text";
  if (["rs", "js", "ts", "py", "go", "java", "c", "cpp", "rb"].includes(ext)) return "icon-code";
  if (["json", "yaml", "yml", "toml"].includes(ext)) return "icon-gear";
  return "icon-file";
}

function formatSize(n) {
  if (n < 1024) return n + " B";
  if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
  return (n / 1048576).toFixed(1) + " MB";
}

async function viewFile(name) {
  const path = [...filesCurrentPath, name].join("/");
  try {
    const data = await api("GET", `/api/files/content?path=${encodeURIComponent(path)}`);
    $("#file-preview-name").textContent = name;
    const body = $("#file-preview-body");
    if (data.mime.startsWith("image/")) {
      body.innerHTML = `<img src="data:${data.mime};base64,${data.base64}" alt="${escapeHtml(name)}">`;
    } else if (data.mime.startsWith("text/") || isTextFile(name)) {
      const text = atob(data.base64);
      body.innerHTML = `<pre>${escapeHtml(text)}</pre>`;
    } else {
      body.innerHTML = `<p class="m3-body-medium">Binary file (${data.mime}, ${formatSize(data.size)}). Preview not available.</p>`;
    }
    $("#file-preview-dialog").classList.remove("hidden");
  } catch (err) {
    alert("Cannot read file: " + err.message);
  }
}

function isTextFile(name) {
  const ext = name.split(".").pop().toLowerCase();
  return ["txt", "md", "rs", "js", "ts", "py", "go", "java", "c", "cpp", "rb", "json", "yaml", "yml", "toml", "log", "html", "css", "sh"].includes(ext);
}

async function deleteFile(name, skipConfirm = false) {
  if (!skipConfirm && !await customConfirm("Delete file", `Delete ${name}?`)) return;
  const path = [...filesCurrentPath, name].join("/");
  try {
    await api("DELETE", `/api/files/delete?path=${encodeURIComponent(path)}`);
    await loadFiles();
  } catch (err) {
    alert("Delete failed: " + err.message);
  }
}

$("#files-upload-input")?.addEventListener("change", async (e) => {
  if (!e.target.files.length) return;
  const fd = new FormData();
  fd.append("path", filesCurrentPath.join("/"));
  for (const f of e.target.files) fd.append("file", f, f.name);
  try {
    await api("POST", `/api/files`, { body: fd });
    await loadFiles();
  } catch (err) {
    alert("Upload failed: " + err.message);
  }
  e.target.value = "";
});

async function mkdir() {
  const name = await customPrompt("New folder", "Folder name");
  if (!name) return;
  const path = [...filesCurrentPath, name].join("/");
  try {
    await api("POST", `/api/files/dir`, { body: { path } });
    await loadFiles();
  } catch (err) {
    alert("Create folder failed: " + err.message);
  }
}

/* ---------- TOTP ---------- */

let pendingTotpSecret = null;

async function totpSetup() {
  try {
    const res = await api("POST", "/api/auth/totp/setup");
    pendingTotpSecret = res.secret;
    $("#totp-secret").textContent = res.secret;
    $("#totp-dialog").classList.remove("hidden");
  } catch (err) {
    alert("TOTP setup failed: " + err.message);
  }
}

async function totpConfirm() {
  const code = $("#totp-verify-code").value.trim();
  if (!code) return;
  try {
    await api("POST", "/api/auth/totp/verify", { body: { code } });
    $("#totp-dialog").classList.add("hidden");
    alert("2FA enabled successfully.");
  } catch (err) {
    alert("Verification failed: " + err.message);
  }
}

/* ---------- Invites ---------- */

async function openInvites() {
  $("#invites-dialog").classList.remove("hidden");
  await loadInvites();
}

async function loadInvites() {
  try {
    const invites = await api("GET", "/api/invites");
    const list = $("#invites-list");
    if (!invites.length) {
      list.innerHTML = '<div class="m3-body-medium" style="color:var(--md-on-surface-variant)">No invites yet.</div>';
      return;
    }
    list.innerHTML = invites
      .map((i) => {
        const used = !!i.used_by_user_id;
        const status = used ? "used" : "fresh";
        const statusText = used ? "Used" : "Available";
        return `
          <div class="invite-row">
            <span class="invite-token">${escapeHtml(i.token)}</span>
            <span class="invite-status ${status}">${statusText}</span>
            <button data-token="${escapeHtml(i.token)}">Copy</button>
          </div>`;
      })
      .join("");
    $$(".invite-row button").forEach((b) => {
      b.addEventListener("click", () => {
        navigator.clipboard.writeText(b.dataset.token);
        b.textContent = "Copied!";
        setTimeout(() => (b.textContent = "Copy"), 1500);
      });
    });
  } catch (err) {
    alert("Load invites failed: " + err.message);
  }
}

async function createInvite() {
  try {
    await api("POST", "/api/invites");
    await loadInvites();
  } catch (err) {
    alert("Create invite failed: " + err.message);
  }
}

/* ---------- Wire up events ---------- */

document.addEventListener("DOMContentLoaded", async () => {
  $("#login-form")?.addEventListener("submit", doLogin);
  $("#register-form")?.addEventListener("submit", doRegister);
  $("#show-register")?.addEventListener("click", () => show("register-view"));
  $("#back-to-login")?.addEventListener("click", () => show("login-view"));
  $("#new-thread-btn")?.addEventListener("click", newThread);
  $("#logout-btn")?.addEventListener("click", doLogout);
  $("#files-btn")?.addEventListener("click", openFilesPanel);
  $("#files-close-btn")?.addEventListener("click", closeFilesPanel);
  $("#files-upload-btn")?.addEventListener("click", () => $("#files-upload-input").click());
  $("#files-mkdir-btn")?.addEventListener("click", mkdir);
  $("#file-preview-close")?.addEventListener("click", () => $("#file-preview-dialog").classList.add("hidden"));
  $("#totp-setup-btn")?.addEventListener("click", totpSetup);
  $("#totp-cancel")?.addEventListener("click", () => $("#totp-dialog").classList.add("hidden"));
  $("#totp-confirm")?.addEventListener("click", totpConfirm);
  $("#invites-btn")?.addEventListener("click", openInvites);
  $("#invites-close")?.addEventListener("click", () => $("#invites-dialog").classList.add("hidden"));
  $("#create-invite-btn")?.addEventListener("click", createInvite);

  // User menu toggle.
  $("#menu-btn")?.addEventListener("click", (e) => {
    e.stopPropagation();
    $("#user-menu").classList.toggle("hidden");
  });
  document.addEventListener("click", () => $("#user-menu").classList.add("hidden"));

  // Sidebar toggle (mobile).
  const sidebar = $("#sidebar");
  const sidebarScrim = $("#sidebar-scrim");
  $("#sidebar-toggle")?.addEventListener("click", (e) => {
    e.stopPropagation();
    const isOpen = sidebar.classList.toggle("open");
    sidebarScrim.classList.toggle("visible", isOpen);
  });
  // Click scrim to close sidebar.
  sidebarScrim?.addEventListener("click", () => {
    sidebar.classList.remove("open");
    sidebarScrim.classList.remove("visible");
  });

  // Enter to send (shift+enter for newline).
  promptInput?.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      $("#composer").requestSubmit();
    }
  });

  // Boot.
  const authed = await checkSession();
  if (authed) {
    await enterApp();
  } else {
    show("login-view");
  }
});
