#!/usr/bin/env python3
"""
Read basic fitness data from a first-generation Sony wena wrist (BLE name "WN-W01")
on macOS, without the discontinued wena app or Sony servers.

Protocol reconstructed from the last Android wena app (jp.co.sony.wena 1.54):
  sony.wena.models.ble.GATT.WenaWristGATT      -> service / characteristic UUIDs
  sony.wena.models.device.synclogic.WenaFirstModelSyncLogic -> gen 1 sync order
  sony.wena.models.ActivityRecord              -> today-steps read, records read loop
  sony.wena.util.BLEPacketConverter            -> byte formats
  sony.wena.models.devicesetting.TimeSetting   -> epoch offset (2013-01-01 UTC)

Usage:
  python3 wena_gen1.py                 # scan, connect, print today's steps + history
  python3 wena_gen1.py --csv out.csv   # also write history to CSV
  python3 wena_gen1.py --set-time      # also push current time/timezone to the band
"""
import argparse
import asyncio
import csv
import datetime as dt
import struct
import sys
import time

from bleak import BleakClient, BleakScanner

DEVICE_NAME = "WN-W01"
EPOCH_OFFSET = 1356998400  # 2013-01-01T00:00:00Z; band timestamps are seconds since this

SVC_SYSTEM = "4efd1501-a6c1-16f0-062f-f196cf496695"
SVC_STEPS = "4efd1701-a6c1-16f0-062f-f196cf496695"

CH_TIMESTAMP = "4efd1502-a6c1-16f0-062f-f196cf496695"  # write u32 LE (now - EPOCH_OFFSET)
CH_MODE = "4efd1503-a6c1-16f0-062f-f196cf496695"       # read: 3 = NORMAL, 1 = SHIPMENT, 0/255 = factory
CH_FW_VERSION = "4efd1505-a6c1-16f0-062f-f196cf496695" # read: UTF-8 string, e.g. "1.74a"
CH_TIMEZONE = "4efd1508-a6c1-16f0-062f-f196cf496695"   # write [hours, minutes] signed bytes
CH_BATTERY = "4efd1509-a6c1-16f0-062f-f196cf496695"    # read: int LE, mV (>999) or centivolts
CH_TRY = "4efd1513-a6c1-16f0-062f-f196cf496695"        # app's connectivity probe
CH_STEP_RECORDS = "4efd1702-a6c1-16f0-062f-f196cf496695"  # read 6-byte records; write 0xFF for next page
CH_TODAY_STEPS = "4efd1703-a6c1-16f0-062f-f196cf496695"   # read: int LE
CH_STEP_GOAL = "4efd1705-a6c1-16f0-062f-f196cf496695"     # read/write: u32 LE

MODE_NAMES = {255: "FPA", 0: "FPA2", 1: "SHIPMENT", 3: "NORMAL", 4: "UNKNOWN"}


def le_int(b: bytes) -> int:
    return int.from_bytes(b, "little", signed=False)


def battery_percent(volts: float):
    """Nearest-voltage lookup in the app's battery_voltage_to_percentage.csv, if present."""
    import os
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "battery_voltage_to_percentage.csv")
    try:
        with open(path) as f:
            table = [(float(a), float(b)) for a, b in csv.reader(f) if a and b]
    except OSError:
        return None
    if not table:
        return None
    return min(table, key=lambda r: abs(r[0] - volts))[1]


