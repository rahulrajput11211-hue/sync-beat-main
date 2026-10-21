# SyncBeat

SyncBeat is a local-network synchronized music-party prototype built with Flutter and a Node.js WebSocket server.

## Important limitations
- This is a runnable MVP, not a guarantee of sample-accurate synchronization. Phone audio hardware, Bluetooth, OS scheduling, and audio focus add latency. The app synchronizes the requested playback position and corrects drift; it cannot make different speakers physically emit sound at exactly the same instant.
- Android background playback is supported through `audio_service` only after you add a production audio-service implementation. This MVP keeps the screen awake while playing, but background playback behavior depends on OS/device. iOS restricts background audio and local-network access; configure capabilities and test on real devices.
- Uploading a song means the host copies a locally stored audio file to the party server. Guests download that file before playing it. Use only music you have permission to share.
- The server uses a four-digit code and is intended for trusted Wi-Fi. Do not expose it to the public internet without TLS, authentication, rate limiting, and storage limits.

## Folder layout
- `server/` — Node.js WebSocket + HTTP server
- `app/` — Flutter application
- `tests/` — 12-client WebSocket synchronization smoke test

See `SETUP.md` for beginner steps.
