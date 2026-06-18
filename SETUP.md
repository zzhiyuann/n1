# Setup

This guide walks a technically-literate owner through standing up N1 end to end:
the **backend** on your Mac, the **network** between your phone and Mac, building
and installing the **app**, and the **first run**.

---

## 1. Backend (`n1d`)

`n1d` is a small local HTTP server that runs the Claude Code CLI as an autonomous
data-science agent over your data. It lives in [`server/`](server).

### 1.1 Install prerequisites

- **Node.js 18+** — `n1d` uses only the Node standard library, so there is **no
  `npm install`** step.
- **Claude Code CLI**, installed and authenticated, with `claude` on your `PATH`.
  `n1d` spawns `claude` to do the actual work. Verify:
  ```sh
  node --version      # >= 18
  claude --version    # CLI installed
  ```
  If `claude` is not authenticated yet, run it once interactively and complete login.

### 1.2 Configure (optional)

`n1d` is configured entirely via environment variables. Copy the template and edit
if you want to change defaults:

```sh
cd server
cp .env.example .env   # then edit, or just export these in your shell
```

> Note: `n1d` reads `process.env` directly — it does **not** auto-load `.env`.
> Either export the variables in your shell, use a process manager, or run e.g.
> `env $(cat .env | xargs) node n1d.mjs`.

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8787` | HTTP port to listen on. |
| `N1_MODEL` | `claude-opus-4-8` | Claude model id passed to the `claude` CLI. |
| `N1_HANDBOOK` | `../agent/handbook.md` | Path to the agent methodology handbook (reloaded per request — edits take effect on save). |
| `N1_EXTRA_SOURCES_DIR` | _unset_ | Optional directory of extra JSON data sources to expose to the agent. |

See [`server/README.md`](server/README.md) for the full API and data-source details.

### 1.3 Run and confirm

```sh
cd server
node n1d.mjs
# or: npm start
```

On start it prints the listen URL, the model in use, and the number of catalog
sources. In another terminal, confirm it's alive:

```sh
curl localhost:8787/health
# {"ok":true,"backend":"autonomous-investigator","model":"claude-opus-4-8","sources":0}
```

---

## 2. Networking: phone ↔ Mac

The app needs to reach `n1d` on your Mac. Pick one of the following.

### Recommended: Tailscale

[Tailscale](https://tailscale.com/) gives your phone and Mac stable private
addresses on an encrypted mesh network, so the connection works on any network
(home, cellular, coffee shop) without port-forwarding.

1. Install Tailscale on **both** your Mac and your iPhone.
2. Sign **both** devices into the **same tailnet** (same account).
3. Find your Mac's Tailscale address (a `100.x.x.x` IP):
   ```sh
   tailscale ip -4
   ```
4. Your server URL for the app will be `http://<mac-tailscale-ip>:8787`
   (e.g. `http://100.x.x.x:8787`).

### Simulator: localhost

If you run the app in the iOS Simulator on the same Mac, use
`http://127.0.0.1:8787` — the simulator shares the Mac's network.

### Alternative: LAN IP

If the phone and Mac are on the same Wi-Fi, you can use the Mac's local IP
(`http://<mac-lan-ip>:8787`, find it in System Settings → Network). Caveats: the IP
can change with DHCP, it only works while both devices are on that network, and it
exposes the port to everyone on that LAN.

> **Security:** `n1d` runs code over your personal data and has **no
> authentication**. Anyone who can reach its port can run code on your machine
> against your data. Keep it on a **trusted private network** — a Tailscale tailnet
> or `127.0.0.1` is ideal. Avoid untrusted/public Wi-Fi when binding beyond
> localhost.

---

## 3. App

The Xcode project is generated with [xcodegen](https://github.com/yonaskolb/XcodeGen)
from `app/project.yml`, so it isn't committed.

### 3.1 Install xcodegen

```sh
brew install xcodegen
```

### 3.2 Set your signing config

Copy the committed template to your (gitignored) local config and fill it in:

```sh
cd app
cp N1/Local.xcconfig.template N1/Local.xcconfig
```

Edit `N1/Local.xcconfig` and set:

- **`DEVELOPMENT_TEAM`** — your 10-character Apple Developer Team ID
  (developer.apple.com → Membership, or Xcode → Settings → Accounts).
- **`PRODUCT_BUNDLE_IDENTIFIER`** — a unique reverse-DNS bundle id you own,
  e.g. `com.yourname.n1`.

`N1/Local.xcconfig` is gitignored, so your personal values never get committed.

### 3.3 Generate and build

```sh
cd app
xcodegen generate
open N1.xcodeproj
```

In Xcode: select your device, build and run. The first install to a physical
device requires trusting your developer profile on the phone:
**Settings → General → VPN & Device Management → (your profile) → Trust**.

---

## 4. First run

1. Launch N1 on the device and open **Settings** (the gear icon).
2. Set the **server URL** to your Mac's address from step 2 — e.g.
   `http://100.x.x.x:8787` (Tailscale) or `http://127.0.0.1:8787` (Simulator).
3. Tap **Test connection** — it should succeed while `n1d` is running.
4. Complete onboarding and **grant Apple Health access for all categories** so the
   agent has data to investigate.
5. Ask your first question.

---

## Publishing a clean public release

This working repository's older git history contains machine-specific values — a
Tailscale `100.x.x.x` IP, an Apple Developer Team ID, and local data paths — even
though the current tree no longer does. If you intend to open-source it publicly,
**publish from a fresh repository with squashed history** rather than pushing the
existing history. For example:

```sh
# from a clean checkout of the current tree, with no .git
git init
git add .
git commit -m "Initial public release"
git remote add origin <your-public-repo>
git push -u origin main
```

This guarantees none of the earlier personal/machine-specific values leak through
old commits.
