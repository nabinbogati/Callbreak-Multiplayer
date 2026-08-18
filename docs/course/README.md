# Build Call Break — Interactive Course

A zero-dependency, offline-first interactive course that teaches you to build the
entire Call Break project — Flutter frontend, Go backend, and shipping — step by
step. Complete every step and you have the whole project built yourself.

## Run it

Open `index.html` in any modern browser. That's it — no server, no `npm install`,
no build step.

```bash
# or, if you prefer a URL:
python3 -m http.server 8000 -d docs/course
# then open http://localhost:8000
```

Progress is saved in your browser's `localStorage` — closing the tab and coming
back picks up where you left off. A "Reset" button is in the sidebar. A
**theme toggle** (moon icon in the sidebar) switches between the dark felt theme
and a warm-paper light theme; your choice persists across reloads. The real app
fonts (PlusJakartaSans + Cinzel) are bundled, so the course reads the way the
game looks.

## Reference docs

The **Reference docs** section of the sidebar renders the repo's markdown files
in-app — no raw-text tabs:

- **Roadmap** (`docs/ROADMAP.md`) — the written build plan
- **Concept Map** (`docs/CONCEPT_MAP.md`) — backend → Flutter translation
- **Course README** (`docs/course/README.md`)
- **Backend README** (`backend/README.md`)
- **Wire Protocol** (`backend/PROTOCOL.md`)
- **REST API** (`backend/docs/API.md`)
- **Persistence** (`backend/docs/PERSISTENCE.md`)

When served over http the app fetches the live files; when opened via `file://`
(where `fetch` is blocked) it falls back to bundled copies in `js/docs.js`.
If you edit any of those markdown files, regenerate the bundle:

```bash
# from the repo root — rewrites docs/course/js/docs.js
python3 - <<'PY'
import json
specs = {
  "roadmap": ("docs/ROADMAP.md", "ROADMAP.md"),
  # ...same ids/paths as the docs.js header describes
}
entries = [{"id": i, "title": t, "path": p, "fallback": open(s).read()}
           for i, (t, s, p) in specs.items()]
open("docs/course/js/docs.js", "w").write("var COURSE_DOCS = " + json.dumps(entries) + ";")
PY
```

## How it works

- **17 modules, 86 steps.** Setup → Dart → game engine → UI → table vs bots →
  state/audio → REST → WebSockets → LAN host → upload queue → **Go backend core**
  → **API & protocol design** → **database design** → **Redis / pub-sub /
  scaling** → **monitoring, metrics & ops** → deploy → **the complete inventory**
  (every file mapped to the step that builds it, the remaining widgets, the full
  test suite, and a project-wide final checklist). Every backend decision step
  answers *"why this, not that"* (REST vs GraphQL, numeric vs float, surrogate
  keys, Redis advisory-not-authoritative, actor inbox vs pub/sub, metrics worth
  alerting on, and more). Nothing in the project is left to discover — module 16
  is the completeness guarantee.
- Each step is a **full tutorial**, not a paragraph:
  - **Learn** — the concept, with backend analogies.
  - **Build it — step by step** — the ordered "start with this, then this, then
    this" coding instructions with real code.
  - **Code walkthrough** — line-by-line explanation of the key code.
  - **Alternative approaches** — 2+ better/different ways to do the same thing
    (codegen, packages, protocols), so you know what the 'production' version
    looks like.
  - **Improve it yourself** — concrete future recommendations per step.
  - **Definition of done** + **reference files** (the real repo files — peek
    *after* you've tried yourself).
- **Activities verify you, not the other way round:**
  - **Quizzes** — one question per concept; correct answers unlock the step.
  - **Write-it-yourself boxes** — type/paste your implementation, hit *Run
    check*, and the step's assertions check the structure of your code (not an
    exact match). Pass them all to unlock the step.
- Steps are **locked until you complete the previous one's activity**, so the
  course enforces the build order.

## Files

```
docs/course/
  index.html          the shell
  css/style.css       dark felt + gold theme (yes, like the app)
  fonts/              the real PlusJakartaSans + Cinzel, bundled
  js/core.js          syntax highlighter, checker engine, progress store
  js/md.js            minimal markdown renderer for the reference docs
  js/docs.js          the reference-docs registry + file:// fallbacks
  js/curriculum.js    module registration
  js/modules-0to3.js  setup, Dart, engine, static UI
  js/modules-4to7.js  table vs bots, state/audio, REST, WebSockets
  js/modules-8to10.js LAN host, upload queue, Go backend core
  js/modules-11to14.js API/protocol, database, Redis/pub-sub/scaling, monitoring/ops
  js/modules-15.js    shipping (stores + deploy)
  js/modules-16.js    the complete inventory: every file mapped, final checklist
  js/app.js           SPA: sidebar, step rendering, activities, section nav, theme
```

## Editing content

Each step is a plain JS object in a `modules-*.js` file. The shape:

```js
  REGISTER(C.module("m2", "♠", "The Game Engine", "pure Dart — your phase", [
  C.step("m2s1", "Cards, suits, the deck", {
    learn: [
      C.h("Heading"),
      C.p("A paragraph, with `inline code` and <code>tags</code>."),
      C.b("a bullet"),
      C.callout("A highlighted note", "warn"),       // kind: "" | "warn" | "ok"
    ],
    do: [
      C.p("Numbered build action — 'start with this'."),
      C.code("source...", "dart"),                    // lang: dart | go | yaml | json | shell
    ],
    explain: [
      C.p("Code walkthrough — why this code works."),
      C.code("the code under discussion", "dart"),
    ],
    alternatives: [
      { title: "The other way to do it", text: "What the 'production' version looks like, and the trade.", code: "optional sample" },
      { title: "Another alternative", text: "..." },
    ],
    improve: [
      { title: "A future recommendation", text: "Concrete next step to take yourself." },
    ],
    activity: { type: "quiz", q: "...", opts: [...], correct: 1, explain: "..." },
    // or
    activity: {
      type: "code", starter: "// prefill...",
      checks: [
        CHK.has("name", "regex pattern", "hint shown on failure"),
        CHK.lacks("name", "regex pattern", "hint"),
        CHK.count("name", "regex pattern", 3, "hint"),
      ],
    },
    // or { type: "both", quiz: {...}, code: {...} }
    done: ["Definition of done item"],
    refs: ["frontend/lib/engine/card.dart"],
  }),
]));
```

Checkers run your pasted code through regex assertions — `has` (pattern must
appear), `lacks` (must not), `count` (at least N matches). Patterns are plain
RegExp, so craft them to accept any correct implementation, not just the
reference one.
