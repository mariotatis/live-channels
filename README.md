# Channels

A native iOS (SwiftUI) live-TV client, port from Android XuperTV app.
Browse channels by category, search, favorite, and play powered by MobileVLCKit for broad codec support.

## Features

- Live-TV only: categories, full channel grid, and search
- Favorites (stored locally)
- Parental control with PIN gating
- Background audio playback

## Build

Open `Channels.xcodeproj` in Xcode and run the `Channels` scheme (iOS 26 target). The only dependency is `vlckit-spm` (MobileVLCKit), resolved automatically via SPM.

## Configuration

Backend hosts, keys, and identity live in `Channels/Core/Config/AppConfig.swift`, which is **not** committed. Copy the template and fill in your own values:

```bash
cp Channels/Core/Config/AppConfig.swift.example Channels/Core/Config/AppConfig.swift
```
