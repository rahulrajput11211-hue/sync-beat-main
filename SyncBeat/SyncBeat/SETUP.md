# SyncBeat setup (beginner-friendly)

## 1. Install tools
1. Install Node.js LTS from https://nodejs.org/
2. Install Flutter using the official guide: https://docs.flutter.dev/get-started/install
3. Install Android Studio and its Android SDK.
4. On your phone, enable Developer options and USB debugging if you want to install by USB.

## 2. Start the server
Open a terminal in the `SyncBeat/server` folder and type:

```bash
npm install
npm start
```

The server listens on port `8787`. For same-Wi-Fi use, find your computer's LAN IP:
- Windows: run `ipconfig` and find the IPv4 address of your Wi-Fi adapter.
- macOS/Linux: run `ip addr` or `ifconfig`.

Allow Node.js through your computer firewall on private networks. Phones and computer must be on the same Wi-Fi. Do not use `localhost` on phones; use the computer's LAN IP, for example `192.168.1.25`.

## 3. Run Flutter app
Open a second terminal in `SyncBeat/app`:

```bash
flutter pub get
flutter run
```

If you have more than one device connected, Flutter may ask you to choose one. In the app's Settings, enter the server address like `ws://192.168.1.25:8787` (include `ws://`).

For the host, tap **Create party**. Guests enter the four-digit code or scan the QR code. In this MVP the QR code contains `server|roomCode`; scanning is implemented as a simple code scanner, and the guest can paste/type the code if camera permission or QR parsing is unavailable.

## 4. Add music
On the host, tap **Add song** and select a local audio file. The app uploads it to the server. Guests see the song list and tap **Download** before playback. Songs are held on the server until the room is empty, when the server removes that room's files.

## 5. Test with 12 pretend phones
With the server running, open another terminal in `SyncBeat/tests`:

```bash
npm install
npm test
```

The test creates one host and 12 guest WebSocket clients, requests a scheduled play command, and checks that all clients receive the same server start timestamp. It tests message distribution, not real audio output.

## 6. Build an Android APK
In `SyncBeat/app`:

```bash
flutter pub get
flutter build apk --release
```

APK output:
`app/build/app/outputs/flutter-apk/app-release.apk`

Copy the APK to Android phones and install it. Android may ask you to allow installation from that file manager/browser. For Play Store distribution, configure signing and privacy disclosures first.

## Internet / HTTPS later
For public internet use, deploy the server behind a reverse proxy such as Caddy or nginx with TLS, and change the app URL to `wss://your-domain.example`. Do not expose this prototype directly to the internet as-is. Add user authentication, per-room authorization, upload limits, malware/file validation, rate limiting, and HTTPS/WSS first.

## Common issues
- **Can't connect:** confirm the phone and computer are on the same Wi-Fi; use the computer LAN IP, not `localhost`; allow port 8787 in firewall.
- **Wrong code / room full:** verify the host's current code. The room cap defaults to 30.
- **Upload fails:** try a small MP3/M4A file and check server terminal output and available disk space.
- **Guest has no sound:** wait for download to finish; check phone media volume and audio file compatibility.
- **Timing differs:** turn off Bluetooth, use the same Wi-Fi, keep phones near the access point, and use per-phone timing nudge. Bluetooth speaker latency can be large.
- **Camera scan fails:** grant camera permission or type the four-digit code manually.
- **iPhone local-network access:** grant Local Network permission when prompted. Configure iOS signing and test on a real iPhone.
