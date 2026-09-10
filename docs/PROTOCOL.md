# wena wrist (first generation, WN-W01) Bluetooth LE protocol

Reconstructed from the last release of Sony's Android companion app
(`jp.co.sony.wena` 1.54, April 2020) by decompiling it with jadx. Class names below refer to
that app. Verified against a real band running firmware 1.74a on 2026-09-10.

## Advertising and pairing

- Device name: `WN-W01`. Connectable, advertises service `4EFD1501-…`. No solicited services,
  which is why modern iOS Settings does not list it.
- Pairing uses a fixed passkey: the last 6 digits of the 7-digit serial number printed on the
  underside of the band module.
- Every data characteristic requires an encrypted link and the band answers unencrypted access
  with ATT error 0x0F "Insufficient Encryption", then disconnects. Apple platforms do **not**
  start a new pairing on 0x0F (only on 0x05 or an accessory security request), so:
  - macOS: cannot pair at all (System Settings does not list the band, CoreBluetooth never prompts).
  - iOS: pair from an app by connecting with `CBConnectPeripheralOptionRequiresANCS = true`.
    iOS must bond to grant ANCS, so it shows the passkey prompt. After that, reads work.
  - Android: the official app called `createBond()` before any GATT traffic.
- A band that already holds a bond ignores other centrals until it is initialised
  (hold power 6 s to switch off, then hold 9 s until the LED blinks red/blue and it vibrates).
  Initialising also **erases the stored step history** and puts the band into mode 1 (shipment).

## Services and characteristics

All 128-bit UUIDs share the suffix `-A6C1-16F0-062F-F196CF496695`; only the first group is shown.
Names are the constants in `sony.wena.models.ble.GATT.WenaWristGATT`. Integers are little-endian.
Timestamps are `u32` seconds since **2013-01-01T00:00:00Z** (`TimeSetting.OFFSET = 1356998400`).

### Service 4EFD1501 (system)

| Char | Name | Access | Format |
|---|---|---|---|
| 4EFD1502 | TimeStampSetting | write, read | u32 (now − offset) |
| 4EFD1503 | WenaMode | write, read | u8: 0/255 factory, 1 shipment, 3 normal. Setup writes `03`. |
| 4EFD1504 | DFU | write | enter firmware-update mode |
| 4EFD1505 | FWVersion | read | UTF-8 string, e.g. `1.74a` |
| 4EFD1506 | ClearInvalidFlag | write | `FF` |
| 4EFD1507 | InvalidStatusCheck | read | status flag |
| 4EFD1508 | TimeZoneSetting | write, read | `[hours, minutes]` signed bytes, UTC offset |
| 4EFD1509 | Battery | read | int; >999 → millivolts, else centivolts. Percent via lookup table. |
| 4EFD1511 | PowerSaveMode / SleepTracking / NotificationIgnore | write | `[kind, startH, startM, endH, endM]`; kind 0/1 sleep-mode schedule, 2/3 notification ignore, 4/5 second-gen power save |
| 4EFD1513 | Try | write | connectivity probe used by the app's empty task |
| 4EFD1514 | DeviceSetting / AutoPowerSaveEnable | write, read | various settings blobs (vibration, display, alarms) |
| 4EFD1516 | DayStartTimeSetting | write | u8 hour at which the daily count resets |
| 4EFD1517 | StepCountSetting / DisconnectedNotification | write | `01 + u32 goal` step goal; `02 + u8` goal-achieved notify on/off |

Present on firmware 1.74a but absent from the app's map: 4EFD1510, 1512, 1515, and service
4EFD1601 (char 1602, write-only). Also present: `1B716C92-57BE-4CBC-8450-70DBA8F1CE10` with
characteristics `…CE11` (write, indicate) and `…CE12` (indicate), purpose unknown, encrypted.
Characteristics 1518 (LargeBinaryTransfer), 1519 (PinSuccess) and service 1530 (FWUpdate) exist in
the app but not on this firmware.

### Service 4EFD1701 (steps)

| Char | Name | Access | Format |
|---|---|---|---|
| 4EFD1702 | StepCountRecords | read, write | Read returns a page of 6-byte records `[u16 steps][u32 timestamp]`; a record with timestamp 0 is empty. Write `FF` to advance to the next page, then read again. Stop after two empty pages or when the first record's timestamp repeats twice (`ContinuousBLEValueLoadStatus`). |
| 4EFD1703 | TodayStepCount | read | int, steps since the day-start hour |
| 4EFD1704 | ShowAchieveSetting | write | u8 show goal-achieved LED pattern |
| 4EFD1705 | StepCountGoal | write | u32 goal (second-gen path; gen 1 uses 1517) |
| 4EFD1706 | ActivityEnable | write | u8 1 = count steps / log activity |

### Service 4EFD1901 (history)

| Char | Name | Access | Format |
|---|---|---|---|
| 4EFD1902 | History | read | 6-byte records `[u16 type][u32 timestamp]`; type `0xFFFE` = step goal achieved. |

### Service 4EFD2001 (phone notification settings)

| Char | Name | Access |
|---|---|---|
| 4EFD2003 | PhoneNotificationFirstGen | write: per-app LED colour / vibration settings for ANCS notifications |

### Service 4EFD2101 (Rakuten Edy e-money)

| Char | Name | Access | Format |
|---|---|---|---|
| 4EFD2102 | EdyHistory | read | 7-byte records `[u8 type][u16 amount][u32 timestamp]` |
| 4EFD2103 | EdyBalance | read | int |
| 4EFD2104 | EdySetting | write | |
| 4EFD2105 | EdyNumber | read | |

Sony's provisioning service for e-money ("Osaifu Link") ended 2023-12-31; nothing new can be
written to the FeliCa chip. Suica was never supported on this model.

## Sync sequence used by the official app (gen 1)

`WenaFirstModelSyncLogic.syncExceptEdy`:

1. read TodayStepCount (1703)
2. read Battery (1509)
3. read StepCountRecords (1702) repeatedly, writing `FF` between reads, until complete
4. read History (1902) the same way
5. write TimeStampSetting (1502) and TimeZoneSetting (1508)
6. read WenaMode (1503); if not 3, write `03`

## First-time setup used by the official app (gen 1)

`WenaDeviceSetting.writeAllSettingToDeviceFirstModel`, after the mode write:

1. ClearInvalidFlag (1506) ← `FF`
2. TimeStampSetting (1502) ← u32
3. TimeZoneSetting (1508) ← `[h, m]`
4. StepCountSetting (1517) ← `01` + u32 goal (default 10000)
5. StepCountSetting (1517) ← `02` + u8 goal-achieved notify
6. PowerSaveMode (1511) ← sleep-mode schedule
7. ActivityEnable (1706) ← `01`
8. optionally AutoPowerSave (1514) and DayStartTimeSetting (1516)

## Firmware

The app bundles gen 1 firmware 1.74a as `assets/wena_app_174a.zip` and uses a Quintic/NXP
QN902x-style OTA path (service 0xFEE9, characteristic `D44BC439-ABFD-45A2-B575-925416129600`)
after writing to DFU (1504); the band then advertises as `UWN-W01`. Not reimplemented here.
