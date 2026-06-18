Set up N1 on this machine for me.

Read `AGENT_SETUP.md` in the repository root and follow it as a runbook: check prerequisites, start
the `n1d` backend, help me configure signing and networking, build and install the iOS app
(device or simulator), and verify it works end to end.

Work autonomously. Run the commands yourself. Stop and ask me only at the decision points the runbook
marks with 🟦 ASK (device vs simulator, Tailscale, my Apple Team ID + bundle id). Before installing any
tool or doing anything outwardly visible, tell me what you're about to do. Never invent my Apple Team
ID, bundle identifier, or server address — ask me for those.

After each phase, confirm it succeeded before moving on, and at the end tell me exactly what to do on
my phone (set the server URL in Settings, grant Apple Health).
