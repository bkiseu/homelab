// Pure data logic for SentinelWatch. No DOM access here, so it can be
// unit-tested with `node --test`.

export const STORAGE_KEY = "sentinelwatch:v1";
export const SCHEMA_VERSION = 1;

export const TYPES = [
  "Job",
  "Contract",
  "Internship",
  "Fellowship",
  "Program",
  "Grant",
  "Scholarship",
  "Other",
];

// Order matters: it's the order shown in filters and pickers.
export const STATUSES = {
  waiting: { label: "Waiting", closed: false },
  interviewing: { label: "Interviewing", closed: false },
  rejected: { label: "Rejected", closed: true },
  ghosted: { label: "Ghosted", closed: true },
  offer: { label: "Offer", closed: true },
};

export const GHOST_AFTER_DAYS = 30;

export function defaultSettings(today = new Date()) {
  return {
    goal: 1000, // rejections to collect
    dailyTarget: 10, // applications per day
    deadline: `${today.getFullYear()}-12-31`,
  };
}

export function emptyState(today = new Date()) {
  return { version: SCHEMA_VERSION, apps: [], settings: defaultSettings(today) };
}

// ---------- dates (always local calendar days, never UTC) ----------

export function dayKey(d) {
  const date = d instanceof Date ? d : new Date(d);
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export function parseDay(key) {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d);
}

export function daysBetween(fromKey, toKey) {
  // Rounded to absorb DST shifts.
  return Math.round((parseDay(toKey) - parseDay(fromKey)) / 86400000);
}

// ---------- records ----------

let counter = 0;
export function newId() {
  counter = (counter + 1) % 1e6;
  return `${Date.now().toString(36)}-${counter.toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
}

export function makeApp(fields, now = new Date()) {
  const company = (fields.company || "").trim();
  if (!company) throw new Error("Company is required");
  const status = STATUSES[fields.status] ? fields.status : "waiting";
  const type = TYPES.includes(fields.type) ? fields.type : "Job";
  const iso = now.toISOString();
  return {
    id: fields.id || newId(),
    company,
    role: (fields.role || "").trim(),
    type,
    status,
    link: normalizeLink(fields.link),
    notes: (fields.notes || "").trim(),
    followUp: fields.followUp || "",
    appliedOn: fields.appliedOn || dayKey(now),
    createdAt: iso,
    updatedAt: iso,
    closedOn: STATUSES[status].closed ? dayKey(now) : "",
  };
}

export function normalizeLink(link) {
  const s = (link || "").trim();
  if (!s) return "";
  if (/^https?:\/\//i.test(s)) return s;
  if (/^[\w-]+(\.[\w-]+)+/.test(s)) return `https://${s}`;
  return "";
}

export function updateApp(app, changes, now = new Date()) {
  const next = { ...app, ...changes, updatedAt: now.toISOString() };
  if ("link" in changes) next.link = normalizeLink(changes.link);
  if ("company" in changes) {
    next.company = (changes.company || "").trim();
    if (!next.company) throw new Error("Company is required");
  }
  if ("status" in changes && changes.status !== app.status) {
    const closed = STATUSES[changes.status]?.closed;
    next.closedOn = closed ? dayKey(now) : "";
  }
  return next;
}

