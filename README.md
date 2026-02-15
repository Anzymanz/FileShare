# FileShare (Flutter Desktop MVP)

FileShare is a Windows desktop Flutter app for LAN file sharing between peers on the same local network.

## What This MVP Does

- Drag and drop files or folders into the app to share them.
- Auto-discover peers on the same LAN (UDP broadcast).
- See each peer's shared files.
- Download remote files to your local `Downloads` folder.

## One-Time Machine Setup

1. Flutter SDK is installed at `C:\src\flutter`.
2. Enable Windows Developer Mode (required by Flutter plugins):
   - Open Settings -> Privacy & security -> For developers
   - Turn on `Developer Mode`

## Run

```powershell
cd F:\Flutter\FileShare
C:\src\flutter\bin\flutter.bat pub get
C:\src\flutter\bin\flutter.bat run -d windows
```

## Notes

- Run the app on two machines on the same subnet.
- Firewall prompts may appear on first run; allow local network access.
- Current MVP supports receive via button download (not OS drag-out from app window).
