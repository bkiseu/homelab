import * as L from "./logic.js";

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const LAST_BACKUP_KEY = "sentinelwatch:lastBackup";

// localStorage can throw (private mode, blocked storage). Fall back to memory
// so the page still works for the session.
const storage = (() => {
  try {
    const k = "__sw_probe";
    localStorage.setItem(k, "1");
    localStorage.removeItem(k);
    return localStorage;
  } catch {
    const mem = new Map();
    return { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, String(v)), removeItem: (k) => mem.delete(k) };
  }
})();

let state = L.loadState(storage);
const ui = { view: "log", status: "all", query: "", year: new Date().getFullYear() };

function save() {
  try {
    L.saveState(storage, state);
  } catch {
    toast("Couldn't save. Storage may be full or blocked; export a backup now.");
  }
  render();
}

// ---------- helpers ----------

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === "class") node.className = v;
    else if (k === "style") node.style.cssText = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else if (k === "dataset") Object.assign(node.dataset, v);
    else node.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    node.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return node;
}

function fmtDay(key) {
  if (!key) return "";
  const d = L.parseDay(key);
  const sameYear = d.getFullYear() === new Date().getFullYear();
  return d.toLocaleDateString(undefined, { day: "numeric", month: "short", ...(sameYear ? {} : { year: "numeric" }) });
}

function ago(key) {
  const n = L.daysBetween(key, L.dayKey(new Date()));
  if (n <= 0) return "today";
  if (n === 1) return "yesterday";
  return `${n} days ago`;
}

const statusColor = (s) => `var(--${s})`;

function fillSelect(select, options, value) {
  select.replaceChildren(...options.map(([v, label]) => el("option", { value: v }, label)));
  if (value) select.value = value;
}

const typeOptions = L.TYPES.map((t) => [t, t]);
const statusOptions = Object.entries(L.STATUSES).map(([k, s]) => [k, s.label]);

let toastTimer;
function toast(msg, action) {
  const t = $("#toast");
  t.replaceChildren(msg);
  if (action) t.append(el("button", { type: "button", onclick: () => { action.run(); t.hidden = true; } }, action.label));
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), action ? 6000 : 3000);
}

