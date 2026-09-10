import Foundation
import CoreBluetooth

/// Talks to a first-generation Sony wena wrist (BLE name "WN-W01").
/// Protocol reconstructed from the last Android wena app (jp.co.sony.wena 1.54):
///  - WenaWristGATT: service/characteristic UUIDs
///  - WenaFirstModelSyncLogic: gen 1 sync order
///  - ActivityRecord / BLEPacketConverter: today-steps read, 6-byte history records
///    [u16 steps][u32 seconds since 2013-01-01 UTC], paged by writing 0xFF and re-reading
///
/// Pairing: pair the band once from iOS Settings > Bluetooth (band in pairing standby,
/// passkey = last 6 digits of the 7-digit serial on the band's underside). After that,
/// iOS encrypts the link automatically and the reads below succeed.
final class WenaBLE: NSObject, ObservableObject {
    // MARK: UUIDs
    static let svcSystem = CBUUID(string: "4EFD1501-A6C1-16F0-062F-F196CF496695")
    static let svcSteps  = CBUUID(string: "4EFD1701-A6C1-16F0-062F-F196CF496695")

    static let chTimestamp   = CBUUID(string: "4EFD1502-A6C1-16F0-062F-F196CF496695") // write u32 LE (now - epochOffset)
    static let chMode        = CBUUID(string: "4EFD1503-A6C1-16F0-062F-F196CF496695") // read: 3 = NORMAL
    static let chFirmware    = CBUUID(string: "4EFD1505-A6C1-16F0-062F-F196CF496695") // read: UTF-8, e.g. "1.74a"
    static let chTimezone    = CBUUID(string: "4EFD1508-A6C1-16F0-062F-F196CF496695") // write [hours, minutes]
    static let chBattery     = CBUUID(string: "4EFD1509-A6C1-16F0-062F-F196CF496695") // read: int LE, mV
    static let chStepRecords = CBUUID(string: "4EFD1702-A6C1-16F0-062F-F196CF496695") // read pages; write 0xFF for next
    static let chTodaySteps  = CBUUID(string: "4EFD1703-A6C1-16F0-062F-F196CF496695") // read: int LE
    // First-time setup (WenaDeviceSetting.writeAllSettingToDeviceFirstModel + WenaDeviceMode):
    static let chClearInvalid   = CBUUID(string: "4EFD1506-A6C1-16F0-062F-F196CF496695") // write 0xFF
    static let chStepSetting    = CBUUID(string: "4EFD1517-A6C1-16F0-062F-F196CF496695") // write [1, goal u32 LE] / [2, notify]
    static let chActivityEnable = CBUUID(string: "4EFD1706-A6C1-16F0-062F-F196CF496695") // write [1] to enable logging

    static let epochOffset: UInt32 = 1_356_998_400 // 2013-01-01T00:00:00Z

    // MARK: Published state
    @Published var status = "idle"
    @Published var firmware = "-"
    @Published var modeText = "-"
    @Published var batteryText = "-"
    @Published var todaySteps: Int?
    @Published var records: [(ts: UInt32, steps: Int)] = []
    @Published var log: [String] = []
    @Published var isBusy = false
    @Published var csvFileURL: URL?
    @Published var requireANCS = true

    var csv: String {
        var s = "timestamp_utc,local_time,steps\n"
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        for r in records {
            let d = Date(timeIntervalSince1970: TimeInterval(r.ts))
            s += "\(r.ts),\(f.string(from: d)),\(r.steps)\n"
        }
        return s
    }

    // MARK: Internals
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var setTimeAfterSync = false
    private var pendingReads: [CBUUID] = []

    // history paging state (mirrors ContinuousBLEValueLoadStatus)
    private var pageCount = 0
    private var emptyPages = 0
    private var samePages = 0
    private var latestCheck: UInt32 = 0
    private var collected: [UInt32: Int] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startSync(setTime: Bool) {
        guard central.state == .poweredOn else { add("Bluetooth is not on"); return }
        setTimeAfterSync = setTime
        reset()
        mode = .sync
        isBusy = true
        status = "scanning"
        add("Scanning for WN-W01…")
        central.scanForPeripherals(withServices: [Self.svcSystem], options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.status == "scanning" else { return }
            self.central.stopScan()
            self.add("Band not found. Wake it: hold the power button ~1 s until it vibrates.")
            self.isBusy = false
            self.status = "idle"
        }
    }

