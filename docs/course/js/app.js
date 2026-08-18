/* Build Call Break — single-page app shell. */

var App = (function () {
  var state = { index: 0, mode: "step", docId: null };
  var els = {};

  function init() {
    els.nav = document.getElementById("moduleNav");
    els.docsNav = document.getElementById("docsNav");
    els.title = document.getElementById("stepTitle");
    els.meta = document.getElementById("stepMeta");
    els.crumbs = document.getElementById("crumbs");
    els.content = document.getElementById("content");
    els.prev = document.getElementById("prevBtn");
    els.next = document.getElementById("nextBtn");
    els.status = document.getElementById("pagerStatus");
    els.pager = document.getElementById("pager");
    els.overallFill = document.getElementById("overallFill");
    els.overallNum = document.getElementById("overallNum");

    var saved = loadState();
    state.index = saved ? saved.index : 0;
    if (state.index < 0 || state.index >= COURSE_STEPS.length) state.index = 0;

    els.prev.addEventListener("click", prev);
    els.next.addEventListener("click", next);
    document.getElementById("resetBtn").addEventListener("click", reset);
    initTheme();
    document.addEventListener("keydown", function (e) {
      if (e.target && (e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT")) return;
      if (e.key === "ArrowRight" || e.key === "PageDown") { e.preventDefault(); next(); }
      else if (e.key === "ArrowLeft" || e.key === "PageUp") { e.preventDefault(); prev(); }
    });

    renderSidebar();
    renderView();
  }

  function loadState() {
    try {
      var raw = localStorage.getItem("callbreak_course_pos");
      return raw ? JSON.parse(raw) : null;
    } catch (e) { return null; }
  }
  function saveState() {
    try { localStorage.setItem("callbreak_course_pos", JSON.stringify({ index: state.index })); } catch (e) {}
  }

  /* ---------------- theme ---------------- */
  function initTheme() {
    var btn = document.getElementById("themeBtn");
    var label = document.getElementById("themeLabel");
    var saved = null;
    try { saved = localStorage.getItem("callbreak_course_theme"); } catch (e) {}
    var theme = saved === "light" ? "light" : "dark";
    applyTheme(theme);
    if (btn) btn.addEventListener("click", function () {
      applyTheme(document.body.getAttribute("data-theme") === "light" ? "dark" : "light");
    });
    function applyTheme(t) {
      document.body.setAttribute("data-theme", t);
      try { localStorage.setItem("callbreak_course_theme", t); } catch (e) {}
      if (label) label.textContent = t === "light" ? "Dark" : "Light";
      if (btn) btn.title = t === "light" ? "Switch to dark theme" : "Switch to light theme";
    }
  }

  /* ---------------- sidebar ---------------- */
  function renderSidebar() {
    var html = "";
    COURSE_MODULES.forEach(function (m, mi) {
      var done = m.steps.every(function (s) { return Store.isDone(s.id); });
      var doneCount = m.steps.filter(function (s) { return Store.isDone(s.id); }).length;
      var active = state.mode === "step" && currentModuleIndex() === mi;
      var expanded = active;
      html += '<div class="mod" data-mi="' + mi + '">';
      html += '<button class="mod-head' + (active ? " active" : "") + '" data-toggle="' + mi + '">';
      html += '<span class="mod-icon">' + m.icon + "</span>";
      html += '<span class="mod-title">' + m.title + "<small>" + m.subtitle + "</small></span>";
      html += '<span class="mod-count" style="color:' + (done ? "var(--ok)" : "") + '">' +
              (done ? "✓ " : "") + doneCount + "/" + m.steps.length + "</span>";
      html += "</button>";
      html += '<div class="mod-steps" ' + (expanded ? "" : 'style="display:none"') + ">";
      html += '<div class="mod-steps-inner">';
      m.steps.forEach(function (s) {
        var cur = state.mode === "step" && state.index === s.stepIndex && currentModuleIndex() === mi;
        var cls = ["mod-step"];
        if (Store.isDone(s.id)) cls.push("done");
        if (cur) cls.push("current");
        html += '<button class="' + cls.join(" ") + '" data-go="' + s.id + '">';
        html += '<span class="st-tick">' + (Store.isDone(s.id) ? "✓" : "") + "</span>";
        html += s.title + "</button>";
      });
      html += "</div></div></div>";
    });
    els.nav.innerHTML = html;

    els.nav.querySelectorAll("[data-toggle]").forEach(function (b) {
      b.addEventListener("click", function () {
        var mi = +b.getAttribute("data-toggle");
        var body = els.nav.querySelector('.mod[data-mi="' + mi + '"] .mod-steps');
        var isOpen = body.style.display !== "none";
        body.style.display = isOpen ? "none" : "";
        if (!isOpen) {
          els.nav.querySelectorAll(".mod").forEach(function (m) {
            var other = m.querySelector(".mod-steps");
            var otherMi = +m.getAttribute("data-mi");
            if (otherMi !== mi) other.style.display = "none";
          });
        }
      });
    });
    els.nav.querySelectorAll("[data-go]").forEach(function (b) {
      b.addEventListener("click", function () {
        var id = b.getAttribute("data-go");
        goTo(id);
      });
    });

    renderDocsNav();
  }

  function renderDocsNav() {
    var html = '<div class="docs-label">Reference docs</div>';
    COURSE_DOCS.forEach(function (d) {
      var active = state.mode === "doc" && state.docId === d.id;
      html += '<button class="doc-link' + (active ? " active" : "") + '" data-doc="' + d.id + '" title="' + H.esc(d.subtitle) + '">' +
              '<span class="doc-dot">📄</span><span>' + H.esc(d.title) + "</span></button>";
    });
    els.docsNav.innerHTML = html;
    els.docsNav.querySelectorAll("[data-doc]").forEach(function (b) {
      b.addEventListener("click", function () { openDoc(b.getAttribute("data-doc")); });
    });
  }

  function currentModuleIndex() { return COURSE_STEPS[state.index].moduleIndex; }

  /* ---------------- step rendering ---------------- */
  // Dispatch: a course step or a reference doc.
  function renderView() {
    if (state.mode === "doc") renderDoc(state.docId);
    else renderStep();
  }

  function renderStep() {
    var entry = COURSE_STEPS[state.index];
    var m = entry.module, s = entry.step;
    var done = Store.isDone(s.id);

    els.crumbs.innerHTML = "Module " + (m.moduleIndex + 1) + " of " + COURSE_MODULES.length +
      " · <b>" + m.title + "</b> · Step " + (s.stepIndex + 1) + " of " + m.steps.length;
    els.title.textContent = s.title;
    els.meta.innerHTML =
      '<span class="pill">' + (done ? "Completed" : "In progress") + "</span>" +
      '<span class="pill">' + (s.stepIndex + 1) + "/" + m.steps.length + " in module</span>" +
      '<span class="pill">' + (m.moduleIndex + 1) + "/" + COURSE_MODULES.length + " modules</span>";

    var html = "";
    if (s.stepIndex === 0) html += moduleIntro(m);
    html += renderLearn(s);
    html += renderDo(s);
    html += renderExplain(s);
    html += renderAlternatives(s);
    html += renderImprove(s);
    html += renderRefs(s);
    html += renderActivity(s);
    html += renderDone(s);
    els.content.innerHTML = html;
    buildToc("s" + state.index);
    bindContent();

    els.pager.style.display = "";
    els.prev.disabled = state.index === 0;
    els.next.textContent = state.index === COURSE_STEPS.length - 1 ? "Finish 🏁" : "Next →";
    els.next.classList.add("primary");
    updateStatus(done);
    renderSidebar();
    updateOverall();
    saveState();
    document.getElementById("main").scrollTop = 0;
  }

  /* ---------------- reference docs ---------------- */
  var _docCache = {};

  function findDoc(id) {
    for (var i = 0; i < COURSE_DOCS.length; i++) if (COURSE_DOCS[i].id === id) return COURSE_DOCS[i];
    return null;
  }

  function openDoc(id) {
    var d = findDoc(id);
    if (!d) return;
    state.mode = "doc";
    state.docId = id;
    renderSidebar();
    if (_docCache[id] !== undefined) {
      renderDocHtml(id, _docCache[id]);
      return;
    }
    els.crumbs.innerHTML = "Reference docs · <b>" + H.esc(d.title) + "</b>";
    els.title.textContent = d.title;
    els.meta.innerHTML = '<span class="pill">Markdown reference</span>';
    els.content.innerHTML = '<div class="doc-loading">Loading ' + H.esc(d.title) + "…</div>";
    els.pager.style.display = "none";
    document.getElementById("main").scrollTop = 0;
    if (window.fetch) {
      fetch(d.path).then(function (r) { return r.ok ? r.text() : Promise.reject(); })
        .then(function (txt) { _docCache[id] = txt; renderDocHtml(id, txt); })
        .catch(function () { _docCache[id] = d.fallback || ""; renderDocHtml(id, d.fallback || ""); });
    } else {
      _docCache[id] = d.fallback || "";
      renderDocHtml(id, d.fallback || "");
    }
  }

  function renderDocHtml(id, text) {
    var d = findDoc(id);
    if (!d || state.mode !== "doc" || state.docId !== id) return;
    els.crumbs.innerHTML = "Reference docs · <b>" + H.esc(d.title) + "</b>";
    els.title.textContent = d.title;
    els.meta.innerHTML = '<span class="pill">Markdown reference</span>';
    els.content.innerHTML =
      '<div class="doc-bar">' +
      '<button class="btn" id="backToCourse">← Back to the course</button>' +
      '<span class="doc-path">' + H.esc(d.path) + "</span></div>" +
      '<article class="doc-reader">' + Md.render(text) + "</article>";
    var back = document.getElementById("backToCourse");
    if (back) back.addEventListener("click", backToCourse);
    buildToc("d" + id, true);
    bindContent();
    document.getElementById("main").scrollTop = 0;
  }

  function backToCourse() {
    state.mode = "step";
    renderView();
  }

  function moduleIntro(m) {
    return '<div class="mod-intro"><h2>' + m.title + "</h2><p>" + m.subtitle + "</p></div>";
  }

  function renderLearn(s) {
    return renderBlocks(s.learn || []);
  }

  // Generic block renderer shared by learn / do / explain.
  function renderBlocks(blocks) {
    var html = "";
    var inUl = false;
    (blocks || []).forEach(function (block) {
      if (block.b) {
        if (!inUl) { html += "<ul>"; inUl = true; }
        html += "<li>" + inline(block.b) + "</li>";
      } else {
        if (inUl) { html += "</ul>"; inUl = false; }
        if (block.p) html += "<p>" + inline(block.p) + "</p>";
        else if (block.h) html += "<h2>" + block.h + "</h2>";
        else if (block.callout) html += '<div class="callout' + (block.kind ? " " + block.kind : "") + '">' + inline(block.callout) + "</div>";
        else if (block.code) html += H.codeBlock(block.code, block.lang, block.title);
      }
    });
    if (inUl) html += "</ul>";
    return html;
  }

  // "start with this, then this, then this" — numbered build actions.
  function renderDo(s) {
    if (!s.do || !s.do.length) return "";
    var html = '<h2>Build it — step by step</h2>';
    html += '<div class="do-list">';
    var n = 0;
    (s.do || []).forEach(function (block) {
      if (block.code) { html += "</div>" + H.codeBlock(block.code, block.lang, block.title) + '<div class="do-list">'; return; }
      n++;
      if (block.p) html += '<div class="do-item"><span class="do-num">' + n + "</span><div>" + inline(block.p) + "</div></div>";
      else if (block.b) html += '<div class="do-item"><span class="do-num">' + n + "</span><div>" + inline(block.b) + "</div></div>";
      else if (block.h) html += '<div class="do-sec">' + block.h + "</div>";
      else if (block.callout) html += '<div class="callout' + (block.kind ? " " + block.kind : "") + '">' + inline(block.callout) + "</div>";
    });
    html += "</div>";
    return html;
  }

  function renderExplain(s) {
    if (!s.explain || !s.explain.length) return "";
    return '<h2>Code walkthrough</h2>' + renderBlocks(s.explain);
  }

  function renderAlternatives(s) {
    if (!s.alternatives || !s.alternatives.length) return "";
    var html = '<h2>Alternative approaches</h2>';
    html += '<div class="alt-wrap">';
    (s.alternatives || []).forEach(function (a) {
      html += '<div class="alt"><div class="alt-title">⇄ ' + inline(a.title) + "</div>";
      html += '<div class="alt-text">' + inline(a.text) + "</div>";
      if (a.code) html += H.codeBlock(a.code, a.lang || "dart", a.title);
      html += "</div>";
    });
    return html + "</div>";
  }

  function renderImprove(s) {
    if (!s.improve || !s.improve.length) return "";
    var html = '<h2>Improve it yourself</h2>';
    html += '<div class="imp-wrap">';
    (s.improve || []).forEach(function (im) {
      html += '<div class="imp"><span class="imp-mark">➤</span><div><b>' + inline(im.title) + "</b><div>" + inline(im.text) + "</div></div></div>";
    });
    return html + "</div>";
  }

  // wrap any existing <li> runs in <ul>. Simple approach: collect bullets.
  function inline(t) {
    return t.replace(/`([^`]+)`/g, function (_, c) { return "<code>" + H.esc(c) + "</code>"; });
  }

  function renderRefs(s) {
    if (!s.refs || !s.refs.length) return "";
    var html = '<h2>Reference (answer key)</h2><p>Build first, peek after.</p><div>';
    s.refs.forEach(function (f) { html += '<span class="file-chip">' + H.esc(f) + "</span>"; });
    return html + "</div>";
  }

  function renderDone(s) {
    if (!s.done || !s.done.length) return "";
    var html = '<div class="done-box"><h3>Definition of done</h3><ul>';
    s.done.forEach(function (d) { html += "<li>" + inline(d) + "</li>"; });
    return html + "</ul></div>";
  }

  function renderActivity(s) {
    if (!s.activity) return "";
    var a = s.activity;
    a._stepId = s.id;
    if (a.quiz) a.quiz._stepId = s.id;
    if (a.code) a.code._stepId = s.id;
    var html = '<div class="activity" data-step="' + s.id + '">';
    html += '<div class="activity-head">✦ ' + activityTitle(a) + "</div>";
    html += '<div class="activity-body">';
    if (a.type === "quiz" || a.type === "both") html += quizHtml(a.quiz || a);
    if (a.type === "code" || a.type === "both") html += codeHtml(a.code || a);
    html += "</div></div>";
    return html;
  }

  function activityTitle(a) {
    switch (a.type) {
      case "quiz": return "Check understanding";
      case "code": return "Write it yourself";
      case "both": return "Check understanding + write it yourself";
    }
  }

  function quizHtml(q) {
    var letters = ["A", "B", "C", "D", "E"];
    var html = '<div class="quiz" data-step="' + (q._stepId || "") + '">';
    html += '<div class="quiz-q">' + inline(q.q) + "</div>";
    html += '<div class="quiz-opts">';
    q.opts.forEach(function (o, i) {
      html += '<button class="quiz-opt" data-i="' + i + '" data-correct="' + (i === q.correct) + '">' +
              '<span class="qp">' + letters[i] + ".</span>" + inline(o) + "</button>";
    });
    html += "</div>";
    html += '<div class="quiz-feedback"></div>';
    return html + "</div>";
  }

  function codeHtml(c) {
    var starter = c.starter || "";
    var html = '<div class="cc" data-step="' + (c._stepId || "") + '">';
    html += '<textarea class="cc-editor" spellcheck="false" placeholder="Type or paste your implementation here…">' +
            H.esc(starter) + "</textarea>";
    html += '<div class="cc-toolbar"><button class="check-btn">Run check</button>' +
            '<span style="font-size:12px;color:var(--faint)">' + (c.checks.length) + " checks</span></div>";
    html += '<div class="cc-result"></div>';
    return html + "</div>";
  }

  /* ---------------- binding ---------------- */
  // Assign anchors to section headings and render a clickable chip nav.
  // includeH3 also chips h3 headings — used for reference docs, whose phase
  // structure lives at h3; steps stay h2-only so the nav isn't noisy.
  function buildToc(prefix, includeH3) {
    var heads = els.content.querySelectorAll("h2" + (includeH3 ? ", h3" : ""));
    if (!heads.length) return;
    var chips = "";
    heads.forEach(function (h, i) {
      var id = (prefix || "sec") + "_" + i;
      h.id = id;
      chips += '<button class="toc-chip' + (h.tagName === "H3" ? " toc-chip-sub" : "") + '" data-sec="' + id + '">' + H.esc(h.textContent) + "</button>";
    });
    var nav = document.createElement("div");
    nav.className = "toc-nav";
    nav.innerHTML = chips;
    els.content.insertBefore(nav, els.content.firstChild);

    els.content.querySelectorAll(".toc-chip").forEach(function (c) {
      c.addEventListener("click", function () {
        document.getElementById(c.getAttribute("data-sec")).scrollIntoView({ behavior: "smooth", block: "start" });
      });
    });
  }

  function bindContent() {
    // copy buttons
    els.content.querySelectorAll(".copy-btn").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var src = btn.getAttribute("data-copy");
        navigator.clipboard && navigator.clipboard.writeText(src).then(function () {
          btn.textContent = "Copied ✓";
          btn.classList.add("copied");
          setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1500);
        });
      });
    });

    // quizzes
    els.content.querySelectorAll(".quiz").forEach(function (q) {
      var stepId = q.getAttribute("data-step");
      var opts = q.querySelectorAll(".quiz-opt");
      var fb = q.querySelector(".quiz-feedback");
      var answered = false;
      opts.forEach(function (o) {
        o.addEventListener("click", function () {
          if (answered) return;
          answered = true;
          var correct = o.getAttribute("data-correct") === "true";
          o.classList.add(correct ? "correct" : "wrong");
          if (!correct) {
            opts.forEach(function (x) { if (x.getAttribute("data-correct") === "true") x.classList.add("correct"); });
          }
          fb.classList.add("show");
          if (correct) {
            fb.className = "quiz-feedback show good";
            fb.textContent = q.getAttribute("data-explain") || "Correct. Step unlocked.";
            markDone(stepId);
            Toast.show("Correct ✓");
          } else {
            fb.className = "quiz-feedback show bad";
            fb.textContent = "Not quite — " + (q.getAttribute("data-hint") || "try the other answers.");
          }
        });
      });
      if (q.hasAttribute("data-explain")) fb.setAttribute("data-orig-explain", q.getAttribute("data-explain"));
    });

    // code checks
    els.content.querySelectorAll(".cc").forEach(function (box) {
      var stepId = box.getAttribute("data-step");
      var editor = box.querySelector(".cc-editor");
      var runBtn = box.querySelector(".check-btn");
      var result = box.querySelector(".cc-result");
      runBtn.addEventListener("click", function () {
        var checks = stepChecks(stepId);
        var src = editor.value;
        var results = Checker.run(src, checks);
        var allPass = results.every(function (r) { return r.pass; });
        var html = "";
        results.forEach(function (r) {
          var mark = r.pass ? "✓" : "✗";
          var cls = r.pass ? "pass" : "fail";
          html += '<div class="assert ' + cls + '"><span class="a-mark">' + mark + "</span>" +
                  "<span>" + H.esc(r.check.name) + " <em>(" + r.count + " found)</em>" +
                  (r.pass ? "" : '<span class="a-hint">' + H.esc(r.check.hint || "Look at the assertion pattern.") + "</span>") +
                  "</span></div>";
        });
        if (allPass) {
          html += '<div class="cc-pass-banner">All checks pass. Step unlocked. 🎉</div>';
          markDone(stepId);
        }
        result.innerHTML = html;
      });
    });
  }

  function stepChecks(stepId) {
    var entry = COURSE_MODULE_OF[stepId];
    var a = entry.module.steps[entry.stepIndex].activity;
    if (!a) return [];
    var c = a.type === "code" ? a : (a.code || { checks: [] });
    return c.checks || [];
  }

  /* ---------------- progress ---------------- */
  function markDone(stepId) {
    if (Store.isDone(stepId)) return;
    Store.setDone(stepId, true);
    renderSidebar();
    updateOverall();
    updateStatus(true);
    var pill = els.meta.querySelector(".pill");
    if (pill) { pill.textContent = "Completed"; pill.classList.add("done"); }
    Toast.show("Step completed ✓");
  }

  function updateStatus(done) {
    els.status.innerHTML = done
      ? "Completed ✓"
      : '<span class="locked">Complete the activity to unlock the next step.</span>';
  }

  function updateOverall() {
    var total = COURSE_STEPS.length;
    var done = COURSE_STEPS.filter(function (e) { return Store.isDone(e.step.id); }).length;
    var pct = Math.round((done / total) * 100);
    els.overallFill.style.width = pct + "%";
    els.overallNum.textContent = pct + "% (" + done + "/" + total + ")";
  }

  /* ---------------- navigation ---------------- */
  function next() {
    if (state.mode === "doc") { backToCourse(); return; }
    if (state.index < COURSE_STEPS.length - 1) { state.index++; renderStep(); }
    else {
      var all = COURSE_STEPS.every(function (e) { return Store.isDone(e.step.id); });
      Toast.show(all ? "You built the whole game. Go deploy it. 🏆" : "Finish all steps to complete the course.");
    }
  }
  function prev() {
    if (state.mode === "doc") { backToCourse(); return; }
    if (state.index > 0) { state.index--; renderStep(); }
  }
  function goTo(id) {
    state.mode = "step";
    var loc = COURSE_MODULE_OF[id];
    if (!loc) return;
    state.index = loc.index;
    renderStep();
  }
  function reset() {
    if (confirm("Reset ALL course progress? This cannot be undone.")) {
      Store.reset();
      try { localStorage.removeItem("callbreak_course_pos"); } catch (e) {}
      state.mode = "step";
      state.index = 0;
      renderStep();
    }
  }

  return { init: init };
})();

window.addEventListener("DOMContentLoaded", function () { App.init(); });
