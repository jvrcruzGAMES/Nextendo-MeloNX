# Technical Comparison: Official Ryujinx vs. Ryujinx Nextendo

## 1. Executive Summary

**Ryujinx Nextendo** is a specialized fork of the official **Ryujinx** Nintendo Switch emulator, customized specifically to integrate out-of-the-box with **Nextendo Network** (a custom online infrastructure replacement for Nintendo Switch Online services).

While official Ryujinx focuses on core emulation accuracy, HLE service completeness, and local/RyuLDN multiplayer requiring external configuration, **Ryujinx Nextendo** transforms the emulator into a fully integrated online gaming client. It embeds network redirection, SSL cert pinning bypasses, cloud save sync, friends and matchmaking systems, game-specific connectivity patches, and a built-in mod store natively into the binary.

---

## 2. Overview of Workspace Projects

| Project Path | Repository | Primary Purpose |
|---|---|---|
| `references/Ryujinx` | Upstream Official Ryujinx | Baseline emulator codebase focusing on emulation accuracy & general HLE services. |
| `references/Ryujinx-Nextendo` | Nextendo Fork | Enhanced emulator client with embedded Nextendo online network stack, cloud sync, social UI, and mod store. |

---

## 3. Quantitative Summary of Changes

A complete git tree comparison between `Ryujinx (master)` and `Ryujinx-Nextendo (main)` reveals:
- **321 files modified or added**
- **38,753 insertions (+)** and **3,025 deletions (-)**
- **Major Subsystems Modified**: `Ryujinx.HLE` (Sockets, DNS, SSL, LDN, Mii, BCAT), `Ryujinx.Horizon`, `Ryujinx` (Avalonia UI, Systems, Configuration, Updater), and `Ryujinx.Tests`.

---

## 4. Key Feature Comparison Matrix

| Feature Category | Upstream Ryujinx | Ryujinx Nextendo |
|---|---|---|
| **Online Networking** | Default system DNS, basic socket layer; requires external tools or RyuLDN | Built-in `DnsMitmResolver` for auto-redirecting NSO FQDNs to Nextendo servers |
| **SSL / TLS Certificate Pinning** | Standard TLS; relies on manual `.ips` exefs patches placed on SD card | Embedded SNI injector (`TlsSniInjector`) & in-memory IPS32 patcher (`NextendoS3Patches`) |
| **LAN Play / LDN** | Requires separate `switch-lan-play` executable or RyuLDN server | Native embedded **LAN Play protocol stack** (`LanPlayClient.cs`, `VirtualAddressAllocator.cs`) |
| **User Account System** | Local offline profiles | **Nextendo OAuth Account Link** ("Sign in with Nextendo") binding profile to Nextendo ID |
| **Cloud Save Sync** | Manual save folder copy | Automatic **Cloud Save Sync** (`NextendoSaveSync.cs`) uploading/downloading on game launch & exit |
| **Social & Friends** | Offline friend code display only | Live Friends List window, favorite starring, status tracking, and "Accept All" requests |
| **Matchmaking & Lobbies** | Basic RyuLDN room list | Dedicated **Lobby Browser** (`NextendoLobbyWindow.axaml`) with live player counts per game |
| **In-Game Notifications** | None | Real-time **Overlay Toast Notifications** (`NextendoNotificationOverlayWindow`) for friend invites & alerts |
| **Mod Management** | Manual folder creation and file placement | Built-in **GameBanana Mod Store** (`ModStoreView.axaml`), searching, direct `.7z/.rar/.zip` installation |
| **BCAT & Event Sync** | Manual dump of BCAT storage | Auto BCAT cache & seed sync (`NextendoCacheSync`, `BcatSeed`) for Splatfests, events, and news |
| **UI & Visual Theme** | Standard Avalonia UI | Custom **Harbor Launcher Shell** (`ShellWindow.axaml`, `HarborTokens.axaml`) & dedicated dialogs |
| **Competitive Integrity** | Allows arbitrary exefs/subsdk mods | Restricts untrusted `.ips` mods on online titles (e.g. Splatoon 3 `ModsInterdits`) to block online cheaters |

---

## 5. Architectural & Technical Deep-Dive

### A. Custom Network Infrastructure & Service Interception
1. **DNS MITM Engine (`DnsMitmResolver.cs`)**:
   - Intercepts all DNS queries targeting Nintendo FQDNs (`*.nintendo.net`, `*.nintendo.com`, NPLN servers, NEX servers, BCAT) and routes them to Nextendo endpoints.
   - **Port-Aware Fallback (`RedirectionParPort`)**: Solves connection drops in gRPC/NEX games where socket code discards destination IPs after deserialization and defaults to `0.0.0.0`.
   - **SNI Tracking (`LastHostForIp`)**: Ensures IP-directed TLS connections carry valid SNI host headers for Nextendo reverse proxies.
   - **NPLN Race Condition Mitigation**: Buffers initial DNS resolution during heavy JIT compilation spikes to prevent gRPC client timeouts on startup.

