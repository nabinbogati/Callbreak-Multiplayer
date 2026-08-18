/* Build Call Break — core engine. No dependencies, plain script globals. */

/* ---------------- syntax highlighter ---------------- */
var H = (function () {
  var LANG = {
    dart: {
      kw: "abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for get hide if implements import in interface is late library mixin new null of on operator part required rethrow return sealed set show static super switch sync this throw true try typedef var void when while with yield",
      types: "String int double num bool List Map Set Iterable Object dynamic Function Record Never void",
      str: /'[^'\n]*'|"[^"\n]*"|`[^`\n]*`/,
      com: /\/\/[^\n]*|\/\*[\s\S]*?\*\//,
      num: /\b\d+(\.\d+)?\b/,
      fn: /[A-Za-z_$][\w$]*(?=\s*\()/,
      op: /[+\-*/%=!<>&|^~?:]+/
    },
    go: {
      kw: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr true false nil iota make new len cap append copy delete panic recover close",
      types: "",
      str: /"(?:[^"\\]|\\.)*"|`[^`]*`|'(?:[^'\\]|\\.)'/,
      com: /\/\/[^\n]*|\/\*[\s\S]*?\*\//,
      num: /\b\d+(\.\d+)?\b/,
      fn: /[A-Za-z_$][\w$]*(?=\s*\()/,
      op: /[+\-*/%=!<>&|^~?:]+/
    },
    shell: {
      kw: "make run test build cd ls cp mkdir rm export source sudo docker go flutter dart npm pub",
      types: "",
      str: /"[^"\n]*"|'[^'\n]*'/,
      com: /#[^\n]*/,
      num: /(?<!\w)\d+(?!\w)/,
      fn: /^[A-Za-z_.\/\-]+/,
      op: /[|&;]+/
    }
  };

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // Tokenise by walking the string; strings and comments win over keywords.
  function highlight(src, lang) {
    var def = LANG[lang] || LANG.dart;
    var out = "";
    var i = 0;
    var word = /^[A-Za-z_][\w$]*/;
    var line = /^[^\n]*/;

    function kwClass(word) {
      var kws = def.kw.split(" ");
      if (kws.indexOf(word) !== -1) return "tok-kw";
      if (def.types && def.types.split(" ").indexOf(word) !== -1) return "tok-type";
      return null;
    }

    while (i < src.length) {
      var rest = src.slice(i);
      var m = def.com.exec(rest);
      if (m && m.index === 0) {
        out += '<span class="tok-com">' + esc(m[0]) + "</span>";
        i += m[0].length;
        continue;
      }
      m = def.str.exec(rest);
      if (m && m.index === 0) {
        out += '<span class="tok-str">' + esc(m[0]) + "</span>";
        i += m[0].length;
        continue;
      }
      var c = src[i];
      if (/\s/.test(c)) { out += c; i++; continue; }
      var w = word.exec(rest);
      if (w && w.index === 0) {
        var cls = kwClass(w[0]);
        if (cls) { out += '<span class="' + cls + '">' + w[0] + "</span>"; i += w[0].length; continue; }
        var fn = def.fn.exec(rest);
        if (fn && fn.index === 0) { out += '<span class="tok-fn">' + esc(fn[0]) + "</span>"; i += fn[0].length; continue; }
        out += esc(w[0]); i += w[0].length; continue;
      }
      var n = def.num.exec(rest);
      if (n && n.index === 0) { out += '<span class="tok-num">' + n[0] + "</span>"; i += n[0].length; continue; }
      var o = def.op.exec(rest);
      if (o && o.index === 0 && o[0].length) { out += '<span class="tok-op">' + esc(o[0]) + "</span>"; i += o[0].length; continue; }
      out += esc(c); i++;
    }
    return out;
  }

  function renderCodeBlock(src, lang, title) {
    lang = lang || "dart";
    var t = title ? title : lang;
    return (
      '<div class="codeblock">' +
      '<div class="codeblock-head"><span class="cb-lang">' + t + "</span>" +
      '<button class="copy-btn" data-copy="' + esc(src).replace(/"/g, "&quot;") + '">Copy</button></div>' +
      "<pre><code>" + highlight(src, lang) + "</code></pre></div>"
    );
  }

  return { highlight: highlight, codeBlock: renderCodeBlock, esc: esc };
})();

/* ---------------- curriculum model ---------------- */
// A module: { id, icon, title, subtitle, steps: [step...] }
// A step:   { id, title, learn: [block...], do: [block...], explain: [block...],
//             alternatives: [{title,text,code?,lang?}], improve: [{title,text}],
//             activity: {type:'quiz'|'code'|'both', ...}, done: [string...],
//             refs: [string...] }
// Block forms:
//   { p: "paragraph" }
//   { b: "bullet" }
//   { h: "heading" }
//   { callout: "text", kind: "warn"|"ok"|"" }
//   { code: "src", lang: "dart", title: "..." }   (inline in learn flow)
var C = (function () {
  function p(text) { return { p: text }; }
  function b(text) { return { b: text }; }
  function h(text) { return { h: text }; }
  function callout(text, kind) { return { callout: text, kind: kind || "" }; }
  function code(src, lang, title) { return { code: src, lang: lang || "dart", title: title }; }
  function step(id, title, def) { def.id = id; def.title = title; return def; }
  function module(id, icon, title, subtitle, steps) {
    return { id: id, icon: icon, title: title, subtitle: subtitle, steps: steps };
  }
  return { p: p, b: b, h: h, callout: callout, code: code, step: step, module: module };
})();

/* checker assertion builders */
var CHK = {
  has: function (name, pattern, hint) { return { type: "has", name: name, pattern: pattern, hint: hint }; },
  lacks: function (name, pattern, hint) { return { type: "lacks", name: name, pattern: pattern, hint: hint }; },
  count: function (name, pattern, min, hint) { return { type: "count", name: name, pattern: pattern, min: min, hint: hint }; }
};

/* ---------------- checker engine ---------------- */
var Checker = {
  run: function (src, checks) {
    var results = [];
    for (var i = 0; i < checks.length; i++) {
      var c = checks[i];
      var re = new RegExp(c.pattern, "m");
      var matches = src.match(new RegExp(c.pattern, "gm")) || [];
      var pass = false;
      switch (c.type) {
        case "has": pass = re.test(src); break;
        case "lacks": pass = !re.test(src); break;
        case "count": pass = matches.length >= c.min; break;
      }
      results.push({ check: c, pass: pass, count: matches.length });
    }
    return results;
  }
};

/* ---------------- progress store ---------------- */
var Store = {
  KEY: "callbreak_course_v1",
  load: function () {
    try {
      var raw = localStorage.getItem(Store.KEY);
      return raw ? JSON.parse(raw) : { completed: {} };
    } catch (e) { return { completed: {} }; }
  },
  save: function (data) { try { localStorage.setItem(Store.KEY, JSON.stringify(data)); } catch (e) {} },
  isDone: function (stepId) { return !!Store.load().completed[stepId]; },
  setDone: function (stepId, done) {
    var d = Store.load();
    if (done) d.completed[stepId] = true; else delete d.completed[stepId];
    Store.save(d);
  },
  reset: function () {
    try { localStorage.removeItem(Store.KEY); } catch (e) {}
  }
};

/* ---------------- tiny toast ---------------- */
var Toast = {
  _t: null,
  show: function (msg, ms) {
    var el = document.getElementById("toast");
    el.textContent = msg;
    el.classList.add("show");
    clearTimeout(Toast._t);
    Toast._t = setTimeout(function () { el.classList.remove("show"); }, ms || 2600);
  }
};