// Bulk add: one application per line. Accepts "Company - Role",
// "Company, Role, link" or "Company | Role | link".
export function parseBulk(text, defaults = {}, now = new Date()) {
  const apps = [];
  const errors = [];
  text.split(/\r?\n/).forEach((raw, i) => {
    const line = raw.trim();
    if (!line || line.startsWith("#")) return;
    let parts;
    if (line.includes("|")) parts = line.split("|");
    else if (line.includes(",")) parts = line.split(",");
    else parts = line.split(/\s+[-–—]\s+/);
    parts = parts.map((p) => p.trim());
    // Only treat a field as a link when it clearly is one, so roles like
    // "Node.js Engineer" stay roles.
    const looksLikeLink = (p) => !/\s/.test(p) && (/^https?:\/\//i.test(p) || /^www\./i.test(p) || /\.[a-z]{2,}\//i.test(p));
    const linkIdx = parts.findIndex((p, idx) => idx > 0 && looksLikeLink(p));
    const link = linkIdx > 0 ? parts.splice(linkIdx, 1)[0] : "";
    const [company, ...rest] = parts;
    try {
      apps.push(makeApp({ ...defaults, company, role: rest.join(" - "), link }, now));
    } catch (e) {
      errors.push(`Line ${i + 1}: ${e.message}`);
    }
  });
  return { apps, errors };
}

// ---------- stats ----------

export function countBy(apps, key) {
  const out = {};
  for (const a of apps) out[a[key]] = (out[a[key]] || 0) + 1;
  return out;
}

export function rejections(apps) {
  return apps.filter((a) => a.status === "rejected" || a.status === "ghosted").length;
}

export function loggedOn(apps, key) {
  return apps.filter((a) => a.appliedOn === key).length;
}

// Consecutive days (ending today, or yesterday if nothing logged yet today)
// with at least one application.
export function currentStreak(apps, today = new Date()) {
  const days = new Set(apps.map((a) => a.appliedOn));
  const cursor = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  if (!days.has(dayKey(cursor))) cursor.setDate(cursor.getDate() - 1);
  let n = 0;
  while (days.has(dayKey(cursor))) {
    n++;
    cursor.setDate(cursor.getDate() - 1);
  }
  return n;
}

export function longestStreak(apps) {
  const keys = [...new Set(apps.map((a) => a.appliedOn))].sort();
  let best = 0;
  let run = 0;
  let prev = null;
  for (const k of keys) {
    run = prev && daysBetween(prev, k) === 1 ? run + 1 : 1;
    best = Math.max(best, run);
    prev = k;
  }
  return best;
}

export function pace(apps, settings, today = new Date()) {
  const todayKey = dayKey(today);
  const daysLeft = Math.max(0, daysBetween(todayKey, settings.deadline) + 1);
  const got = rejections(apps);
  const remaining = Math.max(0, settings.goal - got);
  return {
    got,
    remaining,
    daysLeft,
    perDay: daysLeft > 0 ? remaining / daysLeft : remaining,
    percent: settings.goal > 0 ? Math.min(100, (got / settings.goal) * 100) : 0,
  };
}

// Waiting applications whose follow-up date has arrived.
export function followUpsDue(apps, today = new Date()) {
  const t = dayKey(today);
  return apps
    .filter((a) => !STATUSES[a.status].closed && a.followUp && a.followUp <= t)
    .sort((a, b) => a.followUp.localeCompare(b.followUp));
}

// Still "waiting" long enough that it's probably a ghost.
export function likelyGhosts(apps, today = new Date()) {
  const t = dayKey(today);
  return apps.filter((a) => a.status === "waiting" && daysBetween(a.appliedOn, t) >= GHOST_AFTER_DAYS);
}

export function filterApps(apps, { status = "all", query = "" } = {}) {
  const q = query.trim().toLowerCase();
  return apps
    .filter((a) => status === "all" || a.status === status)
    .filter(
      (a) =>
        !q ||
        a.company.toLowerCase().includes(q) ||
        a.role.toLowerCase().includes(q) ||
        a.notes.toLowerCase().includes(q),
    )
    .sort((a, b) => b.appliedOn.localeCompare(a.appliedOn) || b.createdAt.localeCompare(a.createdAt));
}

export function wrapped(apps, year) {
  const ys = String(year);
  const inYear = apps.filter((a) => a.appliedOn.startsWith(ys));
  const byStatus = countBy(inYear, "status");
  const byType = countBy(inYear, "type");
  const byMonth = Array(12).fill(0);
  for (const a of inYear) byMonth[Number(a.appliedOn.slice(5, 7)) - 1]++;
  const busiest = byMonth.reduce((best, n, i) => (n > byMonth[best] ? i : best), 0);
  const companies = Object.entries(countBy(inYear, "company"))
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 5);
  const heard = (byStatus.rejected || 0) + (byStatus.offer || 0) + (byStatus.interviewing || 0);
  return {
    year,
    total: inYear.length,
    byStatus,
    byType,
    byMonth,
    busiestMonth: inYear.length ? busiest : -1,
    topCompanies: companies,
    longestStreak: longestStreak(inYear),
    responseRate: inYear.length ? heard / inYear.length : 0,
    offers: byStatus.offer || 0,
  };
}

// ---------- persistence / backup ----------

export function exportJSON(state, now = new Date()) {
  return JSON.stringify({ app: "sentinelwatch", exportedAt: now.toISOString(), ...state }, null, 2);
}

// Validates an imported backup. mode "replace" swaps everything; "merge"
// keeps existing records and adds/updates by id (newest updatedAt wins).
export function importJSON(text, current, mode = "merge") {
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error("That file isn't valid JSON.");
  }
  if (!data || data.app !== "sentinelwatch" || !Array.isArray(data.apps)) {
    throw new Error("That doesn't look like a SentinelWatch backup.");
  }
  const clean = data.apps
    .filter((a) => a && typeof a.company === "string" && a.company.trim() && STATUSES[a.status])
    .map((a) => ({ ...makeApp(a, new Date(a.createdAt || Date.now())), ...a }));
  const settings = { ...current.settings, ...(data.settings || {}) };
  if (mode === "replace") return { version: SCHEMA_VERSION, apps: clean, settings };
  const byId = new Map(current.apps.map((a) => [a.id, a]));
  for (const a of clean) {
    const existing = byId.get(a.id);
    if (!existing || (a.updatedAt || "") > (existing.updatedAt || "")) byId.set(a.id, a);
  }
  return { version: SCHEMA_VERSION, apps: [...byId.values()], settings };
}

export function toCSV(apps) {
  const cols = ["appliedOn", "company", "role", "type", "status", "link", "followUp", "closedOn", "notes"];
  const esc = (v) => {
    const s = String(v ?? "");
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [cols.join(","), ...apps.map((a) => cols.map((c) => esc(a[c])).join(","))].join("\n");
}

export function loadState(storage, today = new Date()) {
  try {
    const raw = storage.getItem(STORAGE_KEY);
    if (!raw) return emptyState(today);
    const data = JSON.parse(raw);
    if (!Array.isArray(data.apps)) return emptyState(today);
    return { version: SCHEMA_VERSION, apps: data.apps, settings: { ...defaultSettings(today), ...data.settings } };
  } catch {
    return emptyState(today);
  }
}

export function saveState(storage, state) {
  storage.setItem(STORAGE_KEY, JSON.stringify(state));
}