2. **Embedded Game Patches & Certificate Bypass (`NextendoS3Patches.cs`)**:
   - Integrates binary IPS32 patches directly into the HLE loader. Automatically patches memory offsets for games like *Splatoon 3*, *Mario Tennis Aces*, and *ARMS* to bypass SSL certificate pinning without requiring user configuration.

3. **Native LAN Play & LDN Multi-Stack (`LanPlayClient.cs`, `LanPlayStack.cs`, `VirtualAddressAllocator.cs`)**:
   - Implements the complete IEEE 802.3 / IPv4 / UDP / TCP packet framing and virtual address allocation inside `Ryujinx.HLE.HOS.Services.Ldn`.
   - Replaces external executable dependencies with native in-emulator LAN Play networking.

---

### B. Nextendo API & Cloud Synchronization
1. **Nextendo REST API Client (`NextendoApi.cs`)**:
   - Lightweight client managing session tokens (`NEX token`), user authentication, friend interactions, play history, and online status.
2. **Cloud Save Synchronization (`NextendoSaveSync.cs`)**:
   - Computes save data checksums on title boot and closure, performing incremental upload/download syncs against Nextendo account cloud storage.
3. **BCAT & Dynamic Banners (`NextendoCacheSync.cs`, `NextendoByamlSync.cs`)**:
   - Pulls dynamic event data (e.g., Splatoon 3 Splatfest title screen logo swaps via `722fd4d`) and syncs BCAT seeds directly into game save containers.
4. **Play History & Time Tracking (`NextendoHistorySync.cs`)**:
   - Aggregates played titles, accumulated play time, and last-played timestamps, syncing them across multiple devices tied to the user's Nextendo account.

---

### C. Social Features & In-Game Overlay
1. **Friends Window (`NextendoFriendsWindow.axaml`)**:
   - Manage friend requests, view active friends, launch into friends' active games, and manage shared Mii data (`NextendoMiiSync.cs`).
2. **In-Game Toast Notifications (`NextendoNotificationOverlayWindow.axaml`)**:
   - Rendered directly over the active game view via Avalonia host overlay, presenting popups when friends start playing, join lobbies, or send invites.
3. **Rich Presence & Course Decoders (`NextendoRichPresence.cs`, `NextendoMk8Courses.cs`)**:
   - Custom Discord RPC module decoding detailed game activity (e.g., specific Mario Kart 8 course names, current Splatoon game mode) via game play reports.

---

### D. Integrated GameBanana Mod Store
1. **Mod Store Frontend (`ModStoreView.axaml`, `ModStoreViewModel.cs`)**:
   - Full catalog browser connected to GameBanana REST APIs. Allows searching, filtering by game title, viewing mod details, and managing favorites.
2. **Automated Mod Installer**:
   - Direct download and unarchiving of `.zip`, `.7z`, and `.rar` mod files. Automatically maps mod files to their target title structures and enforces security guards against Zip Slip path traversal attacks.

---

### E. UI Revamp & Shell Windows
1. **Harbor UI Design System (`HarborTokens.axaml`, `ShellWindow.axaml`)**:
   - Contemporary dark-mode visual theme with streamlined control layouts and new desktop launcher views.
2. **Nextendo Dialog Suite**:
   - `NextendoFriendsWindow.axaml` (Social Hub)
   - `NextendoLobbyWindow.axaml` (Lobby & Player Counts)
   - `NextendoFirstRunWindow.axaml.cs` (Onboarding Setup Wizard)
   - `NextendoReportWindow.axaml` (Player Reporting)
   - `SettingsNextendoView.axaml` (Dedicated Network & Account Settings)

---

### F. Security, Build, & Clean Distribution Pipeline
1. **Sanitized Release Binaries (`464abaf`, `6702145`)**:
   - Release builds automatically strip developer machine build paths, local user directory references, and reversed server IP strings from binary outputs.
2. **Custom Auto-Updater (`Updater.Nextendo.cs`)**:
   - Directly checks Nextendo distribution channels and applies seamless delta/full updates.
3. **macOS Code Signing (`6e73053`)**:
   - CI automated script for packaging universal macOS `.app` bundles with ad-hoc signing.

---

## 6. Summary Conclusion

While **Upstream Ryujinx** serves as the general-purpose, accurate emulator core, **Ryujinx Nextendo** is a specialized distribution designed to recreate the full Nintendo Switch Online ecosystem on PC. It accomplishes this through a deeply integrated custom network stack, automated cloud save and BCAT synchronization, built-in social features, native mod management, and tailored game patches.
