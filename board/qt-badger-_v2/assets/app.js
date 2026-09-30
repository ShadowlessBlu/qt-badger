// QT BADGEr dashboard: a thin client for the hub's JSON API (python/main.py).
// Same API the Android app uses. Polls /api/status every ~1.5 s, and /api/events
// whenever the status says something new happened (SOS, arrival, reminder, ...).
// User text is only ever placed with textContent, never innerHTML.
"use strict";

(() => {
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => [...root.querySelectorAll(s)];

  const SCREENS = [
    ["home", "Home"], ["map", "Map"], ["peers", "Peers"], ["tasks", "Tasks"], ["voice", "Voice"],
    ["alert", "Alert"], ["settings", "Settings"], ["badge", "Name tag"], ["inbox", "Inbox"],
  ];

  const S = {
    key: localStorage.getItem("badgeKey") || "",
    status: null,
    seq: null,           // last event seq we've handled (null = first poll, nothing handled yet)
    events: [],          // activity log, newest first
    online: false,
    dirty: new Set(),    // forms the user is editing right now: don't overwrite them from the poll
    last: {},            // JSON of the last data each list was rendered from
    audio: null,
  };

  // ---------------------------------------------------------------- helpers
  function el(tag, props = {}, ...kids) {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === "class") n.className = v;
      else if (k === "text") n.textContent = v;
      else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
      else if (v === true) n.setAttribute(k, "");
      else if (v !== false && v != null) n.setAttribute(k, v);
    }
    for (const kid of kids) if (kid != null) n.append(kid);
    return n;
  }

  function toast(msg, isErr = false) {
    const t = $("#toast");
    t.textContent = msg;
    t.classList.toggle("err", isErr);
    t.classList.add("show");
    clearTimeout(toast.t);
    toast.t = setTimeout(() => t.classList.remove("show"), isErr ? 4500 : 2200);
  }

  async function api(method, path, body) {
    const headers = { "Content-Type": "application/json" };
    if (S.key) headers["X-Badge-Key"] = S.key;
    const res = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    let data = null;
    try { data = await res.json(); } catch (_) { /* not JSON */ }
    if (res.status === 401) { $("#keybox").hidden = false; throw new Error("Access key needed"); }
    if (!res.ok) throw new Error((data && data.detail) || `${res.status} ${res.statusText}`);
    return data;
  }

  // run an action, toast the outcome, then refresh so the page catches up immediately
  async function act(fn, okMsg) {
    try {
      const r = await fn();
      if (okMsg) toast(okMsg);
      poll();
      return r;
    } catch (e) {
      toast(e.message, true);
      return null;
    }
  }

  const fmtTime = (epoch) => new Date(epoch * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const fmtDist = (m) => (m == null ? "–" : m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(2)} km`);
  const fmtDur = (s) => (s == null ? "–" : s < 90 ? `${s}s` : s < 5400 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`);

  // keep a form's fields in step with the hub unless the user is typing in them
  function fill(input, value) {
    if (!input || document.activeElement === input || value == null) return;
    const v = String(value);
    if (input.value !== v && !S.dirty.has(input.form ? input.form.id : input.id)) input.value = v;
  }

  // ---------------------------------------------------------------- rendering
  function pill(text, kind) { return el("span", { class: `pill ${kind || ""}`, text }); }

  function renderPills(st) {
    const box = $("#pills");
    box.replaceChildren();
    if (!S.online) { box.append(pill("hub offline", "bad")); return; }
    if (!st.mcu.alive) { box.append(pill("badge not answering", "bad")); return; }
    box.append(pill("badge online", "ok"));
    const g = st.gps;
    box.append(pill(g.fix ? `position: ${g.source === "gps" ? "GPS" : "phone"}` : `no fix (${g.satellites} sat)`, g.fix ? "ok" : "warn"));
    if (st.badge.unread) box.append(pill(`${st.badge.unread} unread`, "warn"));
    if (st.badge.finding) box.append(pill("finding…", "warn"));
    box.append(pill(`screen: ${st.badge.screen}`));
  }

  function renderScreens(st) {
    const box = $("#screens");
    if (!box.children.length) {
      for (const [id, label] of SCREENS) {
        box.append(el("button", { type: "button", "data-screen": id, text: label, onclick: () => act(() => api("POST", "/api/nav", { screen: id })) }));
      }
    }
    for (const b of $$("button", box)) b.classList.toggle("on", b.dataset.screen === st.badge.screen);
    $("#btn-find").textContent = st.badge.finding ? "⏹ Stop finding" : "🔊 Find my badge";
  }

  // lists are only rebuilt when their data actually changed, so a poll never resets scroll/focus
  function sameAsLast(key, value) {
    const j = JSON.stringify(value);
    if (S.last[key] === j) return true;
    S.last[key] = j;
    return false;
  }

  function renderTasks(tasks) {
    if (sameAsLast("tasks", tasks)) return;
    const list = $("#task-list");
    list.replaceChildren();
    const open = tasks.filter((t) => !t.done).length;
    $("#task-count").textContent = tasks.length ? `${open} open · ${tasks.length}/8` : "";
    if (!tasks.length) list.append(el("p", { class: "empty", text: "No tasks on the badge." }));
    for (const t of tasks) {
      const box = el("input", { type: "checkbox", checked: t.done, "aria-label": "done" });
      box.addEventListener("change", () => act(() => api("POST", `/api/tasks/${t.index}/toggle`)));
      list.append(el("div", { class: `item${t.done ? " done" : ""}` }, box,
        el("span", { class: "txt", text: t.text }),
        el("button", { class: "x", type: "button", title: "Delete", text: "✕", onclick: () => act(() => api("DELETE", `/api/tasks/${t.index}`)) })));
    }
  }

  function renderMsgs(msgs) {
    if (sameAsLast("msgs", msgs)) return;
    const list = $("#msg-list");
    list.replaceChildren();
    $("#msg-count").textContent = msgs.length ? `${msgs.length}/5` : "";
    if (!msgs.length) list.append(el("p", { class: "empty", text: "Inbox is empty." }));
    for (const m of msgs) {
      list.append(el("div", { class: `item${m.unread ? " unread" : ""}` },
        m.unread ? el("span", { class: "dot" }) : null,
        el("span", { class: "txt", text: m.text }),
        el("button", { class: "x", type: "button", title: "Delete", text: "✕", onclick: () => act(() => api("DELETE", `/api/messages/${m.index}`)) })));
    }
  }

  function renderPeers(peers) {
    if (sameAsLast("peers", peers)) return;
    const list = $("#peer-list");
    list.replaceChildren();
    if (!peers.length) list.append(el("p", { class: "empty", text: "No peers yet. Other badges and phones report through this hub." }));
    for (const p of peers) {
      list.append(el("div", { class: "item" },
        el("span", { class: "txt", text: p.name || `Badge ${p.id}` }),
        el("span", { class: "meta", text: `${fmtDist(p.distance_m)} · ${fmtDur(p.age_s)} ago` })));
    }
  }

  function renderReminders(rems) {
    if (sameAsLast("rems", rems)) return;
    const list = $("#reminder-list");
    list.replaceChildren();
    if (!rems.length) list.append(el("p", { class: "empty", text: "No timed reminders." }));
    for (const r of rems) {
      list.append(el("div", { class: "item" },
        el("span", { class: "txt", text: r.text }),
        el("span", { class: "meta", text: new Date(r.at * 1000).toLocaleString([], { dateStyle: "short", timeStyle: "short" }) }),
        el("button", { class: "x", type: "button", title: "Cancel", text: "✕", onclick: () => act(() => api("DELETE", `/api/reminders/${r.id}`)) })));
    }
  }

  function stat(label, value) { return el("div", { class: "stat" }, el("b", { text: value }), el("span", { text: label })); }

  function renderGps(st) {
    const g = st.gps, box = $("#gps-stats");
    box.replaceChildren(
      stat("Distance", g.fix ? fmtDist(g.distance_m) : "–"),
      stat("Bearing", g.fix && g.bearing != null ? `${Math.round(g.bearing)}°` : "–"),
      stat("Source", g.fix ? (g.source === "gps" ? "badge GPS" : "phone") : "none"),
      stat("Satellites", String(g.satellites ?? 0)),
      stat("Position", g.fix ? `${g.lat.toFixed(5)}, ${g.lon.toFixed(5)}` : "–"),
    );
    const d = st.destination;
    fill($("#dest-name"), d.name); fill($("#dest-lat"), d.lat); fill($("#dest-lon"), d.lon);
    $("#btn-osm").href = `https://www.openstreetmap.org/?mlat=${d.lat}&mlon=${d.lon}#map=17/${d.lat}/${d.lon}`;
  }

  function renderControls(st) {
    const b = st.badge;
    const bl = $("#bl");
    if (document.activeElement !== bl && !S.dirty.has("bl")) bl.value = b.backlight;
    $("#bl-out").textContent = `${Math.round((+bl.value) * 100 / 255)}%`;
    if (document.activeElement !== $("#haptic")) $("#haptic").checked = b.haptic;
    if (document.activeElement !== $("#peer-range")) {
      const sel = $("#peer-range");
      if (![...sel.options].some((o) => +o.value === b.peer_range_m)) sel.append(el("option", { value: b.peer_range_m, text: `${b.peer_range_m} m` }));
      sel.value = b.peer_range_m;
    }
    const tz = $("#tz");
    if (document.activeElement !== tz) tz.value = String(st.config.tz_offset_min);
  }

  function renderProfile(st) {
    const p = st.profile;
    fill($("#p-name"), p.name); fill($("#p-title"), p.title); fill($("#p-org"), p.org);
    $("#qr-hint").textContent = p.has_qr ? `A ${p.qr_size}×${p.qr_size} QR code is on the badge. Change it from the Android app.` : "QR codes are set from the Android app (it does the QR maths and uploads the bitmap).";
  }

  function renderSystem(st) {
    const h = st.hub;
    $("#sys-stats").replaceChildren(
      stat("Hub up", fmtDur(h.hub_uptime_s)), stat("Badge up", fmtDur(st.mcu.uptime_s)),
      stat("CPU temp", h.cpu_temp_c == null ? "–" : `${h.cpu_temp_c} °C`),
      stat("Memory", h.mem_used_pct == null ? "–" : `${h.mem_used_pct}%`),
      stat("Disk", h.disk_used_pct == null ? "–" : `${h.disk_used_pct}%`),
      stat("Restores", String(h.restores)), stat("Protocol", `${st.mcu.protocol ?? "?"}`),
      stat("AI model", h.llm && h.llm.ready ? "loaded" : "on demand"),
    );
  }

  function renderEvents() {
    const list = $("#event-list");
    list.replaceChildren();
    if (!S.events.length) list.append(el("p", { class: "empty", text: "Nothing yet." }));
    for (const e of S.events.slice(0, 30)) {
      const detail = e.type === "alert" ? `${e.source} – ${e.message}` : e.type === "voice" ? e.text : e.type === "reminder" ? e.text
        : e.type === "arrived" ? e.name : e.type === "link" ? (e.mcu ? "badge answering" : "badge lost") : e.restored ? "restarted, state restored" : "";
      list.append(el("div", { class: "item" }, el("span", { class: "meta", text: fmtTime(e.t) }), el("span", { class: "txt", text: `${e.type}${detail ? ": " + detail : ""}` })));
    }
  }

  function render(st) {
    $("#subtitle").textContent = `Badge #${st.badge.id ?? "?"}${st.hub.host_ip ? " · " + st.hub.host_ip : ""} · hub v2.0`;
    renderPills(st); renderScreens(st); renderTasks(st.tasks); renderMsgs(st.messages); renderPeers(st.peers);
    renderReminders(st.reminders); renderGps(st); renderControls(st); renderProfile(st); renderSystem(st);
    const off = $("#offline");
    off.hidden = st.mcu.alive;
    if (!st.mcu.alive) off.textContent = `The hub is up but the badge sketch isn't answering (${st.mcu.error || "no reply"}). Start the app from App Lab to flash it.`;
  }

  // ------------------------------------------------------------------- events
  function beep() {
    try {
      S.audio = S.audio || new (window.AudioContext || window.webkitAudioContext)();
      const o = S.audio.createOscillator(), g = S.audio.createGain();
      o.type = "square"; o.frequency.value = 880; g.gain.value = 0.08;
      o.connect(g); g.connect(S.audio.destination);
      o.start(); o.stop(S.audio.currentTime + 0.6);
    } catch (_) { /* audio needs a user gesture first */ }
  }

  function speak(text) {
    if (!$("#speak").checked || !("speechSynthesis" in window)) return;
    speechSynthesis.cancel();
    speechSynthesis.speak(new SpeechSynthesisUtterance(text));
  }

  function handleEvent(e) {
    if (e.type === "alert") {
      $("#sos-title").textContent = e.source === "app" ? "SOS sent" : "SOS from the badge";
      $("#sos-detail").textContent = e.lat != null ? ` – last position ${e.lat.toFixed(5)}, ${e.lon.toFixed(5)}` : " – no position fix";
      const map = $("#sos-map");
      map.hidden = e.lat == null;
      if (e.lat != null) map.href = `https://www.openstreetmap.org/?mlat=${e.lat}&mlon=${e.lon}#map=18/${e.lat}/${e.lon}`;
      $("#sos-banner").hidden = false;
      beep();
    } else if (e.type === "voice") {
      speak(e.text);
    } else if (e.type === "reminder") {
      toast(`Reminder: ${e.text}`);
      speak(e.text);
    } else if (e.type === "arrived") {
      toast(`Arrived: ${e.name}`);
    } else if (e.type === "link") {
      toast(e.mcu ? "Badge is answering again" : "Lost the badge", !e.mcu);
    } else if (e.type === "boot") {
      toast("Badge restarted – saved state restored");
    }
  }

  async function pollEvents(st) {
    if (S.seq === st.event_seq) return;
    const first = S.seq === null;
    const r = await api("GET", `/api/events?after=${first ? 0 : S.seq}`);
    for (const e of r.events) {
      S.events.unshift(e);
      if (!first) handleEvent(e);
    }
    S.events = S.events.slice(0, 100);
    S.seq = r.latest;
    renderEvents();
  }

  // --------------------------------------------------------------------- poll
  let busy = false;
  async function poll() {
    if (busy) return;
    busy = true;
    try {
      const st = await api("GET", "/api/status");
      S.status = st;
      S.online = true;
      $("#keybox").hidden = true;
      render(st);
      await pollEvents(st);
    } catch (e) {
      if (e.message !== "Access key needed") {
        S.online = false;
        renderPills(null);
        const off = $("#offline");
        off.hidden = false;
        off.textContent = `Can't reach the hub at ${location.host}. Retrying…`;
        $("#subtitle").textContent = "offline";
      }
    } finally {
      busy = false;
    }
  }

  // ------------------------------------------------------------------ wiring
  function hold(btn, onDone) {
    const fill = $(".hold-fill", btn), ms = +btn.dataset.hold || 1000;
    let start = 0, raf = 0;
    const tick = () => {
      const p = Math.min(1, (performance.now() - start) / ms);
      fill.style.width = `${p * 100}%`;
      if (p >= 1) { stop(); onDone(); } else raf = requestAnimationFrame(tick);
    };
    const begin = (e) => { e.preventDefault(); start = performance.now(); raf = requestAnimationFrame(tick); };
    const stop = () => { cancelAnimationFrame(raf); fill.style.width = "0"; };
    btn.addEventListener("pointerdown", begin);
    for (const ev of ["pointerup", "pointerleave", "pointercancel"]) btn.addEventListener(ev, stop);
  }

  function markDirty(form) { for (const i of $$("input, select, textarea", form)) i.addEventListener("input", () => S.dirty.add(form.id)); }

  function wire() {
    for (const b of $$("[data-nav]")) b.addEventListener("click", () => act(() => api("POST", "/api/nav", { action: b.dataset.nav })));
    $("#btn-find").addEventListener("click", () => act(() => api("POST", S.status && S.status.badge.finding ? "/api/find/stop" : "/api/find", { seconds: 30 })));
    hold($("#btn-sos"), () => act(() => api("POST", "/api/alert"), "SOS sent"));
    $("#sos-dismiss").addEventListener("click", () => { $("#sos-banner").hidden = true; });

    $("#keyform").addEventListener("submit", (e) => {
      e.preventDefault();
      S.key = $("#keyinput").value.trim();
      localStorage.setItem("badgeKey", S.key);
      poll();
    });

    $("#task-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const input = $("#task-text");
      if (!input.value.trim()) return;
      const r = await act(() => api("POST", "/api/tasks", { text: input.value }), "Task added");
      if (r) { input.value = ""; renderTasks(r.tasks); }
    });
    $("#btn-clear-done").addEventListener("click", () => act(() => api("POST", "/api/tasks/clear_done"), "Cleared"));

    $("#btn-organize").addEventListener("click", async () => {
      const text = $("#org-text").value.trim(), out = $("#org-status");
      if (!text) { out.textContent = "Paste some text first."; return; }
      $("#btn-organize").disabled = true;
      out.textContent = "Working…";
      try {
        let job = await api("POST", "/api/organize", { text, engine: $("#org-engine").value, wait: false });
        while (job.state === "running") {
          out.textContent = `Working… ${Math.round(job.seconds)}s (the on-board AI is slow; rules mode is instant)`;
          await new Promise((r) => setTimeout(r, 1500));
          job = await api("GET", `/api/organize/${job.job}`);
        }
        if (job.state === "done") {
          out.textContent = `Added ${job.added.length} reminder(s) using ${job.engine}${job.list_full ? " – the badge's list is full" : ""}.`;
          $("#org-text").value = "";
        } else {
          out.textContent = job.error || "Nothing extracted.";
        }
      } catch (e) {
        out.textContent = e.message;
      } finally {
        $("#btn-organize").disabled = false;
        poll();
      }
    });

    $("#reminder-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const text = $("#rem-text").value.trim(), when = $("#rem-when").value;
      if (!text || !when) { toast("Enter the text and a time", true); return; }
      const r = await act(() => api("POST", "/api/reminders", { text, at: new Date(when).getTime() / 1000 }), "Reminder scheduled");
      if (r) { $("#rem-text").value = ""; $("#rem-when").value = ""; }
    });

    $("#msg-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const input = $("#msg-text");
      if (!input.value.trim()) return;
      const r = await act(() => api("POST", "/api/messages", { text: input.value, buzz: $("#msg-buzz").checked }), "Sent to the badge");
      if (r) input.value = "";
    });
    $("#btn-clear-msgs").addEventListener("click", () => act(() => api("POST", "/api/messages/clear"), "Inbox cleared"));

    $("#dest-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const r = await act(() => api("POST", "/api/destination", { name: $("#dest-name").value, lat: $("#dest-lat").value, lon: $("#dest-lon").value }), "Destination set");
      if (r) S.dirty.delete("dest-form");
    });
    const here = () => new Promise((ok, no) => (navigator.geolocation ? navigator.geolocation.getCurrentPosition(ok, (e) => no(new Error(e.message || "Location unavailable (browsers need https or localhost)"))) : no(new Error("No geolocation in this browser"))));
    $("#btn-here").addEventListener("click", async () => {
      try { const p = await here(); $("#dest-lat").value = p.coords.latitude.toFixed(6); $("#dest-lon").value = p.coords.longitude.toFixed(6); S.dirty.add("dest-form"); } catch (e) { toast(e.message, true); }
    });
    $("#btn-send-pos").addEventListener("click", async () => {
      try { const p = await here(); await act(() => api("POST", "/api/position", { lat: p.coords.latitude, lon: p.coords.longitude, accuracy: Math.round(p.coords.accuracy) }), "Position sent"); } catch (e) { toast(e.message, true); }
    });

    $("#peer-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const r = await act(() => api("POST", "/api/peers/report", { id: +$("#peer-id").value, name: $("#peer-name").value, lat: $("#peer-lat").value, lon: $("#peer-lon").value }), "Peer reported");
      if (r) S.dirty.delete("peer-form");
    });
    $("#btn-clear-peers").addEventListener("click", () => act(() => api("POST", "/api/peers/clear"), "Peers cleared"));

    let blTimer;
    $("#bl").addEventListener("input", () => {
      S.dirty.add("bl");
      $("#bl-out").textContent = `${Math.round(+$("#bl").value * 100 / 255)}%`;
      clearTimeout(blTimer);
      blTimer = setTimeout(async () => { await act(() => api("POST", "/api/settings", { backlight: +$("#bl").value })); S.dirty.delete("bl"); }, 250);
    });
    $("#haptic").addEventListener("change", () => act(() => api("POST", "/api/settings", { haptic: $("#haptic").checked })));
    $("#peer-range").addEventListener("change", () => act(() => api("POST", "/api/settings", { peer_range_m: +$("#peer-range").value })));
    const tz = $("#tz");
    for (let m = -720; m <= 840; m += 30) {
      const sign = m < 0 ? "-" : "+", a = Math.abs(m);
      tz.append(el("option", { value: String(m), text: `UTC${sign}${String(Math.floor(a / 60)).padStart(2, "0")}:${String(a % 60).padStart(2, "0")}` }));
    }
    tz.addEventListener("change", () => act(() => api("POST", "/api/settings", { tz_offset_min: +tz.value }), "Clock updated"));

    $("#profile-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const r = await act(() => api("POST", "/api/profile", { name: $("#p-name").value, title: $("#p-title").value, org: $("#p-org").value }), "Name tag updated");
      if (r) S.dirty.delete("profile-form");
    });

    for (const f of ["dest-form", "peer-form", "profile-form"]) markDirty($("#" + f));
  }

  wire();
  poll();
  setInterval(poll, 1500);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) poll(); });
})();
