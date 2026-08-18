REGISTER(C.module("m15", "🚀", "Ship It", "icon, builds, stores, backend deploy", [
  C.step("m15s1", "Icon, splash, assets", {
    learn: [
      C.h("First impressions are assets too"),
      C.p("The app already has a felt-and-gold design language; now package it. App icons are generated from one source image via flutter_launcher_icons (or platform tools). Audio, images, and fonts are registered in pubspec.yaml — unlisted assets silently fail at runtime."),
    ],
    do: [
      C.p("Register the asset folders and fonts — the same mechanism you learned in module 0.3:"),
      C.code("flutter:\n  uses-material-design: true\n  assets:\n    - assets/audio/       # music + card SFX\n    - assets/images/      # icon source, any raster art\n  fonts:\n    - family: Cinzel\n      fonts:\n        - asset: assets/fonts/Cinzel-Bold.ttf\n          weight: 700\n    - family: PlusJakartaSans\n      fonts:\n        - asset: assets/fonts/PlusJakartaSans-Medium.ttf\n          weight: 500\n        - asset: assets/fonts/PlusJakartaSans-SemiBold.ttf\n          weight: 600\n        - asset: assets/fonts/PlusJakartaSans-Bold.ttf\n          weight: 700", "yaml"),
      C.p("Generate launcher icons from a single source image with flutter_launcher_icons (dev dependency + a flutter_launcher_icons: section in pubspec)."),
      C.p("Drop the final music into assets/audio/ and wire it into the AudioController (module 5.3)."),
    ],
    explain: [
      C.p("The asset declaration gotcha is worth repeating: assets are registered, not auto-discovered. Forget to list a file and it silently fails at runtime with 'asset not found' — never at build time. That silent failure is exactly why a smoke test should tap through the audio-bearing screens before shipping."),
      C.p("flutter_launcher_icons generates every platform's icon sizes from one source image — the manual alternative is producing 20+ sizes by hand in each platform folder. One tool, one source of truth, per-platform output you never touch."),
      C.p("Fonts ride the same registration mechanism with weights — PlusJakartaSans Medium/SemiBold/Bold as separate files, mapped by weight so TextStyle(fontWeight: w600) picks the right file automatically."),
    ],
    alternatives: [
      { title: "Adaptive icons (Android)", text: "Modern Android wants an adaptive icon (foreground + background layers) for maskable shaping. flutter_launcher_icons supports it; the default one-image icon still works, just with more clipping on some launchers." },
      { title: "A splash package", text: "flutter_native_splash generates a native splash. The felt-green background + a gold suit glyph is a two-line config — the 'set a colour and a logo' path." },
    ],
    improve: [
      { title: "Pick licensed music", text: "music_to_use/ holds tracks awaiting a cut. License matters for a store submission — an unlicensed track is a takedown risk, not a feature." },
      { title: "Icon variants", text: "A themed seasonal icon (felt + gold behind a spade) is a low-effort high-charm touch stores and players notice." },
    ],
    activity: {
      type: "quiz",
      q: "You add assets/audio/trick.mp3 but forget to declare it in pubspec.yaml. What happens?",
      opts: ["Nothing — it auto-loads", "It fails at runtime to load the asset", "The build errors", "Flutter warns and moves on"],
      correct: 1,
      explain: "Assets must be declared; unlisted assets fail to load at runtime.",
    },
    done: ["Your app has an icon, splash, and audio that all load."],
    refs: ["frontend/pubspec.yaml", "frontend/assets/"],
  }),
  C.step("m15s2", "Build for Android", {
    learn: [
      C.h("APK vs App Bundle"),
      C.p("flutter build apk makes a single installable file (side-loadable, great for testing); flutter build appbundle makes the .aab you upload to Play — Play then generates per-device APKs (smaller, and required for new apps). Release builds need a signing keystore."),
    ],
    do: [
      C.p("Set the version — this IS your release tracking:"),
      C.code("# pubspec.yaml\nversion: 1.0.0+1     # versionName.versionCode (x.y.z+buildNumber)", "yaml"),
      C.p("Generate a keystore, add it to android/ (gitignored, secrets never in the repo), and configure signing in build.gradle."),
      C.p("Build the artifacts and verify the quality gate first:"),
      C.code("# debug/side-load\nflutter build apk --debug\n# release, signed\nflutter build apk --release\n# what you upload to Google Play\nflutter build appbundle --release\n\nflutter analyze && flutter test   # before every release", "shell"),
    ],
    explain: [
      C.p("versionCode is the contract with the store: it must INCREASE on every upload or Play rejects the update. Version names are for humans (1.0.0); the build number is for the store. The +1 in 1.0.0+1 is your build counter — bump it per release, and you'll never fight a 'version already exists' rejection."),
      C.p("Signing keys are the crown jewels: the keystore + its passwords must live in a secure store (env vars in CI, never the repo). Lose the keystore and you can never update the app under the same identity — a permanent, learnable mistake the README of Android development is full of."),
      C.p("The App Bundle vs APK split is the store's optimization: you upload one .aab, Play derives per-device APKs (arm64/x86, density-specific). New Play apps require it — build appbundle as the shipping artifact, apk only for direct side-loading."),
    ],
    alternatives: [
      { title: "Play App Signing", text: "Upload a release key and let Play host the signing key (and re-sign on your behalf). Google App Signing is the safer default — you keep the upload key, Google keeps the app signing key, and losing the upload key is recoverable." },
      { title: "CI signing", text: "Store the keystore + passwords as CI secrets and sign in the pipeline, not on your laptop. Reproducible release builds from a tagged commit — the backend release discipline you already know, applied to the app." },
    ],
    improve: [
      { title: "Release notes + staged rollout", text: "Play lets you roll out to 10% then 100%. Ship staged, watch the crash-free rate, then open the tap — the same canary instinct as a backend deploy." },
      { title: "ProGuard/R8 settings", text: "Default shrinking can strip reflection-based code. If a release build misbehaves but debug is fine, the shrink rules are the first suspect — keep the default R8 config until you need to tweak it." },
    ],
    activity: {
      type: "quiz",
      q: "Which artifact do you upload to Google Play for a new app?",
      opts: ["A raw APK", "An App Bundle (.aab)", "A debug APK", "A zip of the source"],
      correct: 1,
      explain: "Play requires App Bundles for new apps; Play derives per-device APKs.",
    },
    done: ["You can produce a signed release build and explain apk vs aab."],
    refs: ["frontend/pubspec.yaml", "frontend/android/"],
  }),
  C.step("m15s3", "Build for iOS", {
    learn: [
      C.h("TestFlight, not side-loading"),
      C.p("No .apk analog on iOS — you can't casually install a release build. The pipeline: flutter build ipa → open in Xcode → bundle id, signing team, icons → Archive → distribute to TestFlight → App Store. Provisioning is Xcode-managed; a paid Apple Developer account is required to distribute."),
    ],
    do: [
      C.p("Build the ipa and open Xcode to configure identity + signing:"),
      C.code("# 1. build the ipa\nflutter build ipa --release\n\n# 2. open Xcode, configure: bundle id, team, version\nopen ios/Runner.xcworkspace\n\n# 3. in Xcode: Product > Archive, then Distribute > TestFlight / App Store\n\nflutter analyze && flutter test   # same gate as Android", "shell"),
      C.p("Set the bundle id ONCE, up front — changing it later means a new app identity."),
      C.p("Add internal testers in App Store Connect and push a TestFlight build; install it on a real device (simulators lie about some plugins)."),
    ],
    explain: [
      C.p("iOS has no side-loading culture: distributing to anyone outside your own registered devices goes through TestFlight (internal testers) or the App Store. That's why the pipeline is build → Archive → distribute, not 'send an APK'. A paid developer account gates all of it."),
      C.p("The bundle id is the app's permanent identity on the platform — set it before your first real build. Renaming it later effectively creates a different app with an empty download history and no update path."),
      C.p("Real-device testing matters here in a way Android devs skip: audio plugins, backgrounding, and sensor behavior differ on simulators. Your TestFlight internal build is the honest QA environment."),
    ],
    alternatives: [
      { title: "Ad-hoc builds", text: "For a handful of devices, register their UDIDs and distribute an ad-hoc ipa. It's the iOS answer to 'send me an APK' — no store needed, but every device must be registered in your account." },
      { title: "Mac-only pipeline", text: "iOS builds require a Mac (Xcode). If you're on Linux, the realistic path is a CI service with macOS runners (GitHub Actions macos-14) that builds and uploads TestFlight builds for you." },
    ],
    improve: [
      { title: "App Store Connect API + CI", text: "Automate the archive→upload via xcrun altool / fastlane. A fastlane lane 'release' that bumps the build number, builds, and uploads is the same release discipline you'd script for a backend tag." },
      { title: "Background music control", text: "iOS interrupts your audio when the user backgrounds the app or a call arrives. Handle audio session interruptions in AudioController — a polish item real players hit on day one." },
    ],
    activity: {
      type: "quiz",
      q: "What's the iOS equivalent of installing a release APK on a friend's phone?",
      opts: ["Nothing casual — TestFlight or a registered device", "A .aab file", "Downloading from the web", "USB copy"],
      correct: 0,
      explain: "iOS has no side-loading; distribution is TestFlight or the App Store.",
    },
    done: ["You have an archived build in TestFlight with internal testers added."],
    refs: ["frontend/ios/"],
  }),
  C.step("m15s4", "Store listing + privacy", {
    learn: [
      C.h("The paperwork"),
      C.p("Both stores want more than the binary: screenshots, a description, category, content rating, a privacy policy URL, and a Data Safety/App Privacy form declaring what you collect. Call Break collects a device id and stores match history — declare both honestly."),
    ],
    do: [
      C.p("Write down what the app actually stores and sends — this IS your data-safety answer key:"),
      C.code("//   device id (Random.secure UUID, in IdentityStore)\n//   guest token / session token (for auth)\n//   match history + statistics (uploaded to your server)\n//   settings (theme, sound, difficulty) — local only", "shell"),
      C.p("Prepare the store materials: screenshots at the required sizes, description, category (Games > Card), content-rating questionnaire."),
      C.p("Host a real privacy policy URL — both stores review the link, so a placeholder fails review."),
      C.p("Fill the Google Play Data Safety form and Apple's App Privacy labels from your answer key."),
    ],
    explain: [
      C.p("The Data Safety / App Privacy forms have legal weight: they're a declaration of what your app does with user data, and the stores police consistency. Answering from what the code ACTUALLY does (the answer key above) is both honest and safer than improvising — a mismatch is what gets apps flagged."),
      C.p("The categories matter more than they seem: 'Games > Card' routes you to the right review queue and the right audience. Screenshots must show a real product at the required resolutions — store-review teams check they're not mockups."),
      C.p("The accounts upgrade (the designed-but-unbuilt Google/Facebook/Apple link, module 10.3) would change your data story: a login flow adds identity collection to these forms. Ship anonymous-first, and the form is short; add accounts, and re-file."),
    ],
    alternatives: [
      { title: "A template privacy policy", text: "Start from a reputable template and fill in your actual data practices. A real URL hosted somewhere (GitHub Pages is fine) beats a placeholder — the review is automated and will reject a dead link." },
      { title: "Deploy before you list", text: "Ship the privacy policy and your backend live BEFORE submitting the listing — store review doesn't wait while you scramble a server into existence." },
    ],
    improve: [
      { title: "Minimize by default", text: "Re-audit what you collect each release. The device id exists to tie history together; if you ever add analytics, declare it and make it opt-out. Less declared data = less review friction." },
      { title: "Data deletion path", text: "Both stores increasingly expect a 'delete my account/data' route. Your persistence is per device id — a 'Clear my data' endpoint is a small, forward-looking addition." },
    ],
    activity: {
      type: "quiz",
      q: "Where does the device id the app generates need to be declared?",
      opts: ["Nowhere", "The store's data-collection/privacy forms", "Only in the README", "In the version number"],
      correct: 1,
      explain: "Stores require honest disclosure of identifiers collected.",
    },
    done: ["You can fill the data-safety form from memory of what the app stores."],
    refs: ["frontend/lib/state/identity_store.dart"],
  }),
  C.step("m15s5", "Deploy the backend", {
    learn: [
      C.h("Your comfort zone, packaged"),
      C.p("The server is one binary that needs nothing by default — perfect for a hobby budget. Dockerfile + docker-compose in backend/deploy/ bring up server + Redis + Postgres. ENV=production makes JWT_SECRET and ALLOWED_ORIGINS mandatory and switches to JSON logs. Health/readiness/metrics let infra watch it."),
    ],
    do: [
      C.p("Bring up the full stack and confirm the probes answer:"),
      C.code("cd backend && make up\n\n# endpoints your infra will care about\nGET /healthz    # liveness\nGET /readyz     # readiness (503 while draining)\nGET /metrics    # Prometheus", "shell"),
      C.p("Configure production env — strict mode is a single switch:"),
      C.code("ENV=production\nJWT_SECRET=<strong random secret>\nALLOWED_ORIGINS=https://yourdomain\nADMIN_TOKEN=<unlocks the admin dashboard>", "shell"),
      C.p("Point the app at the deployed server via the settings sheet's server field (ws://your-host:8080/ws)."),
      C.p("Scale-out (only when you need it): REDIS_URL + PUBLIC_URL, and hash the load balancer on ?room= to minimise redirects."),
    ],
    explain: [
      C.p("ENV=production flips the whole posture: mandatory secrets, JSON logs, strict validation. Development stays forgiving (random JWT per process, pretty logs); production refuses to start misconfigured. That's the fail-fast config discipline you'd demand of any service you operate."),
      C.p("The probes are your load balancer's eyes: /healthz says 'process alive', /readyz goes 503 while draining so the LB stops sending players before tables tear down, /metrics feeds Prometheus the alertable numbers. None of this is game logic — it's the difference between a hobby server and a deployable one."),
      C.p("make test needs no database by design: persistence tests self-skip without TEST_DATABASE_URL, so the whole suite runs on any laptop in seconds. That's a CI-friendly default you should copy — your test suite must never require infrastructure to start."),
    ],
    alternatives: [
      { title: "A managed host vs compose", text: "Railway/Fly/Render can run the container without you touching a VPS. docker-compose on any $5 VPS is the leanest single-node story; managed hosts earn their cost when ops time is scarce." },
      { title: "No Redis, single node", text: "One node, no Redis, sessions stick to it. Fully supported (the server is one-binary-with-nothing by default). Redis only earns its complexity when a second node appears." },
    ],
    improve: [
      { title: "HTTPS + a reverse proxy", text: "Terminate TLS at Caddy/nginx in front of the Go server and put /metrics behind auth. Websocket-over-TLS (wss://) is required for any real deployment — a one-hour hardening that's non-negotiable outside your LAN." },
      { title: "Admin dashboard habit", text: "The token-gated /admin page shows live tables, hands, and pacing knobs. Make checking it part of your deploy ritual — it's the observability the README built for you." },
    ],
    activity: {
      type: "quiz",
      q: "In production, JWT_SECRET and ALLOWED_ORIGINS become what?",
      opts: ["Optional", "Mandatory — the server refuses to start without them", "Auto-generated", "Ignored"],
      correct: 1,
      explain: "ENV=production makes them required, and switches to JSON logs.",
    },
    done: ["make up runs the full stack; /healthz and /readyz answer on your box."],
    refs: ["backend/deploy/Dockerfile", "backend/deploy/docker-compose.yml", "backend/README.md (Configuration)"],
  }),
]));
