# AGENT_SETUP.md — let Claude Code set up N1 for you

This file is written **for an AI coding agent** (Claude Code), not (only) for humans. If you're a new
owner: open a terminal in this repo and run `claude`, then say:

> **"Read AGENT_SETUP.md and set up N1 for me."**

(or use the bundled slash command **`/setup-n1`**.)

The agent will work through the runbook below, run the commands, and ask you only the few choices that
are genuinely yours. What follows is the agent's instructions.

---

## Agent: your job

Set this user up with a working N1: (1) the local backend `n1d` running, and (2) the iOS app built and
installed (on their iPhone or the simulator), pointed at their backend, with Apple Health connected.
Work autonomously; **stop and ask only at the decision points marked 🟦 ASK**. Before installing any
tool or doing anything outwardly-visible, say what you're about to do. Never invent the user's
Apple Team ID, bundle id, or server address — ask.

Proceed phase by phase; after each phase, confirm it succeeded before moving on.

---

## Phase 0 — Environment check

Run these and report what's present/missing; offer to install what's missing (with `brew`) only after
telling the user:

```bash
sw_vers                              # macOS?
xcodebuild -version                  # Xcode (needed for the app)
node -v                              # need Node >= 18
which xcodegen || echo "missing"     # brew install xcodegen
which tailscale || ls /Applications/Tailscale.app 2>/dev/null || echo "no tailscale"
claude -p "reply with exactly: OK"   # is Claude Code installed AND authenticated?
```

- If `node` < 18 → ask the user to install Node 18+ (e.g. `brew install node`).
- If `xcodegen` missing → `brew install xcodegen` (after telling them).
- If the `claude` check doesn't print OK → the backend can't work. Tell the user to install the Claude
  Code CLI and authenticate (`claude` once, follow login), then re-run. Confirm `claude` is on PATH.

## Phase 1 — 🟦 ASK the three setup choices

Ask the user (one question each, accept their answers, then continue):

1. **Run on your real iPhone, or just the iOS Simulator?**
   - Simulator → easiest, no signing, but it uses *demo* health data (no real HealthKit). Good for a look.
   - Real iPhone → uses your real Apple Health (the point of N1); needs an Apple Developer account.
2. **(iPhone only) How will your phone reach your Mac?** Recommend **Tailscale** (free, private). The
   alternative is same-Wi-Fi LAN IP. (Simulator uses `127.0.0.1`, no networking needed.)
3. **(iPhone only) Your Apple Developer Team ID and a unique bundle id.** Team ID is the 10-char string in
   developer.apple.com → Membership. Bundle id e.g. `com.<you>.n1`. (Simulator can skip — any value works.)

## Phase 2 — Backend (`n1d`)

```bash
cd server
# optional: cp .env.example .env  and edit (PORT, N1_MODEL, N1_HANDBOOK, N1_EXTRA_SOURCES_DIR)
node n1d.mjs            # leave running; for background use:  (node n1d.mjs > /tmp/n1d.log 2>&1 &)
```

Verify in another shell:

```bash
curl -s http://127.0.0.1:8787/health    # expect {"ok":true,"model":"...","sources":N}
```

If the model id errors ("model not found"), set `N1_MODEL` to one the user's Claude Code can use
(e.g. `N1_MODEL=claude-sonnet-4-6 node n1d.mjs`) and retry `/health`.

**Offer** to make it permanent so the user doesn't keep a terminal open: create a LaunchAgent at
`~/Library/LaunchAgents/cc.n1.n1d.plist` running `node <repo>/server/n1d.mjs` with `RunAtLoad` +
`KeepAlive`, then `launchctl load` it. Only do this if they say yes.

## Phase 3 — Networking (iPhone only)

- **Tailscale:** ensure it's installed and logged in on the Mac; get the Mac's address:
  ```bash
  tailscale ip -4    # or: /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4
  ```
  Tell the user to install Tailscale on the iPhone and sign into the **same account**. The app's server
  URL will be `http://<that-100.x.address>:8787`.
- **LAN alternative:** `ipconfig getifaddr en0` for the Mac's Wi-Fi IP; phone must be on the same Wi-Fi;
  caveat that it only works at home. Security: `n1d` runs code over the user's data — keep it on a
  trusted private network only.

## Phase 4 — App config

```bash
cd app
cp N1/Local.xcconfig.template N1/Local.xcconfig
# Edit N1/Local.xcconfig:
#   DEVELOPMENT_TEAM = <the user's Team ID>           (simulator: can be blank)
#   PRODUCT_BUNDLE_IDENTIFIER = <unique e.g. com.you.n1>
xcodegen generate
```

## Phase 5 — Build & install

**Simulator:**
```bash
xcodebuild -project N1.xcodeproj -scheme N1 \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; \
xcrun simctl install booted build/dd/Build/Products/Debug-iphonesimulator/N1.app && \
xcrun simctl launch booted cc.<bundle> ; open -a Simulator
```
(Use the actual bundle id from Local.xcconfig.)

**Real iPhone** (device connected via USB or same network, unlocked):
```bash
xcodebuild -project N1.xcodeproj -scheme N1 -destination 'generic/platform=iOS' \
  -derivedDataPath build/dev -allowProvisioningUpdates build
# find the device id:
xcrun devicectl list devices | grep -i iphone
xcrun devicectl device install app --device <DEVICE_ID> \
  build/dev/Build/Products/Debug-iphoneos/N1.app
xcrun devicectl device process launch --device <DEVICE_ID> <bundle id>
```
If install fails with "unable to locate device" / a tunnel error: ask the user to plug the iPhone in
via USB and unlock it, then retry (wireless install is flaky).

## Phase 6 — First run (tell the user to do this on the phone)

1. Open N1 → tap the **gear (Settings)** → set **Server URL** to the Mac's address from Phase 3
   (simulator: `http://127.0.0.1:8787`) → tap **Test connection** (should say connected + model + sources).
2. In onboarding, tap **Connect Apple Health** → **Turn On All** categories. (Optional: enable Location.)
3. Let the agent propose ground-truth facts; confirm/correct them.

## Phase 7 — Verify end to end

Have the user ask one question (e.g. "Do late nights hurt my recovery?"). Watch the backend:
```bash
tail -n 20 /tmp/n1d.log      # should show an [n1d] investigate/onboarding line + a job
```
The app should stream steps and land a finding (or an honest "not enough data"). If it stays blank or
errors, see Troubleshooting.

---

## Troubleshooting (agent: consult as needed)

- **`/health` works locally but not from the phone** → the phone can't reach the Mac. Re-check Tailscale
  is up on both (same account), the URL uses the Mac's `100.x` address and port `8787`, and the Mac is
  awake. `n1d` binds `0.0.0.0`, so it's reachable on the tailnet.
- **App not in iOS Settings → Health → Data Access** → HealthKit auth didn't fire; have them use the
  in-app "Connect Apple Health" button (it requests from inside onboarding). The app writes a
  `healthkit-status.json` in its container you can pull with `devicectl` to diagnose coverage.
- **Shows "Demo data"** → on a real device that means HealthKit isn't authorized yet (grant all). Demo is
  only used on the simulator (no HealthKit).
- **Model errors** → set `N1_MODEL` to an available model and restart `n1d`.
- **Port 8787 in use** → start with `PORT=8799 node n1d.mjs` and set the app's server URL to that port.
- **Hourly/location analyses empty** → hourly steps need step data; location accrues only after you
  enable it (iOS has no location history).

When everything passes, tell the user they're set: ask N1 a question, and run an experiment when it
offers one. Point them at `README.md` for what it can do and `SETUP.md` for the manual reference.