def parse_records(b: bytes):
    """6-byte records: [u16 steps][u32 ts]. ts==0 means empty slot."""
    out = []
    for i in range(len(b) // 6):
        steps, ts = struct.unpack_from("<HI", b, i * 6)
        if ts != 0:
            out.append((ts + EPOCH_OFFSET, steps))
    return out


async def read_all_records(client: BleakClient):
    """Mirror of ActivityRecord.createStepcountRecordsLoadTask + ContinuousBLEValueLoadStatus:
    read a page, then write 0xFF and read again until two empty pages or the same
    first-timestamp is seen twice."""
    records = {}
    empty = 0
    same = 0
    latest_check = 0
    page = 0
    while True:
        data = await client.read_gatt_char(CH_STEP_RECORDS)
        recs = parse_records(bytes(data))
        page += 1
        print(f"  page {page}: {len(data)} bytes, {len(recs)} records", file=sys.stderr)
        if not recs:
            empty += 1
        else:
            if recs[0][0] == latest_check:
                same += 1
            latest_check = recs[0][0]
        for ts, steps in recs:
            records[ts] = steps
        if empty >= 2 or same >= 2:
            break
        await client.write_gatt_char(CH_STEP_RECORDS, b"\xff", response=True)
    return sorted(records.items())


async def main(args):
    print(f"Scanning for {DEVICE_NAME} ({args.scan}s)...", file=sys.stderr)
    dev = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=args.scan)
    if dev is None:
        print("Band not found. Make sure it is in normal mode (not standalone/sleep mode) "
              "and not connected to a phone.", file=sys.stderr)
        return 1
    print(f"Found {dev.name} {dev.address}", file=sys.stderr)

    client = None
    for attempt in range(3):
        try:
            client = BleakClient(dev, timeout=45)
            await client.connect()
            break
        except Exception as e:
            print(f"connect attempt {attempt + 1} failed: {type(e).__name__}: {e}", file=sys.stderr)
            client = None
            await asyncio.sleep(3)
    if client is None:
        print("Could not connect. If the band was previously paired to a phone it may only accept "
              "that phone; see Sony's guide on initialising the band.", file=sys.stderr)
        return 3

    async with client:
        print("Connected. macOS may ask for a pairing PIN (part of the band's serial number).",
              file=sys.stderr)

        if args.dump:
            print("GATT services on the band:")
            for svc in client.services:
                print(f"  service {svc.uuid}")
                for ch in svc.characteristics:
                    print(f"    char {ch.uuid}  props={','.join(ch.properties)}")

        # First read triggers macOS pairing; give the user ~2 minutes to type the passkey.
        fw = None
        for attempt in range(6):
            try:
                fw = bytes(await client.read_gatt_char(CH_FW_VERSION))
                break
            except Exception as e:  # timeout while the PIN dialog is open, or auth error
                print(f"  first read attempt {attempt + 1} failed: {e}", file=sys.stderr)
                await asyncio.sleep(2)
        if fw is None:
            print("Could not read from the band. Pairing probably did not complete.", file=sys.stderr)
            return 2
        print(f"Firmware: {fw.decode('utf-8', 'replace').strip()}")

        mode = le_int(bytes(await client.read_gatt_char(CH_MODE)))
        print(f"Mode: {mode} ({MODE_NAMES.get(mode, '?')})")
        if mode != 3 and args.normal_mode:
            # Same write the app does in createAndroidModeWriteTask: a single byte 0x03.
            await client.write_gatt_char(CH_MODE, b"\x03", response=True)
            mode = le_int(bytes(await client.read_gatt_char(CH_MODE)))
            print(f"Mode after write: {mode} ({MODE_NAMES.get(mode, '?')})")
        elif mode != 3:
            print("Band is not in NORMAL mode. Re-run with --normal-mode to set it, "
                  "which is what the app does during setup.", file=sys.stderr)

        raw = le_int(bytes(await client.read_gatt_char(CH_BATTERY)))
        volts = raw / 1000.0 if raw > 999 else raw / 100.0
        pct = battery_percent(volts)
        pct_s = f", ~{pct:.0f}%" if pct is not None else ""
        print(f"Battery: {volts:.2f} V (raw {raw}{pct_s})")

        today = le_int(bytes(await client.read_gatt_char(CH_TODAY_STEPS)))
        print(f"Today's steps: {today}")

        print("Reading step history...", file=sys.stderr)
        history = await read_all_records(client)
        print(f"History records: {len(history)}")
        for ts, steps in history[-10:]:
            print(f"  {dt.datetime.fromtimestamp(ts).isoformat()}  {steps}")

        if args.csv:
            with open(args.csv, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["timestamp_utc", "local_time", "steps"])
                for ts, steps in history:
                    w.writerow([ts, dt.datetime.fromtimestamp(ts).isoformat(), steps])
            print(f"Wrote {args.csv}")

        if args.set_time:
            now = int(time.time()) - EPOCH_OFFSET
            await client.write_gatt_char(CH_TIMESTAMP, struct.pack("<I", now), response=True)
            off = -time.altzone if time.daylight and time.localtime().tm_isdst else -time.timezone
            tz = struct.pack("<bb", int(off / 3600), int((off % 3600) / 60))
            await client.write_gatt_char(CH_TIMEZONE, tz, response=True)
            print("Time and timezone written.")
    return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--csv", help="write step history to this CSV file")
    p.add_argument("--set-time", action="store_true", help="push current time/timezone to the band")
    p.add_argument("--scan", type=float, default=15.0, help="scan timeout in seconds")
    p.add_argument("--dump", action="store_true", help="list all GATT services/characteristics first")
    p.add_argument("--normal-mode", action="store_true",
                   help="if the band is not in NORMAL mode (3), write mode 3 like the app's setup does")
    sys.exit(asyncio.run(main(p.parse_args())))
