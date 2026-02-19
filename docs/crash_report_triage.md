# Crash Report Triage

## Report Location

FileShare writes diagnostics under:

- Log file:
  - `%APPDATA%\\FileShare\\fileshare.log`
- Crash reports:
  - `%APPDATA%\\FileShare\\crashes\\crash_<timestamp>.txt`

## What To Collect

- Exact app version and installer version.
- OS version and architecture.
- Repro steps (specific and minimal).
- Most recent crash report file.
- Last 200 lines of `fileshare.log`.
- Whether room key auth is enabled.
- Whether issue happens on one PC or both peers.

## First-Pass Classification

- Startup crash
- Drag/drop crash
- Transfer crash/failure
- Discovery/connectivity failure
- Tray/minimize/windowing failure

## Quick Checks

- Confirm both peers run compatible protocol major version.
- Confirm firewall allows app on private network.
- Confirm transfer/discovery ports are listening.
- Confirm crash correlates with oversize/rate-limit/auth diagnostics counters.

## Suggested Repro Data

PowerShell:

```powershell
Get-NetUDPEndpoint -LocalPort 40405
Get-NetTCPConnection -LocalPort 40406
Get-Content "$env:APPDATA\FileShare\fileshare.log" -Tail 200
```

## Escalation Notes

- If no crash file exists but app hangs/freezes, treat as native/plugin-level issue.
- Capture screen recording and exact target app/window involved (for example VS Code chat drop zone).
- Include whether drag icon ghost remains after process exit.
