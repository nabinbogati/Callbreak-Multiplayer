/* Build Call Break — minimal markdown renderer. Zero dependencies.
   Handles what the repo's docs use: headings, code fences (with the course
   syntax highlighter), tables, lists, blockquotes, hr, inline code/bold/
   italic/links. Trusted local docs, but all non-code text is HTML-escaped
   before inline transforms. */

var Md = (function () {
  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // Operates on already-escaped text.
  function inline(s) {
    s = s.replace(/`([^`]+)`/g, function (_, c) { return "<code>" + c + "</code>"; });
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/\*([^*]+)\*/g, "<em>$1</em>");
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
    return s;
  }

  function splitCells(row) {
    return row
      .trim()
      .replace(/^\||\|$/g, "")
      .replace(/\\\|/g, "\u0000")
      .split("|")
      .map(function (c) { return c.replace(/\u0000/g, "|").trim(); });
  }

  function renderList(lines, start) {
    var ordered = /^\s*\d+\.\s+/.test(lines[start]);
    var tag = ordered ? "ol" : "ul";
    var html = "<" + tag + ">";
    var i = start;
    while (i < lines.length) {
      var m = /^(\s*)(?:[-*+]\s+|\d+\.\s+)(.*)$/.exec(lines[i]);
      if (!m) break;
      html += "<li>" + inline(esc(m[2])) + "</li>";
      i++;
    }
    return { html: html + "</" + tag + ">", next: i };
  }

  function isTableRow(line) { return line.indexOf("|") !== -1; }
  function isTableSep(line) {
    return isTableRow(line) && line.indexOf("-") !== -1 && /^\s*\|?[\s:|-]+\|?\s*$/.test(line);
  }

  function render(text) {
    var lines = text.split(/\r?\n/);
    var out = [];
    var i = 0;

    while (i < lines.length) {
      var line = lines[i];
      if (line.trim() === "") { i++; continue; }

      // fenced code block
      var fm = /^```(\w*)\s*$/.exec(line);
      if (fm) {
        var lang = fm[1] || "text";
        var buf = [];
        i++;
        while (i < lines.length && !/^```/.test(lines[i])) { buf.push(lines[i]); i++; }
        i++; // skip the closing fence
        out.push(H.codeBlock(buf.join("\n"), lang, lang === "text" ? "text" : lang));
        continue;
      }

      // heading — bump one level: doc h1 renders as the app's h2, etc.
      var hm = /^(#{1,6})\s+(.*)$/.exec(line);
      if (hm) {
        var level = Math.min(hm[1].length + 1, 6);
        out.push("<h" + level + ">" + inline(esc(hm[2])) + "</h" + level + ">");
        i++;
        continue;
      }

      // horizontal rule
      if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) { out.push("<hr>"); i++; continue; }

      // blockquote
      if (/^>\s?/.test(line)) {
        var bq = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) { bq.push(lines[i].replace(/^>\s?/, "")); i++; }
        out.push("<blockquote>" + render(bq.join("\n")) + "</blockquote>");
        continue;
      }

      // table
      if (isTableRow(line) && i + 1 < lines.length && isTableSep(lines[i + 1])) {
        var rows = [splitCells(line)];
        i += 2; // skip header + separator
        while (i < lines.length && isTableRow(lines[i]) && lines[i].trim() !== "") {
          rows.push(splitCells(lines[i]));
          i++;
        }
        var th = "<div class=\"md-table\"><table>";
        rows.forEach(function (r, ri) {
          var tag = ri === 0 ? "th" : "td";
          th += "<tr>" + r.map(function (c) { return "<" + tag + ">" + inline(esc(c)) + "</" + tag + ">"; }).join("") + "</tr>";
        });
        out.push(th + "</table></div>");
        continue;
      }

      // list
      if (/^\s*[-*+]\s+/.test(line) || /^\s*\d+\.\s+/.test(line)) {
        var lst = renderList(lines, i);
        out.push(lst.html);
        i = lst.next;
        continue;
      }

      // paragraph — gather until a blank line or another block start
      var para = [];
      while (i < lines.length) {
        var l = lines[i];
        if (l.trim() === "") break;
        if (/^#{1,6}\s+/.test(l) || /^```/.test(l) || /^>\s?/.test(l)) break;
        if (/^\s*[-*+]\s+/.test(l) || /^\s*\d+\.\s+/.test(l)) break;
        if (isTableRow(l) && i + 1 < lines.length && isTableSep(lines[i + 1])) break;
        if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(l)) break;
        para.push(l);
        i++;
      }
      out.push("<p>" + para.map(function (p) { return inline(esc(p)); }).join(" ") + "</p>");
    }
    return out.join("\n");
  }

  return { render: render, esc: esc };
})();
