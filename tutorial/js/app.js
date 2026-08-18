/* Sidebar nav, progress tracker, mark-complete wiring. No build step, no deps. */

var NAV = [
  { id: "overview", title: "Overview & Architecture", href: "index.html", group: "Start here" },

  { id: "m01", title: "1. Cards & Rules", href: "modules/01-cards-and-rules.html", group: "Part I — Flutter engine (pure Dart)" },
  { id: "m02", title: "2. Game State Machine", href: "modules/02-game-engine.html", group: "Part I — Flutter engine (pure Dart)" },
  { id: "m03", title: "3. Bot Opponent", href: "modules/03-bot.html", group: "Part I — Flutter engine (pure Dart)" },

  { id: "m04", title: "4. App Wiring & Design Tokens", href: "modules/04-app-wiring.html", group: "Part II — Flutter app" },
  { id: "m05", title: "5. Sessions & Offline Play", href: "modules/05-session-offline.html", group: "Part II — Flutter app" },
  { id: "m06", title: "6. Core Table UI", href: "modules/06-core-ui.html", group: "Part II — Flutter app" },
  { id: "m07", title: "7. Persistent App State", href: "modules/07-app-state.html", group: "Part II — Flutter app" },
  { id: "m08", title: "8. Audio", href: "modules/08-audio.html", group: "Part II — Flutter app" },
  { id: "m09", title: "9. Going Online: RemoteSession, REST & Uploads", href: "modules/09-rest-upload.html", group: "Part II — Flutter app" },
  { id: "m10", title: "10. LAN Multiplayer", href: "modules/10-lan.html", group: "Part II — Flutter app" },

  { id: "m11", title: "11. Go Backend Foundations", href: "modules/11-go-foundations.html", group: "Part III — Go backend" },
  { id: "m12", title: "12. Engine Port to Go", href: "modules/12-go-engine-port.html", group: "Part III — Go backend" },
  { id: "m13", title: "13. Room Actor & Matchmaking", href: "modules/13-room-match.html", group: "Part III — Go backend" },
  { id: "m14", title: "14. WebSocket Edge", href: "modules/14-websocket-edge.html", group: "Part III — Go backend" },
  { id: "m15", title: "15. Auth & Guest Identity", href: "modules/15-auth.html", group: "Part III — Go backend" },
  { id: "m16", title: "16. Persistence (Postgres & Redis)", href: "modules/16-persistence.html", group: "Part III — Go backend" },
  { id: "m17", title: "17. REST API & Admin Dashboard", href: "modules/17-rest-admin.html", group: "Part III — Go backend" },
  { id: "m18", title: "18. Observability, Scaling & Deploy", href: "modules/18-observability-scaling.html", group: "Part III — Go backend" },

  { id: "m19", title: "19. Build It Yourself", href: "modules/19-build-it-yourself.html", group: "Part IV — Finish" },
  { id: "m20", title: "20. Roadmap: Prototype → Production", href: "modules/20-roadmap.html", group: "Part IV — Finish" },
  { id: "glossary", title: "Glossary", href: "glossary.html", group: "Part IV — Finish" }
];

var STORAGE_KEY = "cb-tutorial-progress-v1";

function loadProgress() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
  } catch (e) {
    return {};
  }
}

function saveProgress(p) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(p));
}

function base() {
  return typeof TUT_BASE !== "undefined" ? TUT_BASE : "./";
}

function buildSidebar() {
  var sidebar = document.getElementById("sidebar");
  if (!sidebar) return;

  var progress = loadProgress();
  var trackable = NAV.filter(function (n) { return n.id.indexOf("m") === 0; });
  var done = trackable.filter(function (n) { return progress[n.id]; }).length;
  var pct = trackable.length ? Math.round((done / trackable.length) * 100) : 0;

  var html = "";
  html += '<div class="sidebar-brand">Build Call Break</div>';
  html += '<div class="sidebar-sub">A hands-on rebuild course — Flutter + Go</div>';
  html += '<div class="progress-wrap">';
  html += '<div class="progress-track"><div class="progress-fill" style="width:' + pct + '%"></div></div>';
  html += '<div class="progress-label">' + done + ' / ' + trackable.length + ' modules complete (' + pct + '%)</div>';
  html += '</div>';

  var currentGroup = null;
  var currentPage = document.body.getAttribute("data-page");

  html += '<ul class="nav-list">';
  NAV.forEach(function (item) {
    if (item.group !== currentGroup) {
      currentGroup = item.group;
      html += '<li class="nav-group-label">' + currentGroup + "</li>";
    }
    var isDone = !!progress[item.id];
    var isActive = item.id === currentPage;
    var num = item.id.indexOf("m") === 0 ? item.id.replace("m", "") : "";
    html +=
      '<li class="nav-item' + (isActive ? " active" : "") + '">' +
      '<a href="' + base() + item.href + '">' +
      '<span class="nav-check' + (isDone ? " done" : "") + '" data-nav-check="' + item.id + '">' + (isDone ? "✓" : "") + "</span>" +
      (num ? '<span class="num">' + num + "</span>" : "") +
      "<span>" + item.title + "</span>" +
      "</a></li>";
  });
  html += "</ul>";

  sidebar.innerHTML = html;

  sidebar.querySelectorAll("[data-nav-check]").forEach(function (el) {
    el.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      var id = el.getAttribute("data-nav-check");
      var p = loadProgress();
      p[id] = !p[id];
      saveProgress(p);
      buildSidebar();
      syncMarkCompleteButton();
    });
  });
}

function syncMarkCompleteButton() {
  var btn = document.getElementById("mark-complete-btn");
  if (!btn) return;
  var id = document.body.getAttribute("data-page");
  var progress = loadProgress();
  var isDone = !!progress[id];
  btn.textContent = isDone ? "✓ Module marked complete" : "Mark this module complete";
  btn.classList.toggle("done", isDone);
}

function wireMarkComplete() {
  var btn = document.getElementById("mark-complete-btn");
  if (!btn) return;
  btn.addEventListener("click", function () {
    var id = document.body.getAttribute("data-page");
    var p = loadProgress();
    p[id] = !p[id];
    saveProgress(p);
    buildSidebar();
    syncMarkCompleteButton();
  });
  syncMarkCompleteButton();
}

/* Generic persistence for any .checklist on the page (module 19's build-it-
   yourself tracks). Each checkbox needs a stable data-check-id; state is
   stored under its own localStorage key, separate from module progress. */
var CHECKLIST_KEY = "cb-tutorial-checklist-v1";

function loadChecklist() {
  try {
    return JSON.parse(localStorage.getItem(CHECKLIST_KEY) || "{}");
  } catch (e) {
    return {};
  }
}

function saveChecklist(c) {
  localStorage.setItem(CHECKLIST_KEY, JSON.stringify(c));
}

function wireChecklists() {
  var boxes = document.querySelectorAll(".checklist input[type=checkbox]");
  if (!boxes.length) return;
  var state = loadChecklist();
  boxes.forEach(function (box) {
    var id = box.getAttribute("data-check-id");
    if (!id) return;
    box.checked = !!state[id];
    box.addEventListener("change", function () {
      var s = loadChecklist();
      s[id] = box.checked;
      saveChecklist(s);
    });
  });
}

document.addEventListener("DOMContentLoaded", function () {
  buildSidebar();
  wireMarkComplete();
  wireChecklists();
});