function download(name, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = el("a", { href: url, download: name });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// ---------- render ----------

function render() {
  renderStats();
  renderAlerts();
  if (ui.view === "log") renderList();
  if (ui.view === "wall") renderWall();
  if (ui.view === "wrapped") renderWrapped();
  if (ui.view === "settings") renderSettings();
}

function renderStats() {
  const { apps, settings } = state;
  const today = new Date();
  const p = L.pace(apps, settings, today);
  $("#goal-n").textContent = settings.goal.toLocaleString();
  $("#got").textContent = p.got.toLocaleString();
  $("#goal-bar span").style.width = `${p.percent}%`;
  $("#goal-bar").setAttribute("aria-valuenow", Math.round(p.percent));
  $("#pace-line").textContent =
    p.remaining === 0
      ? "Goal reached. Every one of them was practice."
      : p.daysLeft === 0
        ? `Deadline passed with ${p.remaining.toLocaleString()} to go. Move it in Settings.`
        : `${p.daysLeft} days left · about ${p.perDay.toFixed(1)} a day to get there`;

  const n = L.loggedOn(apps, L.dayKey(today));
  $("#today-n").textContent = n;
  $("#today-target").textContent = settings.dailyTarget;
  $("#today-bar span").style.width = `${Math.min(100, (n / settings.dailyTarget) * 100)}%`;
  $("#today-line").textContent =
    n === 0 ? "Start with one." : n >= settings.dailyTarget ? "Target hit. Anything more is a bonus." : `${settings.dailyTarget - n} to go today.`;

  $("#streak").textContent = L.currentStreak(apps, today);
  $("#best-streak").textContent = L.longestStreak(apps);
  $("#total").textContent = apps.length.toLocaleString();
  $("#open-n").textContent = apps.filter((a) => !L.STATUSES[a.status].closed).length;
  const offers = apps.filter((a) => a.status === "offer").length;
  $("#offer-n").textContent = `${offers} offer${offers === 1 ? "" : "s"}`;
}

function renderAlerts() {
  const box = $("#alerts");
  box.replaceChildren();
  const due = L.followUpsDue(state.apps);
  if (due.length) {
    box.append(
      el("div", { class: "alert" },
        el("p", {}, el("strong", {}, `${due.length} follow-up${due.length > 1 ? "s" : ""} due: `),
          el("span", { class: "names" }, due.slice(0, 4).map((a) => a.company).join(", ") + (due.length > 4 ? "…" : ""))),
        el("button", { type: "button", onclick: () => { setView("log"); ui.status = "all"; ui.query = ""; $("#search").value = ""; renderList(due.map((a) => a.id)); } }, "Show them")),
    );
  }
  const ghosts = L.likelyGhosts(state.apps);
  if (ghosts.length) {
    box.append(
      el("div", { class: "alert" },
        el("p", {}, el("strong", {}, `${ghosts.length} still waiting after ${L.GHOST_AFTER_DAYS}+ days. `),
          el("span", { class: "names" }, "Probably ghosts. They count toward the goal once marked.")),
        el("button", { type: "button", onclick: () => {
          const ids = new Set(ghosts.map((a) => a.id));
          const before = state.apps;
          state = { ...state, apps: state.apps.map((a) => (ids.has(a.id) ? L.updateApp(a, { status: "ghosted" }) : a)) };
          save();
          toast(`Marked ${ids.size} as ghosted.`, { label: "Undo", run: () => { state = { ...state, apps: before }; save(); } });
        } }, "Mark all ghosted")),
    );
  }
}

function renderFilters() {
  const counts = L.countBy(state.apps, "status");
  const chips = [["all", "All", state.apps.length], ...Object.entries(L.STATUSES).map(([k, s]) => [k, s.label, counts[k] || 0])];
  $("#filters").replaceChildren(
    ...chips.map(([k, label, n]) =>
      el("button", { type: "button", class: "chip", "aria-pressed": String(ui.status === k), onclick: () => { ui.status = k; renderList(); } },
        k !== "all" ? el("span", { class: "dot", style: `background:${statusColor(k)}` }) : null,
        label, el("span", { class: "n" }, n)),
    ),
  );
}

function renderList(onlyIds) {
  renderFilters();
  let apps = L.filterApps(state.apps, { status: ui.status, query: ui.query });
  if (onlyIds) {
    const ids = new Set(onlyIds);
    apps = apps.filter((a) => ids.has(a.id));
  }
  const todayKey = L.dayKey(new Date());
  const list = $("#list");
  list.replaceChildren(
    ...apps.slice(0, 300).map((a) => {
      const statusSel = el("select", { "aria-label": `Status for ${a.company}`, onchange: (e) => setStatus(a.id, e.target.value) });
      fillSelect(statusSel, statusOptions, a.status);
      const overdue = a.followUp && !L.STATUSES[a.status].closed && a.followUp <= todayKey;
      return el("li", { class: "item" },
        el("span", { class: "stripe", style: `background:${statusColor(a.status)}` }),
        el("div", {},
          el("div", { class: "title" }, a.company, a.role ? el("span", { class: "role" }, ` · ${a.role}`) : null),
          el("div", { class: "meta" },
            el("span", { class: "badge" }, a.type),
            el("span", { title: a.appliedOn }, `Applied ${fmtDay(a.appliedOn)} (${ago(a.appliedOn)})`),
            a.closedOn && L.STATUSES[a.status].closed && a.status !== "offer" ? el("span", {}, `Closed ${fmtDay(a.closedOn)}`) : null,
            a.followUp ? el("span", { class: overdue ? "due" : "" }, `Follow up ${fmtDay(a.followUp)}`) : null,
            a.link ? el("a", { href: a.link, target: "_blank", rel: "noopener noreferrer" }, "Open link ↗") : null),
          a.notes ? el("p", { class: "notes" }, a.notes) : null),
        el("div", { class: "side" }, statusSel,
          el("button", { type: "button", class: "icon-btn", "aria-label": `Edit ${a.company}`, onclick: () => openEdit(a.id) }, "Edit")),
      );
    }),
  );
  if (apps.length > 300) list.append(el("li", { class: "hint" }, `Showing the newest 300 of ${apps.length}. Search to narrow down.`));
  const empty = $("#empty");
  empty.hidden = apps.length > 0;
  empty.textContent = state.apps.length ? "Nothing matches that filter." : "Nothing logged yet. Your first one goes above.";
}

function renderWall() {
  $("#legend").replaceChildren(
    ...Object.entries(L.STATUSES).map(([k, s]) => el("span", {}, el("span", { class: "dot", style: `background:${statusColor(k)}` }), s.label)),
  );
  const wall = $("#wall");
  const sorted = [...state.apps].sort((a, b) => b.appliedOn.localeCompare(a.appliedOn));
  if (!sorted.length) {
    wall.replaceChildren(el("p", { class: "empty" }, "Log your first application. The wall fills the moment you hear back."));
    return;
  }
  const groups = new Map();
  for (const a of sorted) {
    const k = a.appliedOn.slice(0, 7);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(a);
  }
  wall.replaceChildren(
    ...[...groups].map(([k, apps]) => {
      const [y, m] = k.split("-").map(Number);
      return el("div", { class: "month" },
        el("h3", {}, `${MONTHS[m - 1]} ${y} · ${apps.length}`),
        el("div", { class: "tiles" },
          ...apps.map((a) => {
            const lit = a.status !== "waiting";
            return el("button", {
              type: "button",
              class: `tile${lit ? " lit" : ""}`,
              style: lit ? `background:${statusColor(a.status)}` : null,
              title: `${a.company}${a.role ? ` · ${a.role}` : ""}: ${L.STATUSES[a.status].label}`,
              "aria-label": `${a.company}, ${L.STATUSES[a.status].label}`,
              onclick: () => openEdit(a.id),
            });
          })));
    }),
  );
}

function renderWrapped() {
  const years = [...new Set([new Date().getFullYear(), ...state.apps.map((a) => Number(a.appliedOn.slice(0, 4)))])].sort((a, b) => b - a);
  fillSelect($("#wrapped-year"), years.map((y) => [y, y]), String(ui.year));
  const w = L.wrapped(state.apps, ui.year);
  const box = $("#wrapped");
  if (!w.total) {
    box.replaceChildren(el("p", { class: "empty" }, `Nothing logged in ${ui.year} yet.`));
    return;
  }
  const max = Math.max(...w.byMonth, 1);
  const order = Object.keys(L.STATUSES);
  box.replaceChildren(
    el("div", { class: "wrapped-grid" },
      el("div", { class: "w-card wide" }, el("span", { class: "muted" }, `In ${w.year} you put yourself forward`),
        el("p", { class: "big" }, w.total.toLocaleString(), el("small", {}, " times"))),
      el("div", { class: "w-card" }, el("span", { class: "muted" }, "Rejections + ghosts"),
        el("p", { class: "big" }, ((w.byStatus.rejected || 0) + (w.byStatus.ghosted || 0)).toLocaleString())),
      el("div", { class: "w-card" }, el("span", { class: "muted" }, "Offers"), el("p", { class: "big" }, w.offers)),
      el("div", { class: "w-card" }, el("span", { class: "muted" }, "Heard back"), el("p", { class: "big" }, `${Math.round(w.responseRate * 100)}%`)),
      el("div", { class: "w-card" }, el("span", { class: "muted" }, "Longest streak"), el("p", { class: "big" }, w.longestStreak, el("small", {}, " days"))),
      el("div", { class: "w-card wide" }, el("span", { class: "muted" }, "Busiest month"),
        el("p", { class: "big" }, w.busiestMonth >= 0 ? `${MONTHS[w.busiestMonth]}` : "–", el("small", {}, w.busiestMonth >= 0 ? ` · ${w.byMonth[w.busiestMonth]} applications` : ""))),
      el("div", { class: "w-card full" }, el("span", { class: "muted" }, "Month by month"),
        el("div", { class: "months" },
          ...w.byMonth.map((n, i) => el("div", { title: `${MONTHS[i]}: ${n}` }, el("span", {}, n || ""), el("i", { style: `height:${(n / max) * 80}px` }), MONTHS[i][0])))),
      el("div", { class: "w-card full" }, el("span", { class: "muted" }, "How they ended"),
        el("div", { class: "split" },
          ...order.filter((k) => w.byStatus[k]).map((k) => el("span", { title: `${L.STATUSES[k].label}: ${w.byStatus[k]}`, style: `width:${(w.byStatus[k] / w.total) * 100}%;background:${statusColor(k)}` }))),
        el("p", { class: "legend" }, ...order.filter((k) => w.byStatus[k]).map((k) => el("span", {}, el("span", { class: "dot", style: `background:${statusColor(k)}` }), `${L.STATUSES[k].label} ${w.byStatus[k]}`)))),
      el("div", { class: "w-card wide" }, el("span", { class: "muted" }, "Most applied to"),
        w.topCompanies.some(([, n]) => n > 1)
          ? el("ol", { class: "w-list" }, ...w.topCompanies.filter(([, n]) => n > 1).map(([c, n]) => el("li", {}, `${c} (${n})`)))
          : el("p", { class: "muted" }, "No company twice yet. Every one was a fresh shot.")),
      el("div", { class: "w-card wide" }, el("span", { class: "muted" }, "By type"),
        el("ol", { class: "w-list" }, ...Object.entries(w.byType).sort((a, b) => b[1] - a[1]).map(([t, n]) => el("li", {}, `${t} (${n})`)))),
    ),
  );
}

function renderSettings() {
  const f = $("#settings-form");
  f.goal.value = state.settings.goal;
  f.dailyTarget.value = state.settings.dailyTarget;
  f.deadline.value = state.settings.deadline;
  const last = storage.getItem(LAST_BACKUP_KEY);
  $("#last-backup").textContent = last ? `Last backup: ${fmtDay(last)} (${ago(last)})` : "No backup exported from this browser yet.";
}

// ---------- actions ----------

function setView(view) {
  ui.view = view;
  $$(".tabs button").forEach((b) => b.setAttribute("aria-selected", String(b.dataset.view === view)));
  $$("section.view").forEach((s) => (s.hidden = s.dataset.view !== view));
  try { storage.setItem("sentinelwatch:view", view); } catch {}
  render();
}

function setStatus(id, status) {
  state = { ...state, apps: state.apps.map((a) => (a.id === id ? L.updateApp(a, { status }) : a)) };
  save();
  if (status === "rejected") toast("Rejected. One step closer to the goal.");
  if (status === "offer") toast("An offer. Well done.");
}

function openEdit(id) {
  const a = state.apps.find((x) => x.id === id);
  if (!a) return;
  const d = $("#edit-dialog");
  const f = $("#edit-form");
  f.dataset.id = id;
  for (const k of ["company", "role", "link", "notes", "followUp", "appliedOn"]) f[k].value = a[k] || "";
  fillSelect(f.type, typeOptions, a.type);
  fillSelect(f.status, statusOptions, a.status);
  d.showModal();
}

function readForm(form) {
  return Object.fromEntries(new FormData(form).entries());
}

// ---------- wiring ----------

function init() {
  for (const f of [$("#log-form"), $("#bulk-form")]) {
    fillSelect(f.type, typeOptions, "Job");
    fillSelect(f.status, statusOptions, "waiting");
  }
  $("#log-form").appliedOn.value = L.dayKey(new Date());

  $$(".tabs button").forEach((b) => b.addEventListener("click", () => setView(b.dataset.view)));

  $$(".seg button").forEach((b) =>
    b.addEventListener("click", () => {
      $$(".seg button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
      const many = b.dataset.mode === "many";
      $("#log-form").hidden = many;
      $("#bulk-form").hidden = !many;
    }),
  );

  $("#log-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const form = e.target;
    try {
      const fields = readForm(form);
      const a = L.makeApp(fields);
      if (fields.appliedOn) a.appliedOn = fields.appliedOn;
      state = { ...state, apps: [...state.apps, a] };
      save();
      const keepType = form.type.value;
      form.reset();
      form.type.value = keepType;
      form.status.value = "waiting";
      form.appliedOn.value = L.dayKey(new Date());
      form.company.focus();
      toast(`Logged ${a.company}.`, { label: "Undo", run: () => { state = { ...state, apps: state.apps.filter((x) => x.id !== a.id) }; save(); } });
    } catch (err) {
      toast(err.message);
    }
  });

  $("#bulk-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const form = e.target;
    const { apps, errors } = L.parseBulk(form.bulk.value, { type: form.type.value, status: form.status.value });
    if (apps.length) {
      state = { ...state, apps: [...state.apps, ...apps] };
      save();
      form.bulk.value = "";
    }
    $("#bulk-result").textContent = `Added ${apps.length}.${errors.length ? ` Skipped: ${errors.join("; ")}` : ""}`;
  });

  $("#search").addEventListener("input", (e) => { ui.query = e.target.value; renderList(); });

  $("#edit-form").addEventListener("submit", (e) => {
    const action = e.submitter?.value;
    const f = e.target;
    const id = f.dataset.id;
    if (action === "save") {
      try {
        const changes = readForm(f);
        state = { ...state, apps: state.apps.map((a) => (a.id === id ? L.updateApp(a, changes) : a)) };
        save();
      } catch (err) {
        e.preventDefault();
        toast(err.message);
      }
    } else if (action === "delete") {
      const removed = state.apps.find((a) => a.id === id);
      state = { ...state, apps: state.apps.filter((a) => a.id !== id) };
      save();
      toast(`Deleted ${removed.company}.`, { label: "Undo", run: () => { state = { ...state, apps: [...state.apps, removed] }; save(); } });
    }
  });

  $("#wrapped-year").addEventListener("change", (e) => { ui.year = Number(e.target.value); renderWrapped(); });

  $("#settings-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const f = e.target;
    const goal = Math.max(1, Math.round(Number(f.goal.value)) || 1000);
    const dailyTarget = Math.max(1, Math.round(Number(f.dailyTarget.value)) || 10);
    const deadline = f.deadline.value || L.defaultSettings().deadline;
    state = { ...state, settings: { goal, dailyTarget, deadline } };
    save();
    $("#settings-saved").textContent = "Saved.";
    setTimeout(() => ($("#settings-saved").textContent = ""), 2000);
  });

  const stamp = () => { try { storage.setItem(LAST_BACKUP_KEY, L.dayKey(new Date())); } catch {} renderSettings(); };
  $("#export-json").addEventListener("click", () => {
    download(`sentinelwatch-${L.dayKey(new Date())}.json`, L.exportJSON(state), "application/json");
    stamp();
  });
  $("#export-csv").addEventListener("click", () => {
    download(`sentinelwatch-${L.dayKey(new Date())}.csv`, L.toCSV(L.filterApps(state.apps)), "text/csv");
  });
  $("#import-file").addEventListener("change", async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    const out = $("#backup-result");
    try {
      const mode = $("#import-mode").value;
      if (mode === "replace" && state.apps.length && !window.confirm(`Replace all ${state.apps.length} applications with this backup?`)) return;
      const before = state.apps.length;
      state = L.importJSON(await file.text(), state, mode);
      save();
      out.textContent = `Imported. ${before} → ${state.apps.length} applications.`;
    } catch (err) {
      out.textContent = err.message;
    } finally {
      e.target.value = "";
    }
  });

  $("#wipe").addEventListener("click", () => {
    if (!state.apps.length) return toast("Nothing to delete.");
    const typed = window.prompt(`This deletes all ${state.apps.length} applications in this browser. Type DELETE to confirm.`);
    if (typed !== "DELETE") return;
    state = L.emptyState();
    save();
    toast("Everything deleted.");
  });

  // Re-render at midnight-ish so "today" and streaks stay honest if the tab stays open.
  let lastDay = L.dayKey(new Date());
  setInterval(() => {
    const d = L.dayKey(new Date());
    if (d !== lastDay) { lastDay = d; render(); }
  }, 60_000);

  // Keep multiple tabs in sync.
  window.addEventListener("storage", (e) => {
    if (e.key === L.STORAGE_KEY) { state = L.loadState(storage); render(); }
  });

  let saved = "log";
  try { saved = storage.getItem("sentinelwatch:view") || "log"; } catch {}
  setView(["log", "wall", "wrapped", "settings"].includes(saved) ? saved : "log");
}

init();
