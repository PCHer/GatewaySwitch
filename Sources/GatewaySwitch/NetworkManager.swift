import Foundation
import os.lock
import AppKit

@MainActor
class NetworkManager: ObservableObject {
    static let defaultsKey = "passthroughIP"
    static let langKey = "language"

    enum Language: String, CaseIterable {
        case english = "en"
        case chinese = "zh"
    }

    enum Mode: Equatable {
        case normal
        case passthrough
        case unknown
    }

    @Published var currentDNS = ""
    @Published var currentGateway = ""
    @Published var currentMode: Mode = .unknown
    @Published var isSwitching = false
    @Published var errorMessage: String?
    @Published var publicIP = ""
    @Published var region = ""
    @Published var passthroughIP: String {
        didSet {
            UserDefaults.standard.set(passthroughIP, forKey: Self.defaultsKey)
        }
    }
    @Published var language: Language {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.langKey)
        }
    }

    private var activeServices: [String] = []
    private var refreshTimer: Timer?

    init() {
        passthroughIP = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "192.168.1.147"
        let langRaw = UserDefaults.standard.string(forKey: Self.langKey) ?? "en"
        language = Language(rawValue: langRaw) ?? .english
        currentDNS = Self.localized("Loading...", lang: language)
        currentGateway = Self.localized("Loading...", lang: language)
        publicIP = Self.localized("Fetching...", lang: language)
        Task {
            await refresh()
            await fetchPublicIPInfo()
        }
        startPeriodicRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.refresh()
                await self.fetchPublicIPInfo()
            }
        }
    }

    func tr(_ key: String) -> String {
        Self.localized(key, lang: language)
    }

    static func localized(_ key: String, lang: Language) -> String {
        let table: [String: [Language: String]] = [
            "Loading...":       [.english: "Loading...",       .chinese: "加载中..."],
            "Fetching...":      [.english: "Fetching...",      .chinese: "获取中..."],
            "DHCP (Auto)":      [.english: "DHCP (Auto)",      .chinese: "DHCP (自动)"],
            "Error":            [.english: "Error",            .chinese: "错误"],
            "Not found":        [.english: "Not found",        .chinese: "未找到"],
            "Unknown":          [.english: "Unknown",          .chinese: "未知"],
            "DNS:":             [.english: "DNS:",             .chinese: "DNS:"],
            "Gateway:":         [.english: "Gateway:",         .chinese: "网关:"],
            "Public IP:":       [.english: "Public IP:",       .chinese: "公网 IP:"],
            "Region:":          [.english: "Region:",          .chinese: "地区:"],
            "Normal Mode":      [.english: "Normal Mode",      .chinese: "正常模式"],
            "Passthrough Mode": [.english: "Passthrough Mode", .chinese: "旁路由模式"],
            "Refresh":          [.english: "Refresh",          .chinese: "刷新"],
            "Settings...":      [.english: "Settings...",      .chinese: "设置..."],
            "Quit":             [.english: "Quit",             .chinese: "退出"],
            "Settings":         [.english: "Settings",         .chinese: "设置"],
            "IP Address:":      [.english: "IP Address:",      .chinese: "IP 地址:"],
            "Cancel":           [.english: "Cancel",           .chinese: "取消"],
            "Save":             [.english: "Save",             .chinese: "保存"],
            "Language:":        [.english: "Language:",        .chinese: "语言:"],
            "English":          [.english: "English",          .chinese: "英文"],
            "Chinese":          [.english: "Chinese",          .chinese: "中文"],
            "Scan Network":     [.english: "Scan Network",     .chinese: "扫描网络"],
            "Scanning...":      [.english: "Scanning...",      .chinese: "扫描中..."],
            "No hosts found":   [.english: "No hosts found",   .chinese: "未发现主机"],
            "hosts":            [.english: "hosts",            .chinese: "个主机"],
            "Tap to select":    [.english: "Tap to select",    .chinese: "点击选择"],
            "DNS":              [.english: "DNS",              .chinese: "DNS"],
        ]
        return table[key]?[lang] ?? key
    }

    struct ScannedHost: Identifiable, Equatable {
        let id = UUID()
        let ip: String
        var hostname: String?
        var hasDNS: Bool
        var isARP: Bool
    }

    func scanLocalNetwork() async -> [ScannedHost] {
        var hosts = [String: ScannedHost]()
        let (_, _, routerIP) = await getSubnetInfo()
        let routerIPStr = routerIP ?? ""
        let table = await arpTable()
        for (ip, _) in table {
            if ip != routerIPStr && ip != "127.0.0.1" {
                hosts[ip] = ScannedHost(ip: ip, hostname: nil, hasDNS: false, isARP: true)
            }
        }
        let ips = Array(hosts.keys)
        let hostnames = await resolveHostnames(ips)
        let dnsResults = await checkPorts(ips: ips, port: 53)

        for (ip, name) in hostnames {
            hosts[ip]?.hostname = name
        }
        for ip in dnsResults {
            hosts[ip]?.hasDNS = true
        }

        return hosts.values.sorted { a, b in
            let aParts = a.ip.split(separator: ".").compactMap { Int($0) }
            let bParts = b.ip.split(separator: ".").compactMap { Int($0) }
            for (aP, bP) in zip(aParts, bParts) where aP != bP { return aP < bP }
            return aParts.count < bParts.count
        }
    }

    private func getSubnetInfo() async -> (ip: String?, mask: String?, router: String?) {
        let service = activeServices.first ?? "Wi-Fi"
        guard let output = await shell("/usr/sbin/networksetup", "-getinfo", service) else { return (nil, nil, nil) }
        var ip: String?, mask: String?, router: String?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("ip address:") {
                ip = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("subnet mask:") {
                mask = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("router:") {
                router = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        return (ip, mask, router)
    }

    private func arpTable() async -> [(ip: String, mac: String)] {
        guard let output = await shell("/usr/sbin/arp", "-a") else { return [] }
        var results = [(String, String)]()
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = try? NSRegularExpression(pattern: #"\? \((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F:]+) on"#)
                    .firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let ipRange = Range(match.range(at: 1), in: trimmed),
                  let macRange = Range(match.range(at: 2), in: trimmed) else { continue }
            results.append((String(trimmed[ipRange]), String(trimmed[macRange])))
        }
        return results
    }

    private func checkPorts(ips: [String], port: Int) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            var open = [String]()
            var remaining = ips
            let limit = 8
            for _ in 0..<min(limit, remaining.count) {
                let ip = remaining.removeFirst()
                group.addTask { await self.checkPort(ip: ip, port: port) ? ip : nil }
            }
            for await result in group {
                if Task.isCancelled { break }
                if let ip = result { open.append(ip) }
                if !remaining.isEmpty {
                    let ip = remaining.removeFirst()
                    group.addTask { await self.checkPort(ip: ip, port: port) ? ip : nil }
                }
            }
            return open
        }
    }

    private func checkPort(ip: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["-z", "-w", "3", ip, String(port)]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    private func resolveHostnames(_ ips: [String]) async -> [String: String] {
        var result = [String: String]()
        for ip in ips {
            if Task.isCancelled { break }
            guard let output = await shell("/usr/bin/host", ip, timeout: 5) else { continue }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = try? NSRegularExpression(pattern: #"domain name pointer (.+)\."#)
                    .firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let nameRange = Range(match.range(at: 1), in: trimmed) {
                result[ip] = String(trimmed[nameRange])
            }
        }
        return result
    }

    func refresh() async {
        activeServices = await detectActiveServices()
        currentDNS = await getCurrentDNSText()
        currentGateway = await getCurrentGatewayText()
        currentMode = detectMode()
    }

    func switchToNormal() async {
        guard !isSwitching else { return }
        isSwitching = true
        errorMessage = nil

        let services = activeServices.isEmpty ? ["Wi-Fi"] : activeServices
        let cmds = services.flatMap { s in
            let a = shellArg(s)
            return ["/usr/sbin/networksetup -setdhcp \(a)", "/usr/sbin/networksetup -setdnsservers \(a) empty"]
        }
        let script = cmds.joined(separator: " && ")
        var errors = [String]()
        if let e = runPrivilegedScript(script) { errors.append(e) }
        finish(errors: errors)
    }

    func switchToPassthrough() async {
        guard !isSwitching else { return }
        isSwitching = true
        errorMessage = nil

        let service = activeServices.first ?? "Wi-Fi"
        let (currentIP, currentMask, _) = await getSubnetInfo()
        guard let ip = currentIP, let mask = currentMask else {
            errorMessage = "Failed to read current IP/mask"
            isSwitching = false
            return
        }

        let a = { self.shellArg($0) }
        let script = "/usr/sbin/networksetup -setmanual \(a(service)) \(a(ip)) \(a(mask)) \(a(passthroughIP)) && /usr/sbin/networksetup -setdnsservers \(a(service)) \(a(passthroughIP))"
        var errors = [String]()
        if let e = runPrivilegedScript(script) { errors.append(e) }
        finish(errors: errors)
    }

    private func finish(errors: [String]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            Task {
                await self.refresh()
                self.isSwitching = false
                await self.fetchPublicIPInfo()
                if !errors.isEmpty {
                    self.errorMessage = errors.joined(separator: "\n")
                }
            }
        }
    }

    func fetchPublicIPInfo() async {
        guard let url = URL(string: "http://ip-api.com/json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let ip = json["query"] as? String ?? "Unknown"
            let country = json["country"] as? String ?? ""
            let city = json["city"] as? String ?? ""
            let isp = json["isp"] as? String ?? ""
            let parts = [city, country].filter { !$0.isEmpty }
            let regionStr = parts.isEmpty ? "" : parts.joined(separator: ", ")
            publicIP = ip
            region = isp.isEmpty ? regionStr : "\(regionStr) — \(isp)"
        } catch {
            // ignore
        }
    }

    private func detectActiveServices() async -> [String] {
        let output = await shell("/usr/sbin/networksetup", "-listallnetworkservices")
        guard let lines = output?.components(separatedBy: .newlines) else { return [] }
        var services = [String]()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("*"), !trimmed.hasPrefix("An asterisk") else { continue }
            if let info = await shell("/usr/sbin/networksetup", "-getinfo", trimmed),
               info.contains("IP address:") && !info.contains("IPv6") {
                services.append(trimmed)
            }
        }
        return services
    }

    private func getCurrentDNSText() async -> String {
        let service = activeServices.first ?? "Wi-Fi"
        guard let output = await shell("/usr/sbin/networksetup", "-getdnsservers", service) else { return "Error" }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().contains("there aren't any") {
            return "DHCP (Auto)"
        }
        return trimmed
    }

    private func getCurrentGatewayText() async -> String {
        let service = activeServices.first ?? "Wi-Fi"
        guard let output = await shell("/usr/sbin/networksetup", "-getinfo", service) else { return "Error" }
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("router:") {
                let r = trimmed.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                return r.isEmpty ? "Not found" : r
            }
        }
        return "Not found"
    }

    private func detectMode() -> Mode {
        if currentGateway == tr("Loading...") || currentDNS == tr("Loading...") {
            return .unknown
        }
        if currentGateway == passthroughIP {
            return .passthrough
        }
        if currentDNS == "DHCP (Auto)" || currentDNS.contains("there aren't any") {
            return .normal
        }
        if currentGateway != passthroughIP && !currentGateway.contains("Error") && !currentGateway.contains("Not found") {
            return .normal
        }
        return .unknown
    }

    // MARK: - Shell helpers

    @discardableResult
    private nonisolated func shell(_ command: String..., timeout: TimeInterval = 10) async -> String? {
        guard let executable = command.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe

        return await withCheckedContinuation { continuation in
            final class ResumedFlag: @unchecked Sendable {
                var value = false
                let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
                init() { lock.pointee = os_unfair_lock() }
                deinit { lock.deallocate() }
            }
            let flag = ResumedFlag()

            process.terminationHandler = { _ in
                os_unfair_lock_lock(flag.lock)
                let already = flag.value
                flag.value = true
                os_unfair_lock_unlock(flag.lock)
                guard !already else { return }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }

            do {
                try process.run()
            } catch {
                os_unfair_lock_lock(flag.lock)
                let already = flag.value
                flag.value = true
                os_unfair_lock_unlock(flag.lock)
                guard !already else { return }
                continuation.resume(returning: nil)
                return
            }

            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    os_unfair_lock_lock(flag.lock)
                    let already = flag.value
                    flag.value = true
                    os_unfair_lock_unlock(flag.lock)
                    guard !already else { return }
                    process.terminate()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func shellArg(_ arg: String) -> String {
        "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    @discardableResult
    private func runPrivileged(_ command: String, arguments: [String]) -> String? {
        let args = arguments.map(shellArg).joined(separator: " ")
        return runPrivilegedScript("\(command) \(args)")
    }

    @discardableResult
    private func runPrivilegedScript(_ shellCommand: String) -> String? {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
        let asSource = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", asSource]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus != 0 {
                return errText.isEmpty ? "exit code \(process.terminationStatus)" : errText
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
