import SwiftUI

@main
struct GatewaySwitchApp: App {
    @StateObject private var networkManager = NetworkManager()
    @State private var settingsWindow: NSWindow?
    @State private var settingsObserver: NSObjectProtocol?

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openSettings: openSettings)
                .environmentObject(networkManager)
        } label: {
            switch networkManager.currentMode {
            case .normal:
                Image(systemName: "network")
                    .font(.system(size: 13, weight: .heavy))
            case .passthrough:
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 13, weight: .heavy))
            case .unknown:
                Image(systemName: "questionmark.network")
                    .font(.system(size: 13, weight: .heavy))
            }
        }
    }

    private func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        settingsWindow = nil

        let hostingController = NSHostingController(
            rootView: SettingsView(closeSettings: closeSettings)
                .environmentObject(networkManager)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.setContentSize(NSSize(width: 420, height: 400))
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        settingsWindow = window

        if let old = settingsObserver { NotificationCenter.default.removeObserver(old) }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak window] _ in
            window?.isReleasedWhenClosed = true
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeSettings() {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsObserver = nil
        }
        guard let window = settingsWindow else { return }
        window.isReleasedWhenClosed = true
        settingsWindow = nil
        window.close()
    }
}

struct MenuBarView: View {
    @EnvironmentObject var networkManager: NetworkManager
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(networkManager.tr("DNS:"))
                        .foregroundColor(.secondary)
                    Text(networkManager.tr(networkManager.currentDNS))
                }
                HStack {
                    Text(networkManager.tr("Gateway:"))
                        .foregroundColor(.secondary)
                    Text(networkManager.currentGateway)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(networkManager.tr("Public IP:"))
                        .foregroundColor(.secondary)
                    Text(networkManager.tr(networkManager.publicIP))
                }
                if !networkManager.region.isEmpty {
                    HStack {
                        Text(networkManager.tr("Region:"))
                            .foregroundColor(.secondary)
                        Text(networkManager.region)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let error = networkManager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Divider()

            Button {
                Task { await networkManager.switchToNormal() }
            } label: {
                HStack {
                    Image(systemName: networkManager.currentMode == .normal ? "checkmark" : "circle")
                    Text(networkManager.tr("Normal Mode"))
                }
            }
            .disabled(networkManager.currentMode == .normal || networkManager.isSwitching)

            Button {
                Task { await networkManager.switchToPassthrough() }
            } label: {
                HStack {
                    Image(systemName: networkManager.currentMode == .passthrough ? "checkmark" : "circle")
                    Text("\(networkManager.tr("Passthrough Mode")) (\(networkManager.passthroughIP))")
                }
            }
            .disabled(networkManager.currentMode == .passthrough || networkManager.isSwitching)

            if networkManager.isSwitching {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            Button(networkManager.tr("Refresh")) {
                Task {
                    await networkManager.refresh()
                    await networkManager.fetchPublicIPInfo()
                }
            }

            Button(networkManager.tr("Settings...")) {
                openSettings()
            }

            Button(networkManager.tr("Quit")) {
                NSApplication.shared.terminate(nil)
            }

            Text("v\(Bundle.main.appVersion) (\(Bundle.main.buildDate))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .frame(width: 280)
        .task {
            await networkManager.refresh()
            await networkManager.fetchPublicIPInfo()
        }
    }
}

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildDate: String {
        guard let path = executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

struct SettingsView: View {
    @EnvironmentObject var networkManager: NetworkManager
    let closeSettings: () -> Void
    @State private var ipAddress: String = ""
    @State private var scannedHosts: [NetworkManager.ScannedHost] = []
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Text(networkManager.tr("Settings"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(networkManager.tr("IP Address:"))
                    TextField("192.168.1.147", text: $ipAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    Button(networkManager.tr("Scan Network")) {
                        startScan()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isScanning)
                }

                if isScanning {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(networkManager.tr("Scanning..."))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding(.leading, 4)
                }

                if !scannedHosts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(scannedHosts) { host in
                                Button {
                                    ipAddress = host.ip
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(host.isARP ? Color.green : Color.blue)
                                            .frame(width: 6, height: 6)
                                        Text(host.ip)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                        if let name = host.hostname {
                                            Text(name)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        if host.hasDNS {
                                            Text("DNS")
                                                .font(.caption2)
                                                .foregroundColor(.blue)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.blue.opacity(0.1))
                                                .cornerRadius(3)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(4)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    Text("\(scannedHosts.count) \(networkManager.tr("hosts")) — \(networkManager.tr("Tap to select"))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text(networkManager.tr("Language:"))
                Picker("", selection: $networkManager.language) {
                    Text(networkManager.tr("English")).tag(NetworkManager.Language.english)
                    Text(networkManager.tr("Chinese")).tag(NetworkManager.Language.chinese)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                Button(networkManager.tr("Cancel")) {
                    scanTask?.cancel()
                    closeSettings()
                }
                Button(networkManager.tr("Save")) {
                    let trimmed = ipAddress.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        networkManager.passthroughIP = trimmed
                    }
                    closeSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(ipAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Spacer()
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            ipAddress = networkManager.passthroughIP
        }
        .onDisappear {
            scanTask?.cancel()
        }
    }

    private func startScan() {
        scanTask?.cancel()
        isScanning = true
        scannedHosts = []
        scanTask = Task {
            let hosts = await networkManager.scanLocalNetwork()
            if !Task.isCancelled {
                scannedHosts = hosts
                isScanning = false
            }
        }
    }
}