    /// Put a freshly initialised band (mode 1 = SHIPMENT) back into normal logging mode,
    /// exactly as the official app's first-time setup did.
    func startSetup(stepGoal: Int = 10000) {
        guard central.state == .poweredOn else { add("Bluetooth is not on"); return }
        reset()
        var now = UInt32(Date().timeIntervalSince1970) &- Self.epochOffset
        let tdata = Data(bytes: &now, count: 4)
        let off = TimeZone.current.secondsFromGMT()
        let tz = Data([UInt8(bitPattern: Int8(off / 3600)), UInt8(bitPattern: Int8((off % 3600) / 60))])
        var goal = UInt32(stepGoal)
        let goalLE = Data(bytes: &goal, count: 4)
        setupQueue = [
            (Self.chMode,           Data([0x03]), "mode = NORMAL"),
            (Self.chClearInvalid,   Data([0xFF]), "clear invalid flag"),
            (Self.chTimestamp,      tdata,        "timestamp"),
            (Self.chTimezone,       tz,           "timezone"),
            (Self.chStepSetting,    Data([0x01]) + goalLE, "step goal \(stepGoal)"),
            (Self.chStepSetting,    Data([0x02, 0x00]), "goal-achieved notification off"),
            (Self.chActivityEnable, Data([0x01]), "activity logging on"),
        ]
        mode = .setup
        isBusy = true
        status = "scanning"
        add("Setup: scanning for WN-W01…")
        central.scanForPeripherals(withServices: [Self.svcSystem], options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.status == "scanning" else { return }
            self.central.stopScan()
            self.add("Band not found. Wake it: hold the power button ~1 s until it vibrates.")
            self.isBusy = false
            self.status = "idle"
        }
    }

    private enum Job { case sync, setup }
    private var mode: Job = .sync
    private var setupQueue: [(CBUUID, Data, String)] = []

    private func setupNext() {
        guard let p = peripheral else { return }
        if setupQueue.isEmpty {
            add("Setup writes done; re-reading mode and today's steps")
            status = "reading"
            pendingReads = [Self.chMode, Self.chTodaySteps]
            readNext()
            return
        }
        let (uuid, data, label) = setupQueue.removeFirst()
        guard let c = chars[uuid] else { add("Setup: characteristic \(uuid.uuidString.prefix(8)) missing, skipping \(label)"); setupNext(); return }
        add("Setup: writing \(label)")
        p.writeValue(data, for: c, type: .withResponse)
    }

    func stop() {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        isBusy = false
        status = "stopped"
    }

    private func reset() {
        chars = [:]
        pendingReads = []
        pageCount = 0; emptyPages = 0; samePages = 0; latestCheck = 0; collected = [:]
        records = []
        csvFileURL = nil
        todaySteps = nil
        firmware = "-"; modeText = "-"; batteryText = "-"
    }

    private func add(_ line: String) {
        let t = DateFormatter()
        t.dateFormat = "HH:mm:ss"
        log.append("\(t.string(from: Date())) \(line)")
    }

    private func leInt(_ d: Data) -> UInt32 {
        var v: UInt32 = 0
        for (i, b) in d.prefix(4).enumerated() { v |= UInt32(b) << (8 * UInt32(i)) }
        return v
    }

    private func parseRecords(_ d: Data) -> [(UInt32, Int)] {
        var out: [(UInt32, Int)] = []
        let n = d.count / 6
        for i in 0..<n {
            let o = i * 6
            let steps = Int(d[o]) | (Int(d[o + 1]) << 8)
            let ts = leInt(d.subdata(in: (o + 2)..<(o + 6)))
            if ts != 0 { out.append((ts &+ Self.epochOffset, steps)) }
        }
        return out
    }

    private func readNext() {
        guard let p = peripheral else { return }
        if let uuid = pendingReads.first, let c = chars[uuid] {
            p.readValue(for: c)
        } else if pendingReads.isEmpty {
            if mode == .setup { add("Setup complete"); finish() } else { startHistory() }
        }
    }

    private func startHistory() {
        guard let p = peripheral, let c = chars[Self.chStepRecords] else {
            add("Step records characteristic not found"); finish(); return
        }
        add("Reading step history…")
        status = "reading history"
        p.readValue(for: c)
    }

    private func handleHistoryPage(_ d: Data) {
        guard let p = peripheral, let c = chars[Self.chStepRecords] else { return }
        let recs = parseRecords(d)
        pageCount += 1
        add("page \(pageCount): \(d.count) bytes, \(recs.count) records")
        if recs.isEmpty {
            emptyPages += 1
        } else {
            if recs[0].0 == latestCheck { samePages += 1 }
            latestCheck = recs[0].0
        }
        for (ts, steps) in recs { collected[ts] = steps }
        if emptyPages >= 2 || samePages >= 2 || pageCount > 2000 {
            records = collected.keys.sorted().map { (ts: $0, steps: collected[$0]!) }
            add("History complete: \(records.count) records")
            writeCSVFile()
            if setTimeAfterSync { writeTime() } else { finish() }
            return
        }
        p.writeValue(Data([0xFF]), for: c, type: .withResponse)
    }

