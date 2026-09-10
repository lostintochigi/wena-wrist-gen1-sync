import SwiftUI

struct ContentView: View {
    @StateObject private var ble = WenaBLE()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(ble.isBusy ? "Working…" : "Scan & Sync") { ble.startSync(setTime: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(ble.isBusy)
                    Button("Sync + set time") { ble.startSync(setTime: true) }
                        .buttonStyle(.bordered)
                        .disabled(ble.isBusy)
                    Button("Stop") { ble.stop() }
                        .buttonStyle(.bordered)
                }
                Button("Set up band (after a factory reset: normal mode, clock, logging on)") { ble.startSetup() }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                    .disabled(ble.isBusy)

                Toggle("Require ANCS on connect (forces iOS pairing prompt)", isOn: $ble.requireANCS)
                    .font(.footnote)
                    .disabled(ble.isBusy)

                GroupBox("Band") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status: \(ble.status)")
                        Text("Firmware: \(ble.firmware)")
                        Text("Mode: \(ble.modeText)")
                        Text("Battery: \(ble.batteryText)")
                        Text("Today's steps: \(ble.todaySteps.map(String.init) ?? "-")")
                        Text("History records: \(ble.records.count)")
                    }
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !ble.records.isEmpty {
                    HStack {
                        Button("Copy CSV") { UIPasteboard.general.string = ble.csv }
                            .buttonStyle(.bordered)
                        if let url = ble.csvFileURL {
                            ShareLink(item: url) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                GroupBox("Log") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(ble.log.enumerated()), id: \.offset) { i, line in
                                    Text(line).font(.system(.caption, design: .monospaced)).id(i)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: ble.log.count) { _ in
                            if let last = ble.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("wena gen 1 sync")
        }
    }
}
