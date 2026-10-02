# Nextendo-MeloNX

<p align="center">
  <strong>An experimental iOS Nintendo Switch emulator with native Nextendo Network multiplayer support.</strong>
</p>

---

> [!WARNING]
> **EXPERIMENTAL PROJECT**
>
> Nextendo-MeloNX is an **experimental fork** of [MeloNX](https://github.com/MeloNX-Emulator/MeloNX) with integrated [Nextendo Network](https://nextendo.network) online capabilities. 
> 
> Features, server integrations, network protocols, and authentication flows are under active development and may change at any time. Compatibility varies by game title and network environment. Use at your own risk.

---

## 🌟 Overview

**Nextendo-MeloNX** combines the portable performance of MeloNX (powered by a C# NativeAOT Ryujinx emulator core) with built-in networking hooks for the Nextendo community network. It allows iOS devices to participate in online matchmaking, lobbies, friend sessions, and network multiplayer for supported titles without requiring complicated network setups.

### Key Highlights

- **Nextendo Network Integration**: Native support for NPLN and NEX (PRUDP) game traffic routing.
- **Account & Profile Sync**: Full-page WebKit OAuth login with PKCE exchange, persistent profile synchronization, and secure iOS Keychain storage.
- **Custom Server Override**: Built-in private server mode for connecting to self-hosted or LAN instances with isolated configuration that completely decouples from Nextendo secrets.
- **Automated Fallbacks**:
  - Missing network IPs automatically fallback to `127.0.0.1`.
  - Missing OAuth configuration safely disables account login while keeping the emulator fully functional.
- **Automated Nightly CI**: Pre-configured GitHub Actions workflow to build and package unsigned or signed sideloadable IPAs (`.ipa`) and application bundles (`.app.zip`).

---

## 🎮 Supported Titles & Engines

Nextendo-MeloNX integrates network compatibility patches for various online engines:

| Title | Network Engine | Features |
| :--- | :--- | :--- |
| **Mario Kart 8 Deluxe** | NEX (PRUDP) | Global/regional lobbies, tournaments, friend invites |
| **Super Mario Bros. Wonder** | NPLN (gRPC) | Live player shadows, standees, friend rooms |
| **Splatoon 3** | NPLN (gRPC) | Battles, Splatfests, BCAT seed delivery |
| **Splatoon 2** | NEX (PRUDP) | Regular/ranked battles, Salmon Run, stage rotations |
| **Pokémon Scarlet & Violet** | NPLN | Poké Portal battles, Tera Raids, Union Circle |
| **Super Smash Bros. Ultimate** | NEX (PRUDP) | Battle Arenas, matchmaking, friend rooms |
| **Animal Crossing: New Horizons** | NEX (PRUDP) | Dodo Code airport visits, island multiplayer |
| **Nintendo 64 - Nintendo Classics** | NPLN | 4-player netplay with TLS/peer hostname patches |

*(See the in-app **Nextendo** tab for full compatibility details and title IDs).*

---

## 🛠 Prerequisites

To build and run Nextendo-MeloNX, you will need:

1. **Host Environment**: macOS (Apple Silicon recommended) with Xcode 15 or 16 installed.
2. **.NET SDK**: .NET 10.0 or 8.0 SDK with `ios-arm64` NativeAOT support.
3. **iOS Device**:
   - iPhone / iPad running iOS 15.0 or later (iOS 17+ or iOS 18+ recommended).
   - **JIT is strictly required** (enabled via StikDebug, LiveContainer or TrollStore).
4. **Keys & Firmware**: Legal Nintendo Switch `prod.keys` and dumped system firmware.

---

## 🚀 Building from Source

### 1. Clone the Repository
```bash
git clone --recursive https://github.com/jvrcruzGAMES/Nextendo-MeloNX.git
cd Nextendo-MeloNX
```

### 2. Configure Environment & Secrets (Optional)
Copy `.env.example` to `.env` to configure your credentials:
```bash
cp .env.example .env
```
Edit `.env` to add your Nextendo credentials:
```env
# Nextendo OAuth Client ID (leaves OAuth disabled if empty)
NEXTENDO_OAUTH_CLIENT_ID=your_client_id_here

# Secret Nextendo Infrastructure IPs (defaults to 127.0.0.1 if unconfigured)
NEXTENDO_SERVER_IP=127.0.0.1
NEXTENDO_NAT_IP=127.0.0.1

NEXTENDO_SERVER_URL=https://nextendo.network
NEXTENDO_REDIRECT_URI=melonx://oauth/callback
NEXTENDO_OAUTH_SCOPES=identity friends presence game.matchmaking profil
```

> [!NOTE]
> `.env` and `NextendoSecrets.swift` are ignored by git to keep your private server credentials and client secrets secure.

### 3. Build MeloNX
Build the NativeAOT C# core, compile the Swift application, and package the IPA:
```bash
./build.sh --release
```
Artifacts will be produced in `./build`:
- `build/MeloNX.app` (Application bundle)
- `build/MeloNX.ipa` (Sideloadable IPA package)

### 4. Install Directly to a Connected iOS Device
If your device is paired with Xcode / CoreDevice:
```bash
./install.sh --release
```
This automatically resolves your Apple Development certificate, signs the bundle with development entitlements, creates the IPA, and installs it onto the device.

---

## ⚙️ Network Modes Explained

### Nextendo Network Mode
- Enabled by default via **Enable Nextendo Network**.
- Uses secret build constants embedded from `.env` or GitHub Actions secrets.
- Nextendo IPs are managed automatically behind the scenes and never exposed in the interface.

### Custom Server Mode
- Enabled via **Enable Custom Server Override (Private Mode)**.
- Intended for local LAN games, private servers, or self-hosted emulated servers.
- Uses dedicated, user-entered settings (`Custom Server URL`, `Custom Game Server IP`, `Custom NAT Responder IP`).
- **Completely ignores** Nextendo build constants and keeps your custom environment isolated.

---

## 🤖 GitHub Actions CI / Nightly Builds

The repository includes a nightly workflow [`.github/workflows/nightly.yml`](.github/workflows/nightly.yml) that compiles and outputs an unsigned `.ipa` package as a downloadable workflow artifact result:

### Configuring Repository Secrets
To build with Nextendo Network support in GitHub Actions, add these repository secrets:
- `NEXTENDO_OAUTH_CLIENT_ID`
- `NEXTENDO_SERVER_IP`
- `NEXTENDO_NAT_IP`
- `NEXTENDO_SERVER_URL`
- `NEXTENDO_REDIRECT_URI`
- `NEXTENDO_OAUTH_SCOPES`

If these secrets are omitted, the workflow will still succeed: it builds an unsigned IPA ready for your preferred sideloader (AltStore, SideStore, LiveContainer, TrollStore, Sideloadly, etc.), defaults network endpoints to `127.0.0.1`, and deactivates OAuth account login safely.

### Downloading the Workflow Result
Each workflow run uploads a single artifact:
- **`MeloNX-ipa`**: Contains the unsigned `MeloNX.ipa` ready for sideloading and signing with your own Apple ID or signing certificate.

---

## ⚖️ Legal & Disclaimer

- **Nextendo-MeloNX** is an open-source software project licensed under the GNU General Public License v3 (GPLv3).
- This project is **not** affiliated with, endorsed by, or associated with Nintendo Co., Ltd., Apple Inc., or any of their subsidiaries.
- **We do not endorse or support piracy.** Nextendo-MeloNX does not distribute proprietary Nintendo Switch firmware, game ROMs, encryption keys (`prod.keys`), or copyrighted assets. Users must legally dump their own software from their personal Nintendo Switch consoles.
