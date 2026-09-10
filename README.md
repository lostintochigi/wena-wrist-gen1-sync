# wena wrist gen 1 sync

Read step data from a first-generation **Sony wena wrist** (band `WN-WB01`, Bluetooth name
`WN-W01`) after Sony switched off the wena service and pulled the apps in February 2026.
No Sony app, no Sony server: an iPhone app talks straight to the band over Bluetooth LE using
the protocol reconstructed from the last official Android app.

Unofficial. Not affiliated with Sony. Use at your own risk. MIT licensed, except
`battery_voltage_to_percentage.csv`, which is a calibration table taken from Sony's app.

## What you get

- Today's step count and the band's stored step history, exported as CSV
- Battery, firmware, and mode readout
- A one-tap "Set up band" that restores a factory-reset band to normal logging mode
- The full GATT map and sync sequence in [docs/PROTOCOL.md](docs/PROTOCOL.md)

What the band cannot give you: heart rate, sleep, GPS, or calories. The first-generation
hardware has only an accelerometer. Suica was never supported on this model, and Sony's e-money
provisioning ended in 2023, so nothing new can be added to the FeliCa chip.

## Contents

| Path | What it is |
|---|---|
| `WenaSync.swiftpm/` | iPhone app (SwiftUI + CoreBluetooth, Swift Playgrounds app package, iOS 16+) |
| `install_iphone.sh` | Builds, signs, installs and launches the app from the Mac command line |
| `wena_gen1.py` | Python/bleak script for macOS. Can scan and enumerate the band, but macOS cannot pair with it, so it cannot read data. Kept for reference. |
| `battery_voltage_to_percentage.csv` | Voltage-to-percent table from Sony's app, used by the Python script |
| `docs/PROTOCOL.md` | Protocol reference |

## Requirements

- A first-generation wena wrist, charged. A flat band stops logging and sleeps.
- An iPhone running iOS 16 or later.
- A Mac with Xcode 15 or later (built and tested with Xcode 26) and a free Apple ID signed in
  to Xcode. A paid developer account is not needed; free signing works and lasts 7 days per
  install, after which you re-run the install.
- The band's 7-digit serial number, printed on the underside of the band module. The last
  6 digits are the Bluetooth passkey.

## Installation

### 1. Get the code

```sh
git clone https://github.com/lostintochigi/wena-wrist-gen1-sync.git
cd wena-wrist-gen1-sync
```

### 2. Prepare the iPhone

1. Plug the iPhone into the Mac with a cable, unlock it, tap **Trust This Computer**.
2. Enable Developer Mode: **Settings > Privacy & Security > Developer Mode**, turn on, restart,
   confirm. The switch only appears after the phone has been connected to Xcode once.

### 3a. Install with Xcode (GUI)

1. Open the folder `WenaSync.swiftpm` in Xcode.
2. In the project settings, under **Signing & Capabilities**, pick your personal team.
3. Select your iPhone as the run destination and press **Run**.
4. First launch only: on the phone go to **Settings > General > VPN & Device Management**, tap
   your Apple ID under Developer App, tap **Trust**. Then open WenaSync.

### 3b. Install from the command line

```sh
TEAM=ABCDE12345 ./install_iphone.sh
```

`TEAM` is your 10-character Apple Development Team ID, shown in Xcode under
**Settings > Accounts > your Apple ID > Team**. The script finds the connected iPhone, builds and
signs the app, installs it, and launches it. Do the one-time **Trust** step above if the launch
is refused.

## First run: pairing

The band only talks over an encrypted link, and it never asks Apple devices to pair on its own.
The app works around this by connecting with iOS's "requires ANCS" option, which forces iOS to
bond and show the passkey prompt.

1. Wake the band: press the power button for about 1 second until it vibrates. The top white
   LED blinks while it waits for a connection.
2. In WenaSync, leave **Require ANCS on connect** switched on and tap **Scan & Sync**.
3. When iOS shows the pairing prompt, enter the last 6 digits of the serial number.
4. The band flashes blue twice. The bond is permanent; you will not be asked again.

### If the band refuses to connect

A band that is still bonded to an old phone ignores every other device. You must initialise it:

1. Hold the power button about 6 seconds until it switches off (white LEDs go out one by one).
2. Hold it again about 9 seconds until the colour LED blinks red and blue alternately twice and
   the band vibrates once. The top white LED then blinks: pairing standby.

**Warning:** initialising erases the step history stored on the band and puts it into
"shipment" mode, in which it does not count steps. After pairing, tap **Set up band** once in
the app. That replays the official first-time setup: normal mode, clock and timezone, step
goal, activity logging on. FeliCa data is not affected.

## Everyday use

1. Wake the band (1-second press).
2. Open WenaSync, tap **Scan & Sync**.
3. Tap **Copy CSV** or **Share CSV**.

**Sync + set time** also pushes the phone's clock and timezone to the band; do this now and
then, since the band has no other time source.

CSV columns: `timestamp_utc` (Unix seconds), `local_time` (ISO 8601), `steps`.
Each row is one of the band's timestamped step buckets.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "Band not found" | Band asleep or in standalone mode. 1-second press until it vibrates. Standalone mode is yellow LED on a short press; normal mode is blue. |
| Connects, then "Insufficient Encryption" | Not bonded. Make sure the ANCS toggle is on. If the band was paired to another phone before, initialise it (see above). |
| "Mode 1 (SHIPMENT)" and 0 steps | Band was factory-reset. Tap **Set up band**. |
| App refuses to open on the phone | Trust the developer profile: Settings > General > VPN & Device Management. |
| Xcode says the device is unpaired / Developer Mode disabled | Accept the trust prompt on the phone and enable Developer Mode, then retry. |
| Band not listed in iOS Settings > Bluetooth | Expected. Modern iOS hides it. Pair from the app. |

## Why not the Mac?

`wena_gen1.py` shows what a Mac can do: scan, connect, list services. Every read then fails with
"Insufficient Encryption" and the band disconnects. Apple platforms only start a new pairing when
an accessory answers "Insufficient Authentication" or requests security itself, and this band
does neither. macOS System Settings does not list it either. See docs/PROTOCOL.md.

To run the script anyway:

```sh
python3 -m venv venv && ./venv/bin/pip install bleak
./venv/bin/python wena_gen1.py --dump
```

## How this was made

Sony's last Android app (`jp.co.sony.wena` 1.54) was decompiled with jadx. The UUID map lives in
`WenaWristGATT`, the gen 1 sync order in `WenaFirstModelSyncLogic`, the record formats in
`BLEPacketConverter`, and the first-time setup in `WenaDeviceSetting`. Details in
[docs/PROTOCOL.md](docs/PROTOCOL.md). The battery table is the app's own
`battery_voltage_to_percentage.csv`.

## Ideas not yet built

- Read goal-achievement history (service 4EFD1901)
- Distance and calorie estimates from height, weight and stride
- Write steps into Apple Health (needs a regular Xcode project for the HealthKit entitlement)
- Per-app notification LED colours over ANCS (characteristic 4EFD2003)
- Edy balance and payment history readout