    private func writeTime() {
        guard let p = peripheral, let ct = chars[Self.chTimestamp], let cz = chars[Self.chTimezone] else { finish(); return }
        var now = UInt32(Date().timeIntervalSince1970) &- Self.epochOffset
        let tdata = Data(bytes: &now, count: 4) // little-endian on all Apple platforms
        p.writeValue(tdata, for: ct, type: .withResponse)
        let off = TimeZone.current.secondsFromGMT()
        let tz = Data([UInt8(bitPattern: Int8(off / 3600)), UInt8(bitPattern: Int8((off % 3600) / 60))])
        p.writeValue(tz, for: cz, type: .withResponse)
        add("Time and timezone written")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finish() }
    }

    private func writeCSVFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wena_steps.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            csvFileURL = url
        } catch {
            add("CSV write failed: \(error.localizedDescription)")
        }
    }

    private func finish() {
        status = "done"
        isBusy = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }
}

extension WenaBLE: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        add("Bluetooth state: \(central.state.rawValue)")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "?"
        add("Found \(name) rssi \(RSSI)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = "connecting"
        // The band uses ANCS for phone notifications. Asking iOS to require ANCS on this
        // connection makes iOS bond the accessory (passkey prompt) even though the band only
        // ever answers "Insufficient Encryption", which by itself never triggers pairing.
        var opts: [String: Any] = [:]
        if requireANCS { opts[CBConnectPeripheralOptionRequiresANCS] = true }
        add(requireANCS ? "Connecting with ANCS required (forces pairing)…" : "Connecting…")
        central.connect(peripheral, options: opts)
    }

    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        add("ANCS authorized: \(peripheral.ancsAuthorized)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        add("Connected")
        status = "discovering"
        peripheral.discoverServices([Self.svcSystem, Self.svcSteps])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        add("Connect failed: \(error?.localizedDescription ?? "?")")
        isBusy = false; status = "idle"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        add("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if status != "done" { isBusy = false; status = "idle" }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { add("Service discovery error: \(e.localizedDescription)"); finish(); return }
        for s in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] { chars[c.uuid] = c }
        let haveAll = chars[Self.chFirmware] != nil && chars[Self.chTodaySteps] != nil
        if haveAll && pendingReads.isEmpty && status == "discovering" {
            if mode == .setup {
                status = "setup"
                setupNext()
            } else {
                status = "reading"
                pendingReads = [Self.chFirmware, Self.chMode, Self.chBattery, Self.chTodaySteps]
                readNext()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let e = error {
            add("Read \(c.uuid.uuidString.prefix(8)) failed: \(e.localizedDescription)")
            if (e as NSError).code == CBATTError.insufficientEncryption.rawValue
                || (e as NSError).code == CBATTError.insufficientAuthentication.rawValue {
                add("Band needs pairing. Pair it once in iOS Settings > Bluetooth (passkey = last 6 digits of serial), then retry.")
            }
            finish(); return
        }
        let d = c.value ?? Data()
        switch c.uuid {
        case Self.chFirmware:
            firmware = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? d.map { String(format: "%02x", $0) }.joined()
            add("Firmware \(firmware)")
        case Self.chMode:
            let m = leInt(d)
            modeText = "\(m) (\(m == 3 ? "NORMAL" : m == 1 ? "SHIPMENT" : "other"))"
            add("Mode \(modeText)")
        case Self.chBattery:
            let raw = leInt(d)
            let volts = raw > 999 ? Double(raw) / 1000.0 : Double(raw) / 100.0
            batteryText = String(format: "%.2f V (raw %d)", volts, raw)
            add("Battery \(batteryText)")
        case Self.chTodaySteps:
            todaySteps = Int(leInt(d))
            add("Today's steps \(todaySteps!)")
        case Self.chStepRecords:
            handleHistoryPage(d)
            return
        default:
            add("Value \(c.uuid.uuidString.prefix(8)): \(d.map { String(format: "%02x", $0) }.joined())")
        }
        if let i = pendingReads.firstIndex(of: c.uuid) { pendingReads.remove(at: i) }
        readNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let e = error { add("Write \(c.uuid.uuidString.prefix(8)) failed: \(e.localizedDescription)"); finish(); return }
        if mode == .setup && status == "setup" { setupNext(); return }
        if c.uuid == Self.chStepRecords { peripheral.readValue(for: c) } // next page
    }
}
