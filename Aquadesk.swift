import Accelerate
import AppKit
import AudioToolbox
import Carbon.HIToolbox
import OSLog
import CoreAudio
import CoreImage
import CoreLocation
import CoreServices
import CoreWLAN
import Darwin
import DiskArbitration
import EventKit
import IOKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Data

struct LimitWindow: Identifiable {
    let id: String
    let label: String
    let usedPercent: Double?
    let resetsAt: Date?

    var remaining: Double? { usedPercent.map { max(0, min(100, 100 - $0)) } }

    /// A window whose reset time has passed is back to full, however old the reading is.
    func normalized(now: Date = Date()) -> LimitWindow {
        guard let resetsAt, resetsAt < now else { return self }
        return LimitWindow(id: id, label: label, usedPercent: 0, resetsAt: nil)
    }
}

struct ProviderUsage {
    var windows: [LimitWindow] = []
    var updatedAt: Date?
    var note: String?
}

struct MemorySnapshot {
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var total: Double = 1
    var pressure: Int = 1

    var used: Double { app + wired + compressed }
    var fraction: Double { min(1, used / total) }
}

struct MailSnapshot {
    var unread: Int?
    var updatedAt: Date?
    var note: String?
}

// MARK: - Memory

enum MemoryReader {
    static func read() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.total = Double(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Double(getpagesize())
            // Same breakdown Activity Monitor uses for "Memory Used".
            let appPages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            snapshot.app = max(0, appPages) * page
            snapshot.wired = Double(stats.wire_count) * page
            snapshot.compressed = Double(stats.compressor_page_count) * page
        }

        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            snapshot.pressure = Int(level)
        }
        return snapshot
    }
}

// MARK: - Calendar and reminders

enum AgendaAccess: Equatable {
    case pending, granted, denied
}

struct AgendaEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
}

struct AgendaReminder: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?
    let hasTime: Bool
    let color: Color

    func isOverdue(now: Date) -> Bool {
        guard let due else { return false }
        return due < (hasTime ? now : Calendar.current.startOfDay(for: now))
    }
}

struct AgendaSnapshot: Equatable {
    var eventAccess = AgendaAccess.pending
    var events: [AgendaEvent] = []
    var reminderAccess = AgendaAccess.pending
    var reminders: [AgendaReminder] = []
    var reminderCount = 0
}

/// Titles are only held for display; nothing from the calendar store is written or logged.
final class AgendaReader: @unchecked Sendable {
    private static let limit = 3
    private static let lookaheadDays = 7
    private let store = EKEventStore()

    func fetch() async -> AgendaSnapshot {
        var snapshot = AgendaSnapshot()
        snapshot.eventAccess = await access(to: .event)
        if snapshot.eventAccess == .granted {
            snapshot.events = Self.arrange(events(), now: Date())
        }
        snapshot.reminderAccess = await access(to: .reminder)
        if snapshot.reminderAccess == .granted {
            let all = await incompleteReminders()
            snapshot.reminderCount = all.count
            snapshot.reminders = Self.arrange(all)
        }
        return snapshot
    }

    /// Nearest day first, and timed events before all-day ones so holidays don't crowd them out.
    static func arrange(_ events: [AgendaEvent], now: Date) -> [AgendaEvent] {
        let calendar = Calendar.current
        func day(_ event: AgendaEvent) -> Date { calendar.startOfDay(for: max(event.start, now)) }
        let sorted = events.filter { $0.end > now }.sorted { a, b in
            if day(a) != day(b) { return day(a) < day(b) }
            if a.isAllDay != b.isAllDay { return b.isAllDay }
            return a.start < b.start
        }
        return Array(sorted.prefix(limit))
    }

    /// Soonest due first; reminders with no due date come last.
    static func arrange(_ reminders: [AgendaReminder]) -> [AgendaReminder] {
        let sorted = reminders.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        return Array(sorted.prefix(limit))
    }

    private func access(to type: EKEntityType) async -> AgendaAccess {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return .granted
        case .notDetermined:
            let granted: Bool
            if type == .event {
                granted = (try? await store.requestFullAccessToEvents()) ?? false
            } else {
                granted = (try? await store.requestFullAccessToReminders()) ?? false
            }
            if granted { store.reset() }
            return granted ? .granted : .denied
        default:
            return .denied
        }
    }

    private func events() -> [AgendaEvent] {
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: Self.lookaheadDays, to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled else { return nil }
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            guard !declined else { return nil }
            return AgendaEvent(
                // Occurrences of a repeating event share an identifier.
                id: "\(event.eventIdentifier ?? "")-\(event.startDate.timeIntervalSince1970)",
                title: Self.title(event.title),
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                color: Color(cgColor: event.calendar.cgColor))
        }
    }

    private func incompleteReminders() async -> [AgendaReminder] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { reminder -> AgendaReminder in
                    let components = reminder.dueDateComponents
                    return AgendaReminder(
                        id: reminder.calendarItemIdentifier,
                        title: Self.title(reminder.title),
                        due: components.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) },
                        hasTime: components?.hour != nil,
                        color: Color(cgColor: reminder.calendar.cgColor))
                }
                continuation.resume(returning: items)
            }
        }
    }

    private static func title(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "（タイトルなし）" : trimmed
    }
}

// MARK: - Wi-Fi and Bluetooth

struct WiFiStatus: Equatable {
    var hasInterface = false
    var isOn = false
    var isConnected = false
    var rssi = 0
    var rate = 0.0
    var name: String?
}

struct BluetoothDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let battery: String?
    let lowestBattery: Int?
}

struct BluetoothStatus: Equatable {
    var isOn: Bool?
    var devices: [BluetoothDevice] = []
}

/// macOS only reveals the Wi-Fi network name to apps with Location access. This holds that
/// permission and nothing more: no location updates are ever requested or read.
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onChange: (Bool?) -> Void

    /// `onChange` gets true when allowed, false when refused and nil while undecided.
    init(onChange: @escaping (Bool?) -> Void) {
        self.onChange = onChange
        super.init()
        manager.delegate = self
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            onChange(nil)
        case .authorizedAlways, .authorizedWhenInUse:
            onChange(true)
        default:
            onChange(false)
        }
    }
}

enum WiFiReader {
    static func read() -> WiFiStatus {
        guard let interface = CWWiFiClient.shared().interface() else { return WiFiStatus() }
        let rate = interface.transmitRate()
        return WiFiStatus(
            hasInterface: true, isOn: interface.powerOn(), isConnected: rate > 0,
            rssi: interface.rssiValue(), rate: rate, name: interface.ssid())
    }
}

/// `system_profiler` needs no Bluetooth permission and includes the battery levels devices report.
enum BluetoothReader {
    static func read() -> BluetoothStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return BluetoothStatus() }
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return parse(data)
    }

    static func parse(_ data: Data) -> BluetoothStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = (root["SPBluetoothDataType"] as? [[String: Any]])?.first
        else { return BluetoothStatus() }
        var status = BluetoothStatus()
        if let state = (info["controller_properties"] as? [String: Any])?["controller_state"] as? String {
            status.isOn = state == "attrib_on"
        }
        let connected = info["device_connected"] as? [[String: [String: Any]]] ?? []
        for (index, entry) in connected.enumerated() {
            for (name, properties) in entry {
                let (text, lowest) = battery(properties)
                status.devices.append(BluetoothDevice(id: "\(index)-\(name)", name: name, battery: text, lowestBattery: lowest))
            }
        }
        return status
    }

    private static func battery(_ properties: [String: Any]) -> (String?, Int?) {
        func level(_ key: String) -> Int? {
            (properties[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
        }
        let main = level("device_batteryLevelMain"), left = level("device_batteryLevelLeft"),
            right = level("device_batteryLevelRight")
        if left != nil || right != nil {
            let parts = [left.map { "左 \($0)%" }, right.map { "右 \($0)%" }].compactMap { $0 }
            return (parts.joined(separator: " "), [left, right].compactMap { $0 }.min())
        }
        return (main.map { "\($0)%" }, main)
    }
}

// MARK: - External storage

struct ExternalVolume: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: Int64?
    let available: Int64?

    var id: URL { url }
}

enum VolumeReader {
    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsEjectableKey,
        .volumeIsRemovableKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    /// Physically attached local drives. Network shares are left out because they can stall when
    /// the server is unreachable; disk images because they are files, not connected storage.
    static func read() -> [ExternalVolume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> ExternalVolume? in
            guard url.path != "/", let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true,
                  values.volumeIsInternal != true || values.volumeIsEjectable == true || values.volumeIsRemovable == true,
                  !isDiskImage(url)
            else { return nil }
            return ExternalVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                total: values.volumeTotalCapacity.map(Int64.init),
                available: values.volumeAvailableCapacity.map(Int64.init))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
        return model?.trimmingCharacters(in: .whitespaces) == "Disk Image"
    }
}

// MARK: - CPU

/// Share of all cores in use since the previous sample, the figure Activity Monitor shows as
/// System + User. Ticks are cumulative, so the first sample only sets the baseline.
final class CPUMeter {
    private var last: (busy: UInt32, total: UInt32)?

    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = info.cpu_ticks
        let busy = ticks.0 &+ ticks.1 &+ ticks.3  // user, system, nice
        let total = busy &+ ticks.2  // plus idle
        defer { last = (busy, total) }
        guard let last else { return nil }

        // Wrapping subtraction keeps the delta right when a 32-bit counter rolls over.
        let elapsed = total &- last.total
        guard elapsed > 0 else { return nil }
        return min(1, Double(busy &- last.busy) / Double(elapsed))
    }
}

// MARK: - GPU

enum GPUMeter {
    /// The driver's own utilization figure, read from the IORegistry. The key isn't a documented
    /// API, so a driver without it just yields nil. With several GPUs, the busiest one counts.
    static func read() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var busiest: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            guard let statistics = property as? [String: Any],
                  let percent = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue
            else { continue }
            busiest = max(busiest ?? 0, min(1, percent / 100))
        }
        return busiest
    }
}

struct DiskTotals: Equatable {
    var read: Int64 = 0
    var written: Int64 = 0
}

/// Cumulative since startup, from each disk driver's counters. A disk's counters leave with it,
/// so ejecting an external drive lowers the total. Disk images are skipped: their traffic also
/// passes through the disk that holds the image, and would be counted twice.
enum DiskMeter {
    static func read() -> DiskTotals? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var totals: DiskTotals?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard !isDiskImage(service) else { continue }
            let property = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            guard let statistics = property as? [String: Any],
                  let read = (statistics["Bytes (Read)"] as? NSNumber)?.int64Value,
                  let written = (statistics["Bytes (Write)"] as? NSNumber)?.int64Value
            else { continue }
            var sum = totals ?? DiskTotals()
            sum.read += read
            sum.written += written
            totals = sum
        }
        return totals
    }

    static func parentClass(of service: io_object_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return IOObjectCopyClass(parent)?.takeRetainedValue() as String?
    }

    private static func isDiskImage(_ service: io_object_t) -> Bool {
        parentClass(of: service)?.contains("DiskImage") ?? false
    }
}

// MARK: - Codex

enum CodexReader {
    private static let needle = Data("\"rate_limits\"".utf8)
    private static let tailBytes: UInt64 = 4 * 1024 * 1024

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func read() -> ProviderUsage {
        // File modification time is not enough: a resumed session gets touched while its
        // last limit event is weeks old, so the newest event timestamp decides.
        var best: (date: Date, limits: [String: Any])?
        for url in recentSessionFiles(limit: 8) {
            guard let event = lastEvent(in: url) else { continue }
            if best == nil || event.date > best!.date { best = event }
        }
        guard let best else {
            return ProviderUsage(note: "Codexのログが見つかりません")
        }

        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = best.limits[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
            let resets = (window["resets_at"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            windows.append(
                LimitWindow(id: key, label: label(forMinutes: minutes), usedPercent: used, resetsAt: resets)
                    .normalized())
        }
        return ProviderUsage(windows: windows, updatedAt: best.date)
    }

    static func label(forMinutes minutes: Int) -> String {
        switch minutes {
        case 10080: return "週間"
        case 300: return "5時間"
        case let value where value >= 60: return "\(value / 60)時間"
        default: return "\(minutes)分"
        }
    }

    private static func recentSessionFiles(limit: Int) -> [URL] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

        func children(_ url: URL) -> [URL] {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return items.sorted { $0.lastPathComponent > $1.lastPathComponent }
        }

        var files: [(url: URL, modified: Date)] = []
        var daysVisited = 0
        walk: for year in children(root) {
            for month in children(year) {
                for day in children(month) {
                    for file in children(day) where file.pathExtension == "jsonl" {
                        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        files.append((file, values?.contentModificationDate ?? .distantPast))
                    }
                    daysVisited += 1
                    if daysVisited >= 14 { break walk }
                }
            }
        }
        return files.sorted { $0.modified > $1.modified }.prefix(limit).map(\.url)
    }

    private static func lastEvent(in url: URL) -> (date: Date, limits: [String: Any])? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in data.split(separator: 0x0A).reversed() where line.range(of: needle) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any],
                  let stamp = object["timestamp"] as? String,
                  let date = isoFractional.date(from: stamp)
            else { continue }
            if let id = limits["limit_id"] as? String, id != "codex" { continue }
            return (date, limits)
        }
        return nil
    }
}

/// Asks Codex itself through `codex app-server`, which also sees usage from other devices
/// that never reaches this Mac's logs. Codex handles its own login, so no token is read here.
enum CodexLiveReader {
    private final class Box: @unchecked Sendable {
        var result: Result<ProviderUsage, CredentialError> = .failure(CredentialError(message: "応答なし"))
    }

    static func fetch(timeout: TimeInterval = 30) -> Result<ProviderUsage, CredentialError> {
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server"]
        // Apps opened from Finder don't inherit the shell's PATH, and codex is a node script.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        let inherited = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "\(home)/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:\(inherited)"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(CredentialError(message: "codexを起動できません"))
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        func send(_ message: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            data.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: data)
        }

        send([
            "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "aquadesk", "title": "Aquadesk", "version": AppInfo.version]],
        ])

        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { finished.signal() }
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                    else { continue }
                    switch (message["id"] as? NSNumber)?.intValue {
                    case 1:
                        send(["method": "initialized"])
                        send(["id": 2, "method": "account/rateLimits/read"])
                    case 2:
                        box.result = parse(message)
                        return
                    default:
                        continue
                    }
                }
            }
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            return .failure(CredentialError(message: "応答がタイムアウト"))
        }
        return box.result
    }

    static func parse(_ message: [String: Any], now: Date = Date()) -> Result<ProviderUsage, CredentialError> {
        guard let result = message["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any]
        else { return .failure(CredentialError(message: "応答の形式が想定と異なります")) }

        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue
            else { continue }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let resets = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(LimitWindow(
                id: key, label: CodexReader.label(forMinutes: minutes), usedPercent: used, resetsAt: resets))
        }
        guard !windows.isEmpty else { return .failure(CredentialError(message: "枠の情報がありません")) }
        return .success(ProviderUsage(windows: windows, updatedAt: now))
    }
}

// MARK: - Claude

struct ClaudeReading: Codable {
    var fetchedAt: Date
    var fiveHourUsed: Double?
    var fiveHourResets: Date?
    var sevenDayUsed: Double?
    var sevenDayResets: Date?
}

enum ClaudeFetch {
    case success(ClaudeReading)
    case failure(String)
}

enum ClaudeReader {
    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aquadesk/claude-usage.json")
    }

    /// Reads the current token only; refreshing it would rotate Claude Code's own login.
    static func fetch() async -> ClaudeFetch {
        let credentials: (token: String, expiresAt: Date?)
        switch readCredentials() {
        case .success(let value): credentials = value
        case .failure(let error): return .failure(error.message)
        }
        if let expiry = credentials.expiresAt, expiry < Date() {
            return .failure("トークン期限切れ・Claude Code起動で復帰")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .failure(status == 401 ? "トークン期限切れ・Claude Code起動で復帰" : "取得エラー (HTTP \(status))")
            }
            guard let reading = parse(data, fetchedAt: Date()) else {
                return .failure("API応答の形式が想定と異なります")
            }
            save(reading)
            return .success(reading)
        } catch {
            return .failure("ネットワークエラー")
        }
    }

    static func parse(_ data: Data, fetchedAt: Date) -> ClaudeReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func window(_ key: String) -> (used: Double?, resets: Date?) {
            guard let value = root[key] as? [String: Any] else { return (nil, nil) }
            let used = (value["utilization"] as? NSNumber)?.doubleValue
            let resets = (value["resets_at"] as? String).flatMap(parseDate)
            return (used, resets)
        }

        let five = window("five_hour")
        let seven = window("seven_day")
        guard five.used != nil || seven.used != nil else { return nil }
        return ClaudeReading(
            fetchedAt: fetchedAt, fiveHourUsed: five.used, fiveHourResets: five.resets,
            sevenDayUsed: seven.used, sevenDayResets: seven.resets)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Picks the fresher of the last API reading and the Claude app's local history, per window.
    static func merged(apiNote: String?) -> ProviderUsage {
        let cached = loadCache()
        let local = loadLocalHistory()
        let now = Date()

        func pick(
            id: String, label: String, apiUsed: Double?, apiResets: Date?,
            localUsed: Double?, maxAge: TimeInterval
        ) -> (LimitWindow, Date?) {
            let apiDate = apiUsed == nil ? nil : cached?.fetchedAt
            var localDate = localUsed == nil ? nil : local?.date
            if let date = localDate, now.timeIntervalSince(date) > maxAge { localDate = nil }

            if let localDate, apiDate == nil || localDate > apiDate! {
                return (LimitWindow(id: id, label: label, usedPercent: localUsed, resetsAt: nil), localDate)
            }
            if let apiDate {
                let window = LimitWindow(id: id, label: label, usedPercent: apiUsed, resetsAt: apiResets)
                return (window.normalized(now: now), apiDate)
            }
            return (LimitWindow(id: id, label: label, usedPercent: nil, resetsAt: nil), nil)
        }

        let five = pick(
            id: "five", label: "5時間", apiUsed: cached?.fiveHourUsed, apiResets: cached?.fiveHourResets,
            localUsed: local?.fiveHour, maxAge: 5 * 3600)
        let seven = pick(
            id: "seven", label: "週間", apiUsed: cached?.sevenDayUsed, apiResets: cached?.sevenDayResets,
            localUsed: local?.sevenDay, maxAge: 7 * 86400)

        return ProviderUsage(
            windows: [five.0, seven.0],
            updatedAt: [five.1, seven.1].compactMap { $0 }.max(),
            note: apiNote)
    }

    private static func readCredentials() -> Result<(token: String, expiresAt: Date?), CredentialError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failure(CredentialError(message: "キーチェーンを読めません"))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else {
            return .failure(CredentialError(message: "Claude Codeのログイン情報がありません"))
        }
        let expiry = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return .success((token, expiry))
    }

    private static func loadLocalHistory() -> (date: Date, fiveHour: Double?, sevenDay: Double?)? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]],
              let last = samples.max(by: {
                  (($0["t"] as? NSNumber)?.doubleValue ?? 0) < (($1["t"] as? NSNumber)?.doubleValue ?? 0)
              }),
              let time = (last["t"] as? NSNumber)?.doubleValue,
              let usage = last["u"] as? [String: Any]
        else { return nil }
        return (
            Date(timeIntervalSince1970: time / 1000),
            (usage["fh"] as? NSNumber)?.doubleValue,
            (usage["sd"] as? NSNumber)?.doubleValue
        )
    }

    private static func loadCache() -> ClaudeReading? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeReading.self, from: data)
    }

    static func save(_ reading: ClaudeReading) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(reading) else { return }
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

struct CredentialError: Error {
    let message: String
}

// MARK: - Shortcuts

/// A file or app, a web address, a Shortcuts.app shortcut, a work set (several items opened
/// together), or a launcher: a named ring of further shortcuts, which may hold launchers of its
/// own. Older saves have only the first two fields and still decode.
struct Shortcut: Codable, Equatable {
    enum Kind {
        case file, launcher, link, workflow, group
    }

    var bookmark: Data?
    var path: String
    var name: String?
    var items: [Shortcut]?
    var link: String?
    /// The name of a shortcut in Shortcuts.app.
    var workflow: String?
    var group: [Shortcut]?

    static func launcher(named name: String) -> Shortcut {
        Shortcut(bookmark: nil, path: "", name: name, items: [])
    }

    static func file(_ url: URL) -> Shortcut? {
        (try? url.bookmarkData()).map { Shortcut(bookmark: $0, path: url.path) }
    }

    var kind: Kind {
        if items != nil { return .launcher }
        if link != nil { return .link }
        if workflow != nil { return .workflow }
        if group != nil { return .group }
        return .file
    }

    var isLauncher: Bool { items != nil }

    var displayName: String {
        switch kind {
        case .launcher: return name ?? "ランチャー"
        case .link: return name ?? link.flatMap { URL(string: $0)?.host } ?? link ?? "URL"
        case .workflow: return name ?? workflow ?? "ショートカット"
        case .group: return name ?? "作業セット"
        case .file: return url.map { FileManager.default.displayName(atPath: $0.path) } ?? "見つかりません"
        }
    }

    /// A bookmark keeps working after the item is moved or renamed; the path is the fallback.
    var url: URL? {
        guard kind == .file, let bookmark else { return nil }
        var stale = false
        let resolved = try? URL(
            resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        if let resolved { return resolved }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}

/// Opens whatever a shortcut stands for. Launchers aren't opened here: they need a ring.
@MainActor
enum ShortcutRunner {
    @discardableResult
    static func run(_ shortcut: Shortcut) -> Bool {
        switch shortcut.kind {
        case .file:
            guard let url = shortcut.url else { return false }
            return NSWorkspace.shared.open(url)
        case .link:
            guard let link = shortcut.link, let url = URL(string: link) else { return false }
            return NSWorkspace.shared.open(url)
        case .workflow:
            guard let name = shortcut.workflow else { return false }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return (try? process.run()) != nil
        case .group:
            let results = (shortcut.group ?? []).map { run($0) }
            return results.contains(true)
        case .launcher:
            return false
        }
    }
}

enum AddKind: String, CaseIterable {
    case files, link, workflow, group, launcher

    var title: String {
        switch self {
        case .files: return "アプリ・ファイル…"
        case .link: return "URL…"
        case .workflow: return "ショートカット（ショートカット.app）…"
        case .group: return "作業セット（まとめて開く）…"
        case .launcher: return "ランチャー…"
        }
    }
}

/// Asks for the details of a new item. Gives an empty list when cancelled.
@MainActor
enum ItemPrompt {
    static func make(_ kind: AddKind, multiple: Bool, completion: @escaping @MainActor ([Shortcut]) -> Void) {
        switch kind {
        case .files:
            choose("登録する項目を選んでください", multiple: multiple) { urls in
                completion(urls.compactMap(Shortcut.file))
            }
        case .link:
            completion(link().map { [$0] } ?? [])
        case .workflow:
            completion(workflow().map { [$0] } ?? [])
        case .group:
            choose("まとめて開く項目を選んでください（複数可）", multiple: true) { urls in
                let members = urls.compactMap(Shortcut.file)
                guard !members.isEmpty, let name = NamePrompt.ask("作業セットの名前", initial: "作業セット") else {
                    completion([])
                    return
                }
                completion([Shortcut(bookmark: nil, path: "", name: name, group: members)])
            }
        case .launcher:
            completion(NamePrompt.ask("新しいランチャーの名前", initial: "ランチャー").map { [.launcher(named: $0)] } ?? [])
        }
    }

    private static func choose(_ message: String, multiple: Bool, completion: @escaping @MainActor ([URL]) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.message = message
        panel.prompt = "追加"
        panel.begin { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.urls : []) }
        }
    }

    private static func link() -> Shortcut? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "URLを追加"
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        let address = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        address.placeholderString = "https://…"
        let title = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        title.placeholderString = "名前（省略可）"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        box.addSubview(address)
        box.addSubview(title)
        alert.accessoryView = box
        alert.window.initialFirstResponder = address
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var text = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard URL(string: text) != nil else {
            NSSound.beep()
            return nil
        }
        let name = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Shortcut(bookmark: nil, path: "", name: name.isEmpty ? nil : name, link: text)
    }

    static func shortcutNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func workflow() -> Shortcut? {
        NSApp.activate(ignoringOtherApps: true)
        let names = shortcutNames()
        let alert = NSAlert()
        guard !names.isEmpty else {
            alert.messageText = "ショートカット.appにショートカットがありません"
            alert.runModal()
            return nil
        }
        alert.messageText = "実行するショートカットを選んでください"
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popup.addItems(withTitles: names)
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn, let name = popup.titleOfSelectedItem else { return nil }
        return Shortcut(bookmark: nil, path: "", workflow: name)
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    static let slotCount = 8
    /// Twelve fit around one ring without crowding.
    static let launcherLimit = 12
    private static let defaultsKey = "shortcuts"

    @Published private(set) var slots: [Shortcut?]
    var persists = true

    init() {
        var loaded = [Shortcut?](repeating: nil, count: Self.slotCount)
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Shortcut?].self, from: data) {
            for (index, slot) in saved.prefix(Self.slotCount).enumerated() { loaded[index] = slot }
        }
        slots = loaded
    }

    func assign(_ url: URL, to index: Int) {
        guard let bookmark = try? url.bookmarkData() else { return }
        slots[index] = Shortcut(bookmark: bookmark, path: url.path)
        save()
    }

    func remove(_ index: Int) {
        slots[index] = nil
        save()
    }

    /// Onto an empty slot this is a move; onto a filled one, the two trade places.
    func move(from source: Int, to destination: Int) {
        guard source != destination, slots.indices.contains(source), slots.indices.contains(destination) else { return }
        slots.swapAt(source, destination)
        save()
    }

    /// A path is a slot index followed by item indices, one per launcher level.
    /// Filled slots in order: what the ring opened by the hotkey shows.
    var filledSlots: [Int] { slots.indices.filter { slots[$0] != nil } }

    /// The path of an item shown in the ring at `path`; the hotkey's ring (an empty path) lists slots.
    func childPath(_ path: [Int], _ index: Int) -> [Int]? {
        guard path.isEmpty else { return path + [index] }
        let filled = filledSlots
        return filled.indices.contains(index) ? [filled[index]] : nil
    }

    func item(at path: [Int]) -> Shortcut? {
        if path.isEmpty {
            return Shortcut(bookmark: nil, path: "", name: "ショートカット", items: filledSlots.compactMap { slots[$0] })
        }
        guard let first = path.first, slots.indices.contains(first), var current = slots[first] else { return nil }
        for index in path.dropFirst() {
            guard let items = current.items, items.indices.contains(index) else { return nil }
            current = items[index]
        }
        return current
    }

    private static func modify(_ shortcut: inout Shortcut, _ rest: ArraySlice<Int>, _ body: (inout Shortcut) -> Void) {
        guard let first = rest.first else {
            body(&shortcut)
            return
        }
        guard var items = shortcut.items, items.indices.contains(first) else { return }
        modify(&items[first], rest.dropFirst(), body)
        shortcut.items = items
    }

    private func update(_ path: [Int], _ body: (inout Shortcut) -> Void) {
        guard let first = path.first, slots.indices.contains(first), var slot = slots[first] else { return }
        Self.modify(&slot, path.dropFirst(), body)
        slots[first] = slot
        save()
    }

    func createLauncher(at index: Int, name: String) {
        slots[index] = .launcher(named: name)
        save()
    }

    /// Anything past the limit is left out with a beep.
    func addItems(_ urls: [URL], to path: [Int]) {
        let entries = urls.compactMap { url in
            (try? url.bookmarkData()).map { Shortcut(bookmark: $0, path: url.path) }
        }
        add(entries, to: path)
    }

    func addLauncher(named name: String, to path: [Int]) {
        add([.launcher(named: name)], to: path)
    }

    func put(_ shortcut: Shortcut, in index: Int) {
        slots[index] = shortcut
        save()
    }

    func add(_ entries: [Shortcut], to path: [Int]) {
        guard let current = item(at: path)?.items else { return }
        let room = max(0, Self.launcherLimit - current.count)
        if entries.count > room { NSSound.beep() }
        guard room > 0, !entries.isEmpty else { return }
        update(path) { $0.items?.append(contentsOf: entries.prefix(room)) }
    }

    func removeItem(at path: [Int]) {
        if path.count == 1 {
            remove(path[0])
            return
        }
        let index = path[path.count - 1]
        update(Array(path.dropLast())) { launcher in
            guard let items = launcher.items, items.indices.contains(index) else { return }
            launcher.items?.remove(at: index)
        }
    }

    func rename(_ path: [Int], to name: String) {
        update(path) { $0.name = name }
    }

    /// Dropping onto a launcher's tile files the item inside it instead of replacing the launcher.
    func drop(_ url: URL, on index: Int) {
        if slots[index]?.isLauncher == true {
            addItems([url], to: [index])
        } else {
            assign(url, to: index)
        }
    }

    func chooseItems(for path: [Int], completion: @escaping @MainActor () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "ランチャーに入れる項目を選んでください（複数可）"
        panel.prompt = "追加"
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK { self?.addItems(panel.urls, to: path) }
                completion()
            }
        }
    }

    func open(_ index: Int) {
        guard let slot = slots[index], ShortcutRunner.run(slot) else {
            NSSound.beep()
            return
        }
    }

    func choose(for index: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "ショートカットに登録する項目を選んでください"
        panel.prompt = "登録"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.assign(url, to: index) }
        }
    }

    private func save() {
        guard persists, let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Pending

struct PendingItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let reason: String
    let since: Date?
}

/// Claude Code keeps one small state file per running session, marked "waiting" while it needs the user.
enum PendingReader {
    static let shownCount = 3

    static func read() -> [PendingItem] {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let items: [PendingItem] = files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["status"] as? String == "waiting",
                  let pid = (root["pid"] as? NSNumber)?.intValue,
                  kill(pid_t(pid), 0) == 0  // A crashed session leaves its file behind.
            else { return nil }
            let cwd = (root["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            return PendingItem(
                id: pid,
                title: (root["name"] as? String) ?? cwd ?? "Claude",
                reason: reasonText(root["waitingFor"] as? String),
                since: (root["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        }
        let sorted = items.sorted { ($0.since ?? .distantPast) > ($1.since ?? .distantPast) }
        return Array(sorted.prefix(shownCount))
    }

    private static func reasonText(_ waitingFor: String?) -> String {
        guard let waitingFor else { return "応答待ち" }
        if waitingFor == "input needed" { return "入力待ち" }
        if waitingFor.lowercased().contains("approv") || waitingFor.lowercased().contains("permission") { return "承認待ち" }
        return waitingFor
    }
}

// MARK: - Mail

/// Asks Mail.app through osascript: NSAppleScript would block the main thread during the
/// permission prompt.
enum MailReader {
    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    // Count only: a `whose` search over the inbox pinned Mail at 100% CPU for minutes.
    private static let script = """
    tell application "Mail"
        with timeout of 15 seconds
            return (unread count of inbox) as text
        end timeout
    end tell
    """

    static func fetch(timeout: TimeInterval = 30) -> MailSnapshot {
        // `tell application` would launch Mail, which a desktop widget must not do.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else {
            return MailSnapshot(note: "メールアプリが起動していません")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return MailSnapshot(note: "メールを読み取れません")
        }

        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return MailSnapshot(note: "メールの応答がタイムアウト")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return MailSnapshot(note: errorNote(message))
        }
        return parse(String(decoding: box.data, as: UTF8.self))
    }

    static func parse(_ text: String, now: Date = Date()) -> MailSnapshot {
        guard let unread = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return MailSnapshot(note: "メールの応答を読み取れません")
        }
        return MailSnapshot(unread: unread, updatedAt: now)
    }

    private static func errorNote(_ message: String) -> String {
        if message.contains("-1743") { return "システム設定のオートメーションでメールを許可してください" }
        if message.contains("-600") { return "メールアプリが起動していません" }
        if let open = message.lastIndex(of: "("), let close = message.lastIndex(of: ")"), open < close {
            return "メールの取得エラー \(message[open...close])"
        }
        return "メールの取得エラー"
    }
}

// MARK: - Media

enum MediaSource: String, Hashable {
    /// The Spotify app, and a streaming site in a Chrome tab.
    case spotify, browser
}

/// What the buttons either side of play/pause do on a site.
enum MediaSkip: Equatable {
    case track
    case seek
    case none
}

/// A streaming site the widget knows. Sites not listed are never touched, so pages such as
/// banking or mail never have script run in them.
struct MediaSite {
    let name: String
    let prefixes: [String]
    var symbol = "play.rectangle.fill"
    var skip = MediaSkip.seek
    /// The site's own buttons, when its player keeps the media element out of reach.
    var playButton: String?
    var nextButton: String?
    var previousButton: String?

    static let all: [MediaSite] = [
        MediaSite(name: "YouTube Music", prefixes: ["https://music.youtube.com/"], symbol: "music.note", skip: .track,
                  nextButton: "ytmusic-player-bar .next-button", previousButton: "ytmusic-player-bar .previous-button"),
        MediaSite(name: "YouTube", prefixes: ["https://www.youtube.com/watch", "https://www.youtube.com/live/", "https://www.youtube.com/shorts/"],
                  skip: .track, nextButton: ".ytp-next-button", previousButton: ".ytp-prev-button"),
        // Netflix's player stops with an error when its position is changed from outside.
        MediaSite(name: "Netflix", prefixes: ["https://www.netflix.com/watch/"], skip: .none),
        MediaSite(name: "Prime Video", prefixes: ["https://www.amazon.co.jp/gp/video/", "https://www.primevideo.com/"]),
        MediaSite(name: "Disney+", prefixes: ["https://www.disneyplus.com/"]),
        MediaSite(name: "U-NEXT", prefixes: ["https://video.unext.jp/"]),
        MediaSite(name: "Hulu", prefixes: ["https://www.hulu.jp/"]),
        MediaSite(name: "ABEMA", prefixes: ["https://abema.tv/"]),
        MediaSite(name: "TVer", prefixes: ["https://tver.jp/"]),
        MediaSite(name: "ニコニコ", prefixes: ["https://www.nicovideo.jp/watch/", "https://live.nicovideo.jp/watch/"]),
        MediaSite(name: "Twitch", prefixes: ["https://www.twitch.tv/"], skip: .none),
        MediaSite(name: "Vimeo", prefixes: ["https://vimeo.com/"]),
        MediaSite(name: "SoundCloud", prefixes: ["https://soundcloud.com/"], symbol: "music.note", skip: .track,
                  playButton: ".playControl", nextButton: ".skipControl__next", previousButton: ".skipControl__previous"),
        MediaSite(name: "Spotify Web", prefixes: ["https://open.spotify.com/"], symbol: "music.note", skip: .track,
                  playButton: "[data-testid=\"control-button-playpause\"]",
                  nextButton: "[data-testid=\"control-button-skip-forward\"]",
                  previousButton: "[data-testid=\"control-button-skip-back\"]"),
    ]

    static func matching(_ url: String) -> MediaSite? {
        all.first { site in site.prefixes.contains { url.hasPrefix($0) } }
    }
}

enum MediaAction: Hashable {
    case previous, playPause, next
}

struct MediaItem: Identifiable, Equatable {
    enum Access: Equatable {
        case controllable
        /// Chrome refuses JavaScript from Apple Events until the user turns that on.
        case browserSettingNeeded
        case automationDenied
    }
    var source: MediaSource
    var title = ""
    var artist = ""
    var isPlaying = false
    var access = Access.controllable
    /// Finds the tab again when a command is sent. Kept in memory only.
    var tabURL: String?
    var siteName = "Chrome"
    var symbol = "music.note"
    var skip = MediaSkip.track
    var id: MediaSource { source }

    var label: String { source == .spotify ? "Spotify" : siteName }
}

/// The Spotify app and the streaming sites in `MediaSite.all` open in Chrome: macOS no longer lets ordinary apps read the system's
/// now-playing information, so each player is asked directly through Apple Events.
enum MediaReader {
    private final class Box: @unchecked Sendable {
        var data = Data()
    }
    private enum ScriptResult {
        case output(String)
        case denied
        case failed
    }

    private static let spotifyID = "com.spotify.client"
    private static let chromeID = "com.google.Chrome"

    /// The page's main media element: a playing one first, and YouTube's own player before previews.
    private static let findMedia = "var all=[].slice.call(document.querySelectorAll('video,audio')).filter(function(e){return e.currentSrc||e.srcObject;});var main=document.querySelector('video.html5-main-video');var v=all.filter(function(e){return !e.paused&&!e.ended;})[0]||(main&&main.currentSrc?main:all[0]);"
    /// Players that hide their media element still report through Media Session.
    private static let stateJS = "(function(){\(findMedia)var s=navigator.mediaSession,m=s&&s.metadata,p=s&&s.playbackState;if(!v&&!(m&&(p==='playing'||p==='paused')))return '';var playing=v?(!v.paused&&!v.ended):p==='playing';return JSON.stringify({playing:playing,title:(m&&m.title)||'',artist:(m&&m.artist)||''});})()"

    private static let spotifyState = """
    tell application id "\(spotifyID)"
        with timeout of 5 seconds
            set state to (player state as text)
            if state is "stopped" then return state
            return state & (character id 10) & (name of current track) & (character id 10) & (artist of current track)
        end timeout
    end tell
    """

    // Only tabs of known sites leave the script; other tabs' addresses are compared here and dropped.
    private static let chromeState = """
    on run argv
        set js to item 1 of argv
        set prefixes to rest of argv
        set sep to character id 9
        set nl to character id 10
        set out to ""
        tell application id "\(chromeID)"
            with timeout of 5 seconds
                repeat with w from 1 to (count of windows)
                    set urls to URL of tabs of window w
                    repeat with t from 1 to (count of urls)
                        set u to item t of urls
                        set known to false
                        repeat with p in prefixes
                            if u starts with (p as text) then set known to true
                        end repeat
                        if known then
                            set r to ""
                            try
                                set r to (execute tab t of window w javascript js)
                            on error m
                                if m contains "AppleScript" then set r to "!js"
                            end try
                            set out to out & r & sep & u & sep & (title of tab t of window w) & nl
                        end if
                    end repeat
                end repeat
            end timeout
        end tell
        return out
    end run
    """

    private static func chromeOnTab(_ body: String) -> String {
        """
        on run argv
            set targetURL to item 1 of argv
            set js to item 2 of argv
            tell application id "\(chromeID)"
                with timeout of 5 seconds
                    repeat with w from 1 to (count of windows)
                        set urls to URL of tabs of window w
                        repeat with t from 1 to (count of urls)
                            considering case
                                set matched to (item t of urls is targetURL)
                            end considering
                            if matched then
                                \(body)
                                return
                            end if
                        end repeat
                    end repeat
                end timeout
            end tell
        end run
        """
    }

    private static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private static func run(_ script: String, arguments: [String] = [], timeout: TimeInterval = 8) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failed
        }
        let box = Box()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return message.contains("-1743") ? .denied : .failed
        }
        return .output(String(decoding: box.data, as: UTF8.self))
    }

    /// `previous` is what to keep when a read fails, so a slow reply doesn't make the row blink.
    static func readSpotify(previous: MediaItem?) -> MediaItem? {
        // `tell application` would launch the player, which a desktop widget must not do.
        guard isRunning(spotifyID) else { return nil }
        switch run(spotifyState) {
        case .output(let text): return parseSpotify(text)
        case .denied: return MediaItem(source: .spotify, access: .automationDenied)
        case .failed: return previous
        }
    }

    static func readBrowser(previous: MediaItem?) -> MediaItem? {
        guard isRunning(chromeID) else { return nil }
        switch run(chromeState, arguments: [stateJS] + MediaSite.all.flatMap(\.prefixes)) {
        case .output(let text): return parseBrowser(text)
        case .denied: return MediaItem(source: .browser, access: .automationDenied)
        case .failed: return previous
        }
    }

    static func parseSpotify(_ text: String) -> MediaItem {
        let lines = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        var item = MediaItem(source: .spotify, title: "停止中")
        guard lines.count >= 3, lines[0] != "stopped" else { return item }
        item.isPlaying = lines[0] == "playing"
        item.title = lines[1]
        item.artist = lines[2]
        return item
    }

    /// One line per tab: state, address, tab title. The playing tab wins, then the first one.
    static func parseBrowser(_ text: String) -> MediaItem? {
        var items: [MediaItem] = []
        for line in text.components(separatedBy: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, !fields[0].isEmpty else { continue }
            guard let site = MediaSite.matching(fields[1]) else { continue }
            var item = MediaItem(source: .browser, tabURL: fields[1])
            item.siteName = site.name
            item.symbol = site.symbol
            item.skip = site.skip
            // Tab titles end with the site's name, which the row already shows.
            item.title = fields[2].replacingOccurrences(of: #"\s*[-|｜]\s*(YouTube( Music)?|Netflix|Prime Video|Twitch|Vimeo|ニコニコ動画|ABEMA|TVer|U-NEXT|Hulu|SoundCloud|Spotify)\s*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(Prime Video|Amazon\.co\.jp)\s*[:：]\s*"#, with: "", options: .regularExpression)
            if fields[0] == "!js" {
                item.access = .browserSettingNeeded
            } else if let data = fields[0].data(using: .utf8),
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                item.isPlaying = state["playing"] as? Bool ?? false
                if let title = state["title"] as? String, !title.isEmpty { item.title = title }
                item.artist = state["artist"] as? String ?? ""
            } else {
                continue
            }
            items.append(item)
        }
        return items.first { $0.isPlaying } ?? items.first
    }

    static func send(_ action: MediaAction, to item: MediaItem) {
        switch item.source {
        case .spotify:
            guard isRunning(spotifyID) else { return }
            let command: String
            switch action {
            case .previous: command = "previous track"
            case .playPause: command = "playpause"
            case .next: command = "next track"
            }
            _ = run("tell application id \"\(spotifyID)\" to \(command)")
        case .browser:
            guard isRunning(chromeID), let url = item.tabURL, let site = MediaSite.matching(url) else { return }
            let js = script(for: action, on: site)
            _ = run(chromeOnTab("execute tab t of window w javascript js"), arguments: [url, js])
        }
    }

    private static func quoted(_ selector: String?) -> String {
        guard let selector else { return "null" }
        return "'" + selector.replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A site's own button when it has one and it is showing; otherwise the media element itself.
    static func script(for action: MediaAction, on site: MediaSite) -> String {
        let button = "function btn(s){var b=s&&document.querySelector(s);return b&&b.offsetParent!==null?b:null;}"
        switch action {
        case .playPause:
            return "(function(){\(button)\(findMedia)var b=btn(\(quoted(site.playButton)));if(b){b.click();}else if(v){if(v.paused){v.play();}else{v.pause();}}return '';})()"
        case .next, .previous:
            let forward = action == .next
            let selector = forward ? site.nextButton : site.previousButton
            let fallback: String
            switch site.skip {
            case .seek:
                fallback = forward ? "v.currentTime=Math.min(v.duration||Infinity,v.currentTime+10);" : "v.currentTime=Math.max(0,v.currentTime-10);"
            case .track:
                // Without a previous button (a single video), going back means the start, as a player would.
                fallback = forward ? "" : "v.currentTime=0;"
            case .none:
                fallback = ""
            }
            return "(function(){\(button)\(findMedia)var b=btn(\(quoted(selector)));if(b){b.click();}else if(v){\(fallback)}return '';})()"
        }
    }

    static func bringToFront(_ item: MediaItem) {
        guard item.source == .browser, isRunning(chromeID), let url = item.tabURL else { return }
        let body = """
        set active tab index of window w to t
        set index of window w to 1
        activate
        """
        _ = run(chromeOnTab(body), arguments: [url, ""])
    }
}

// MARK: - Visualizer

/// Listens to everything the Mac plays through a Core Audio process tap and keeps a set of
/// smoothed band levels for the visualizer. Audio is analysed in memory only, never stored.
/// macOS asks for "System Audio Recording" permission the first time it starts.
final class AudioSpectrum: @unchecked Sendable {
    static let log = Logger(subsystem: "local.aquadesk", category: "visualizer")
    static let bandCount = 32
    private static let size = 1024
    private static let hop = 512

    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: bandCount)
    private let control = DispatchQueue(label: "visualizer.control")
    private let audio = DispatchQueue(label: "visualizer.audio", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    /// Diagnostics only: how far start got, and whether audio arrives. No audio is kept.
    private(set) var stage = "未開始"
    private(set) var callbacks = 0
    private(set) var loudestSample: Float = 0
    private var lastSound = Date.distantPast

    /// Seconds since anything above near-silence arrived.
    var quietFor: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastSound)
    }

    /// A tap started before permission was granted delivers only silence until it is rebuilt.
    func restart() {
        control.async {
            guard self.running else { return }
            Self.log.notice("restarting after silence")
            self.stop()
            self.running = self.start()
        }
    }

    // Touched on the audio queue only.
    private var ring = [Float](repeating: 0, count: size)
    private var ringIndex = 0
    private var sinceLast = 0
    private var sampleRate: Float = 48_000
    private var peak: Float = -30
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)

    func current() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }

    /// For snapshots only.
    func preview(_ values: [Float]) {
        lock.lock()
        levels = values
        lock.unlock()
    }

    func setRunning(_ wanted: Bool) {
        control.async {
            guard wanted != self.running else { return }
            if wanted {
                self.running = self.start()
                Self.log.notice("start: \(self.stage, privacy: .public)")
            } else {
                Self.log.notice("stop")
                self.stop()
                self.running = false
            }
        }
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private func start() -> Bool {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Aquadesk Visualizer"
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else {
            stage = "tap作成失敗 \(tapStatus)"
            tapID = AudioObjectID(kAudioObjectUnknown)
            return false
        }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            let rate = Float(format.mSampleRate)
            audio.sync { self.sampleRate = rate }
        }

        var settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Aquadesk Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString],
            ],
        ]
        if let output = Self.defaultOutputUID() {
            settings[kAudioAggregateDeviceMainSubDeviceKey] = output
            settings[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        let aggregateStatus = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            stage = "集約デバイス作成失敗 \(aggregateStatus)"
            stop()
            return false
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, audio) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let procID else {
            stage = "IOProc作成失敗 \(status)"
            stop()
            return false
        }
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            stage = "開始失敗 \(startStatus)"
            stop()
            return false
        }
        stage = "動作中 rate=\(Int(format.mSampleRate)) ch=\(format.mChannelsPerFrame) output=\(settings[kAudioAggregateDeviceMainSubDeviceKey] != nil)"
        return true
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        audio.async {
            self.ring = [Float](repeating: 0, count: Self.size)
            self.preview([Float](repeating: 0, count: Self.bandCount))
        }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = data.assumingMemoryBound(to: Float.self)
        callbacks += 1
        var loudest: Float = 0
        for frame in 0..<frames { loudest = max(loudest, abs(samples[frame * channels])) }
        loudestSample = max(loudestSample, loudest)
        if loudest > 0.0005 {
            lock.lock()
            lastSound = Date()
            lock.unlock()
        }
        for frame in 0..<frames {
            ring[ringIndex] = samples[frame * channels]
            ringIndex = (ringIndex + 1) % Self.size
        }
        sinceLast += frames
        guard sinceLast >= Self.hop else { return }
        sinceLast = 0
        analyse()
    }

    private func analyse() {
        let n = Self.size
        let half = n / 2
        var ordered = [Float](repeating: 0, count: n)
        for index in 0..<n { ordered[index] = ring[(ringIndex + index) % n] }
        let windowed = vDSP.multiply(ordered, window)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft?.forward(input: split, output: &split)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }

        let count = Self.bandCount
        let low: Float = 40, high: Float = 16_000
        let binWidth = sampleRate / Float(n)
        var decibels = [Float](repeating: -120, count: count)
        for band in 0..<count {
            let from = low * powf(high / low, Float(band) / Float(count))
            let to = low * powf(high / low, Float(band + 1) / Float(count))
            let first = min(half - 1, max(1, Int(from / binWidth)))
            let last = min(half - 1, max(first, Int(to / binWidth)))
            var sum: Float = 0
            for bin in first...last { sum += power[bin] }
            let mean = sum / Float(last - first + 1)
            // Music carries less energy up high; a gentle tilt keeps the right side alive.
            let tilt = 3 * log2f(max(from, 1) / 200)
            decibels[band] = 10 * log10f(mean + 1e-12) + tilt
        }
        // Follows the loudest band slowly, so the bars fill the panel at any volume.
        let loudest = decibels.max() ?? -120
        peak = max(loudest, peak - 0.15)
        let silent = loudest < -70
        let range: Float = 45

        lock.lock()
        for band in 0..<count {
            let target = silent ? 0 : min(1, max(0, (decibels[band] - (peak - range)) / range))
            let previous = levels[band]
            levels[band] = target > previous ? previous + (target - previous) * 0.6 : previous * 0.86 + target * 0.14
        }
        lock.unlock()
    }
}

/// Bars rising from the bottom of the media panel, drawn faintly behind its rows.
struct VisualizerBackground: View {
    let spectrum: AudioSpectrum
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            // Reading the frame's date makes each tick a new Canvas; without it SwiftUI kept the first one.
            let frame = timeline.date
            Canvas { context, size in
                _ = frame
                let levels = spectrum.current()
                guard levels.contains(where: { $0 > 0.01 }) else { return }
                let gap: CGFloat = 2
                let width = (size.width - gap * CGFloat(levels.count - 1)) / CGFloat(levels.count)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Palette.active.opacity(0.38), Color(red: 0.30, green: 0.58, blue: 0.95).opacity(0.10)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height))
                for (index, level) in levels.enumerated() {
                    let height = max(0, CGFloat(level)) * size.height * 0.92
                    guard height > 0.5 else { continue }
                    let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 2)), with: shading)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Activity

struct ActivityState: Equatable {
    var isActive = false
    var tokensPerMinute = 0
}

/// Watches the session logs with FSEvents and reads only what was appended. The logs are
/// far too large to rescan: a single Codex session can reach hundreds of megabytes.
final class ActivityMonitor: @unchecked Sendable {
    private enum Provider { case codex, claude }

    /// Nothing is written while a model is generating, so the idle window has to outlast a long reply.
    private static let idleWindow: TimeInterval = 30
    private static let rateWindow: TimeInterval = 60
    private static let maxRead: UInt64 = 8 * 1024 * 1024
    private static let codexNeedle = Data("\"token_count\"".utf8)
    private static let claudeNeedle = Data("\"usage\"".utf8)

    private let queue = DispatchQueue(label: "local.aquadesk.activity", qos: .utility)
    private let codexRoot: String
    private let claudeRoot: String
    private let startedAt = Date()
    private var stream: FSEventStreamRef?

    // Touched only on `queue`.
    private var offsets: [String: UInt64] = [:]
    private var codexTotals: [String: Int] = [:]
    private var claudeCounted: [String: Int] = [:]

    // Guarded by `lock`, since the UI reads these every second.
    private let lock = NSLock()
    private var lastActivity: [Provider: Date] = [:]
    private var samples: [Provider: [(date: Date, tokens: Int)]] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        codexRoot = home + "/.codex/sessions"
        claudeRoot = home + "/.claude/projects"
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<ActivityMonitor>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            monitor.handle(Set(changed))
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [codexRoot, claudeRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func states(now: Date = Date()) -> (codex: ActivityState, claude: ActivityState) {
        lock.lock()
        defer { lock.unlock() }
        return (state(.codex, now: now), state(.claude, now: now))
    }

    private func state(_ provider: Provider, now: Date) -> ActivityState {
        samples[provider]?.removeAll { now.timeIntervalSince($0.date) > Self.rateWindow }
        let isActive = lastActivity[provider].map { now.timeIntervalSince($0) < Self.idleWindow } ?? false
        guard isActive else { return ActivityState() }
        let tokens = samples[provider]?.reduce(0) { $0 + $1.tokens } ?? 0
        return ActivityState(isActive: true, tokensPerMinute: tokens)
    }

    private func handle(_ paths: Set<String>) {
        for path in paths where path.hasSuffix(".jsonl") {
            if path.hasPrefix(codexRoot) {
                process(path, provider: .codex)
            } else if path.hasPrefix(claudeRoot) {
                process(path, provider: .claude)
            }
        }
    }

    private func process(_ path: String, provider: Provider) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return }

        guard var offset = offsets[path] else {
            // A log that predates launch has history that must not count as current usage.
            let created = attributes[.creationDate] as? Date ?? .distantPast
            if created < startedAt {
                offsets[path] = size
                record(provider, tokens: 0)
            } else {
                offsets[path] = 0
                process(path, provider: provider)
            }
            return
        }

        if size < offset { offset = size }
        guard size > offset else { return }
        if size - offset > Self.maxRead { offset = size - Self.maxRead }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // A line still being written waits for the next event.
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            offsets[path] = offset
            record(provider, tokens: 0)
            return
        }
        offsets[path] = offset + UInt64(data.distance(from: data.startIndex, to: lastNewline)) + 1

        var tokens = 0
        let complete = data[data.startIndex..<lastNewline]
        let needle = provider == .codex ? Self.codexNeedle : Self.claudeNeedle
        for line in complete.split(separator: 0x0A) where line.range(of: needle) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            tokens += provider == .codex ? codexTokens(object, path: path) : claudeTokens(object)
        }
        record(provider, tokens: tokens)
    }

    /// Cache reads are excluded on both sides: they dwarf real usage and would make the rate meaningless.
    private func codexTokens(_ object: [String: Any], path: String) -> Int {
        guard let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any]
        else { return 0 }

        func fresh(_ key: String) -> Int? {
            guard let usage = info[key] as? [String: Any] else { return nil }
            func value(_ name: String) -> Int { (usage[name] as? NSNumber)?.intValue ?? 0 }
            return max(0, value("input_tokens") - value("cached_input_tokens")) + value("output_tokens")
        }

        guard let total = fresh("total_token_usage") else { return 0 }
        defer { codexTotals[path] = total }
        if let previous = codexTotals[path] { return max(0, total - previous) }
        return fresh("last_token_usage") ?? 0
    }

    /// The same message is logged on several lines, so each id only contributes its increase.
    private func claudeTokens(_ object: [String: Any]) -> Int {
        guard let message = object["message"] as? [String: Any],
              let id = message["id"] as? String,
              let usage = message["usage"] as? [String: Any]
        else { return 0 }
        func value(_ name: String) -> Int { (usage[name] as? NSNumber)?.intValue ?? 0 }
        let total = value("input_tokens") + value("cache_creation_input_tokens") + value("output_tokens")

        if claudeCounted.count > 5000 { claudeCounted.removeAll() }
        let increase = max(0, total - (claudeCounted[id] ?? 0))
        claudeCounted[id] = max(total, claudeCounted[id] ?? 0)
        return increase
    }

    private func record(_ provider: Provider, tokens: Int) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        lastActivity[provider] = now
        if tokens > 0 { samples[provider, default: []].append((now, tokens)) }
    }
}

// MARK: - Model

@MainActor
final class WidgetModel: ObservableObject {
    @Published var memory = MemorySnapshot()
    @Published var cpu: Double?
    @Published var gpu: Double?
    @Published var disk: DiskTotals?
    @Published var codex = ProviderUsage()
    @Published var claude = ProviderUsage()
    @Published var codexActivity = ActivityState()
    @Published var claudeActivity = ActivityState()
    @Published var mail = MailSnapshot()
    @Published var agenda = AgendaSnapshot()
    @Published var isWindowVisible = true {
        didSet { updateVisualizer() }
    }
    @Published var wifi = WiFiStatus()
    @Published var locationAllowed: Bool?
    @Published var bluetooth = BluetoothStatus()
    @Published var volumes: [ExternalVolume] = []
    @Published var ejecting: Set<URL> = []
    @Published var volumeError: String?
    @Published var pending: [PendingItem] = []
    @Published var media: [MediaItem] = [] {
        didSet { updateVisualizer() }
    }
    /// Listening runs only while something plays and the widget can be seen, which also keeps
    /// the menu bar's recording indicator off the rest of the time.
    @Published private(set) var visualizerActive = false
    let spectrum = AudioSpectrum()
    var listensToAudio = true
    @Published var now = Date()
    let shortcuts = ShortcutStore()
    /// Set by the user; nil follows the content.
    @Published var heightLimit: CGFloat?
    /// The wide layout for portrait screens: a band of figures over three columns.
    @Published var isHorizontal = false
    @Published var horizontalWidth: CGFloat = 1000
    /// Room from the widget's top edge down to the bottom of its screen.
    @Published var screenLimit = CGFloat.greatestFiniteMagnitude
    @Published var isLocked = false
    let slotDrag = SlotDragState()
    let aquarium = AquariumSimulation()
    var aquariumClock: Date?
    @Published var layout = WidgetLayout.load()
    @Published var isEditingLayout = false
    /// The widget's measured content height; kept here rather than in the view's @State (see ShortcutSlot).
    @Published var contentHeight: CGFloat = 0
    let panelDrag = PanelDragState()
    private var resizeStart: WidgetLayout?

    /// Wide enough for every tile in one row, the shortcuts go in a single row; otherwise four by two.
    var shortcutColumns: Int { horizontalWidth >= 1240 ? 8 : 4 }
    var shortcutsWidth: CGFloat { shortcutColumns == 8 ? 8 * 56 + 7 * 8 : 4 * 62 + 3 * 8 }
    /// The wide layout's width inside its padding.
    var wideInner: CGFloat { horizontalWidth - 32 }

    func movePanel(_ source: PanelID, onto target: PanelID) {
        layout.move(source, onto: target, horizontal: isHorizontal)
        layout.save()
    }

    func resizePanels(_ a: PanelID, _ b: PanelID, by dx: CGFloat, finished: Bool) {
        let start = resizeStart ?? layout
        resizeStart = finished ? nil : start
        layout.resize(a, b, by: dx, from: start, total: wideInner, shortcuts: shortcutsWidth)
        if finished { layout.save() }
    }

    func changeRows(_ id: PanelID, by delta: Int) {
        let rows = layout.rowCount(id) + delta
        guard WidgetLayout.rowRange.contains(rows) else { return }
        layout.rows[id.rawValue] = rows
        layout.save()
    }

    func resetLayout() {
        layout.reset(horizontal: isHorizontal)
        layout.save()
    }

    private let monitor = ActivityMonitor()
    private let cpuMeter = CPUMeter()
    private var timers: [Timer] = []
    private var claudeNote: String?
    private var fetchInFlight = false
    private var codexLog = ProviderUsage()
    private var codexLive: ProviderUsage?
    private var codexNote: String?
    private var codexFetchInFlight = false
    private var codexRoseAt: Date?
    private var mailFetchInFlight = false
    private let agendaReader = AgendaReader()
    private var agendaFetchInFlight = false
    private var agendaObserver: NSObjectProtocol?
    private var locationAccess: LocationAccess?
    private var bluetoothFetchInFlight = false
    private var volumeFetchInFlight = false
    private var volumeFetchQueued = false
    private var volumeObservers: [NSObjectProtocol] = []
    private var volumeErrorClear: Task<Void, Never>?
    private var mediaFetchInFlight = false
    /// A read begun before a command would undo what that command just showed.
    private var mediaGeneration = 0

    /// Much Codex usage leaves no trace in this Mac's logs, so a rising server value also counts
    /// as activity. It moves in 1% steps, hence a window longer than the log-based one.
    private static let codexRiseWindow: TimeInterval = 150

    func start() {
        refreshMemory()
        refreshLocal()
        refreshClaudeAPI()
        refreshCodexLive()
        schedule(every: 60) { $0.refreshCodexLive() }
        monitor.start()
        schedule(every: 1) { $0.refreshActivity() }
        schedule(every: 3) { $0.refreshMemory() }
        schedule(every: 60) { $0.refreshLocal() }
        schedule(every: 300) { $0.refreshClaudeAPI() }
        refreshMail()
        schedule(every: 60) { $0.refreshMail() }
        refreshPending()
        schedule(every: 2) { $0.refreshPending() }
        locationAccess = LocationAccess { [weak self] allowed in
            MainActor.assumeIsolated {
                self?.locationAllowed = allowed
                self?.refreshWiFi()
            }
        }
        refreshWiFi()
        schedule(every: 5) { $0.refreshWiFi() }
        refreshBluetooth()
        schedule(every: 15) { $0.refreshBluetooth() }
        refreshVolumes()
        schedule(every: 60) { $0.refreshVolumes() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
        refreshMedia()
        schedule(every: 5) { model in
            if model.isWindowVisible { model.refreshMedia() }
        }
        refreshAgenda()
        schedule(every: 60) { $0.refreshAgenda() }
        agendaObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAgenda() }
        }
    }

    private func refreshMedia() {
        guard !mediaFetchInFlight else { return }
        mediaFetchInFlight = true
        let generation = mediaGeneration
        let previous = media
        Task.detached(priority: .utility) {
            let items = [
                MediaReader.readSpotify(previous: previous.first { $0.source == .spotify }),
                MediaReader.readBrowser(previous: previous.first { $0.source == .browser }),
            ].compactMap { $0 }
            await MainActor.run {
                self.mediaFetchInFlight = false
                if generation == self.mediaGeneration, items != self.media { self.media = items }
                self.checkVisualizerSilence()
            }
        }
    }

    private var lastAudioRestart = Date.distantPast

    /// Called with the media poll: a player says it is playing, yet nothing has been heard.
    private func checkVisualizerSilence() {
        guard visualizerActive, spectrum.quietFor > 8, Date().timeIntervalSince(lastAudioRestart) > 30 else { return }
        lastAudioRestart = Date()
        spectrum.restart()
    }

    private func updateVisualizer() {
        let wanted = listensToAudio && isWindowVisible && media.contains { $0.isPlaying }
        guard wanted != visualizerActive else { return }
        AudioSpectrum.log.notice("visualizer \(wanted ? "on" : "off", privacy: .public) visible=\(self.isWindowVisible, privacy: .public) playing=\(self.media.filter(\.isPlaying).count, privacy: .public)")
        visualizerActive = wanted
        spectrum.setRunning(wanted)
    }

    func sendMedia(_ action: MediaAction, to source: MediaSource) {
        guard let index = media.firstIndex(where: { $0.source == source }) else { return }
        let item = media[index]
        mediaGeneration += 1
        if action == .playPause { media[index].isPlaying.toggle() }
        Task.detached(priority: .userInitiated) {
            MediaReader.send(action, to: item)
            // Players take a moment to change track.
            try? await Task.sleep(for: .milliseconds(800))
            await MainActor.run {
                self.mediaGeneration += 1
                self.mediaFetchInFlight = false
                self.refreshMedia()
            }
        }
    }

    private func refreshWiFi() {
        let status = WiFiReader.read()
        if status != wifi { wifi = status }
    }

    private func refreshBluetooth() {
        guard !bluetoothFetchInFlight else { return }
        bluetoothFetchInFlight = true
        Task.detached(priority: .utility) {
            let status = BluetoothReader.read()
            await MainActor.run {
                if status != self.bluetooth { self.bluetooth = status }
                self.bluetoothFetchInFlight = false
            }
        }
    }

    private func refreshVolumes() {
        guard !volumeFetchInFlight else {
            // A mount during a read may be missing from its result, so read once more afterwards.
            volumeFetchQueued = true
            return
        }
        volumeFetchInFlight = true
        Task.detached(priority: .utility) {
            let volumes = VolumeReader.read()
            await MainActor.run {
                if volumes != self.volumes { self.volumes = volumes }
                self.volumeFetchInFlight = false
                if self.volumeFetchQueued {
                    self.volumeFetchQueued = false
                    self.refreshVolumes()
                }
            }
        }
    }

    /// Unmounting waits on the disk, and fails rather than forcing it when files are in use.
    func eject(_ url: URL) {
        guard volumes.contains(where: { $0.url == url }), !ejecting.contains(url) else { return }
        let name = volumes.first { $0.url == url }?.name ?? url.lastPathComponent
        ejecting.insert(url)
        showVolumeError(nil)
        Task.detached(priority: .userInitiated) {
            let failed: Bool
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                failed = false
            } catch {
                failed = true
            }
            await MainActor.run {
                self.ejecting.remove(url)
                if failed { self.showVolumeError("「\(name)」を取り外せません（使用中の可能性）") }
                self.refreshVolumes()
            }
        }
    }

    private func showVolumeError(_ message: String?) {
        volumeErrorClear?.cancel()
        volumeError = message
        guard message != nil else { return }
        volumeErrorClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.volumeError = nil
        }
    }

    private func refreshAgenda() {
        guard !agendaFetchInFlight else { return }
        agendaFetchInFlight = true
        let reader = agendaReader
        Task.detached(priority: .utility) {
            let snapshot = await reader.fetch()
            await MainActor.run {
                if snapshot != self.agenda { self.agenda = snapshot }
                self.agendaFetchInFlight = false
            }
        }
    }

    private func refreshPending() {
        let items = PendingReader.read()
        if items != pending { pending = items }
    }

    private func refreshActivity() {
        let states = monitor.states()
        var codexState = states.codex
        if let rose = codexRoseAt, Date().timeIntervalSince(rose) < Self.codexRiseWindow {
            codexState.isActive = true
        }
        if codexState != codexActivity { codexActivity = codexState }
        if states.claude != claudeActivity { claudeActivity = states.claude }
    }

    func refreshAll() {
        refreshMemory()
        refreshLocal()
        refreshClaudeAPI()
        refreshCodexLive()
        refreshMail()
        refreshAgenda()
        refreshVolumes()
        refreshWiFi()
        refreshBluetooth()
        refreshMedia()
    }

    private func refreshMail() {
        guard !mailFetchInFlight else { return }
        mailFetchInFlight = true
        Task.detached(priority: .utility) {
            let snapshot = MailReader.fetch()
            await MainActor.run {
                self.mail = snapshot
                self.mailFetchInFlight = false
            }
        }
    }

    /// The log moves with local use between queries, so whichever reading is newer wins.
    private func applyCodex() {
        var usage = codexLog
        if let live = codexLive, (codexLog.updatedAt ?? .distantPast) <= (live.updatedAt ?? .distantPast) {
            usage = live
            usage.windows = live.windows.map { $0.normalized() }
        }
        usage.note = codexNote ?? codexLog.note
        codex = usage
    }

    private func refreshCodexLive() {
        guard !codexFetchInFlight else { return }
        codexFetchInFlight = true
        Task.detached(priority: .utility) {
            let result = CodexLiveReader.fetch()
            await MainActor.run {
                switch result {
                case .success(let usage):
                    if let previous = self.codexLive?.windows.first?.usedPercent,
                       let current = usage.windows.first?.usedPercent, current > previous {
                        self.codexRoseAt = Date()
                    }
                    self.codexLive = usage
                    self.codexNote = nil
                case .failure(let error):
                    self.codexNote = "最新値を取得できません（\(error.message)）"
                }
                self.codexFetchInFlight = false
                self.applyCodex()
            }
        }
    }

    /// One shot with no network or Keychain access, used to render a snapshot.
    func loadOffline() {
        refreshMemory()
        Thread.sleep(forTimeInterval: 0.5)  // CPU use needs two samples.
        refreshMemory()
        codex = CodexReader.read()
        claude = ClaudeReader.merged(apiNote: nil)
    }

    private func schedule(every interval: TimeInterval, _ action: @escaping @MainActor (WidgetModel) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func refreshMemory() {
        memory = MemoryReader.read()
        if let value = cpuMeter.sample() { cpu = value }
        gpu = GPUMeter.read()
        disk = DiskMeter.read()
        now = Date()
    }

    private func refreshLocal() {
        let note = claudeNote
        let apiEnabled = Self.claudeAPIEnabled
        Task.detached(priority: .utility) {
            let codex = CodexReader.read()
            var merged = ClaudeReader.merged(apiNote: note)
            if !apiEnabled && merged.updatedAt == nil { merged.note = Self.claudeOffHint }
            let claude = merged
            await MainActor.run {
                self.codexLog = codex
                self.applyCodex()
                self.claude = claude
            }
        }
    }

    /// Reading Claude Code's login and calling its unofficial usage endpoint is opt-in.
    static let claudeAPIKey = "ClaudeUsageAPIEnabled"
    nonisolated static let claudeOffHint = "メニューの「Claude使用量をAPIで取得」で有効化"
    static var claudeAPIEnabled: Bool { UserDefaults.standard.bool(forKey: claudeAPIKey) }

    func setClaudeAPI(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.claudeAPIKey)
        refreshClaudeAPI()
    }

    private func refreshClaudeAPI() {
        guard Self.claudeAPIEnabled else {
            claudeNote = nil
            let claude = ClaudeReader.merged(apiNote: nil)
            self.claude = claude.updatedAt == nil
                ? ProviderUsage(windows: claude.windows, updatedAt: nil, note: Self.claudeOffHint)
                : claude
            return
        }
        guard !fetchInFlight else { return }
        fetchInFlight = true
        Task.detached(priority: .utility) {
            let result = await ClaudeReader.fetch()
            let note: String?
            if case .failure(let message) = result { note = message } else { note = nil }
            let claude = ClaudeReader.merged(apiNote: note)
            await MainActor.run {
                self.claudeNote = note
                self.claude = claude
                self.fetchInFlight = false
            }
        }
    }
}

// MARK: - Formatting

enum Format {
    private static let reset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d H:mm"
        return formatter
    }()

    static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f", bytes / 1_073_741_824)
    }

    static func resetText(_ window: LimitWindow) -> String {
        guard window.usedPercent != nil else { return "記録なし" }
        guard let date = window.resetsAt else { return window.usedPercent == 0 ? "全量利用可" : "リセット時刻不明" }
        return "\(reset.string(from: date)) リセット"
    }

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    static func capacity(_ volume: ExternalVolume) -> String? {
        guard let total = volume.total else { return nil }
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        guard let available = volume.available else { return totalText }
        return "空き \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) / \(totalText)"
    }

    static func agendaDay(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "今日" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明日"
        }
        return monthDay.string(from: date)
    }

    static func eventTime(_ event: AgendaEvent, now: Date) -> String {
        if event.isAllDay { return "\(agendaDay(max(event.start, now), now: now)) 終日" }
        if event.start <= now { return "開催中" }
        return "\(agendaDay(event.start, now: now)) \(clock.string(from: event.start))"
    }

    static func reminderDue(_ reminder: AgendaReminder, now: Date) -> String {
        guard let due = reminder.due else { return "期限なし" }
        let day = agendaDay(due, now: now)
        return reminder.hasTime ? "\(day) \(clock.string(from: due))" : day
    }

    static func rate(_ tokensPerMinute: Int) -> String {
        guard tokensPerMinute > 0 else { return "動作中" }
        if tokensPerMinute < 1000 { return "\(tokensPerMinute) トークン/分" }
        return String(format: "%.1fk トークン/分", Double(tokensPerMinute) / 1000)
    }

    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "未取得" }
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "たった今"
        case ..<3600: return "\(seconds / 60)分前"
        case ..<86400: return "\(seconds / 3600)時間前"
        default: return "\(seconds / 86400)日前"
        }
    }
}

// MARK: - Views

enum Palette {
    static let appMemory = Color(red: 0.36, green: 0.68, blue: 1.0)
    static let wired = Color(red: 0.70, green: 0.53, blue: 1.0)
    static let compressed = Color(red: 1.0, green: 0.66, blue: 0.32)
    static let good = Color(red: 0.30, green: 0.85, blue: 0.62)
    static let warn = Color(red: 1.0, green: 0.76, blue: 0.28)
    static let low = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let active = Color(red: 0.42, green: 0.85, blue: 1.0)
    static let track = Color.white.opacity(0.10)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.45)

    static func remaining(_ percent: Double) -> Color {
        percent > 40 ? good : (percent > 15 ? warn : low)
    }

    static func pressure(_ level: Int) -> Color {
        level >= 4 ? low : (level >= 2 ? warn : good)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = 0.7
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct MemoryRing: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            VStack(spacing: -1) {
                Text("\(Int((fraction * 100).rounded()))")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .frame(width: 66, height: 66)
    }
}

struct MemorySection: View {
    let memory: MemorySnapshot
    let cpu: Double?
    let gpu: Double?
    let disk: DiskTotals?

    private var pressureText: String {
        memory.pressure >= 4 ? "負荷 高" : (memory.pressure >= 2 ? "負荷 中" : "負荷 低")
    }

    var body: some View {
        HStack(spacing: 14) {
            MemoryRing(fraction: memory.fraction, color: Palette.pressure(memory.pressure))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("メモリ").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Format.gigabytes(memory.used)) / \(Format.gigabytes(memory.total)) GB")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                }
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        segment(memory.app, Palette.appMemory, proxy.size.width)
                        segment(memory.wired, Palette.wired, proxy.size.width)
                        segment(memory.compressed, Palette.compressed, proxy.size.width)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Palette.track)
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                HStack(spacing: 10) {
                    legend("App", Palette.appMemory, memory.app)
                    legend("確保", Palette.wired, memory.wired)
                    legend("圧縮", Palette.compressed, memory.compressed)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(pressureText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.pressure(memory.pressure))
                    Spacer()
                    Text("\(usageText("CPU", cpu))  \(usageText("GPU", gpu))")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("ディスク")
                    Spacer()
                    Text(diskText)
                        .monospacedDigit()
                }
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.secondary)
            }
        }
    }

    private var diskText: String {
        guard let disk else { return "読み --  書き --" }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "読み \(format(disk.read))  書き \(format(disk.written))"
    }

    private func usageText(_ label: String, _ value: Double?) -> String {
        value.map { "\(label) \(Int(($0 * 100).rounded()))%" } ?? "\(label) --"
    }

    private func segment(_ bytes: Double, _ color: Color, _ width: CGFloat) -> some View {
        color.frame(width: max(0, width * bytes / memory.total))
    }

    private func legend(_ title: String, _ color: Color, _ bytes: Double) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(Format.gigabytes(bytes))")
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.secondary)
                .fixedSize()
        }
    }
}

/// Light travelling along a limit bar while its provider is consuming tokens.
struct FlowingShimmer: View {
    let tokensPerMinute: Int

    private var period: Double {
        tokensPerMinute >= 20_000 ? 1.0 : (tokensPerMinute >= 2_000 ? 1.6 : 2.4)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
            GeometryReader { proxy in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let width = max(30, proxy.size.width * 0.35)
                LinearGradient(
                    colors: [.clear, .white.opacity(0.8), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: width)
                .offset(x: -width + (proxy.size.width + width) * phase)
            }
        }
    }
}

struct ActivityBadge: View {
    let activity: ActivityState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            if reduceMotion {
                Circle().fill(Palette.active).frame(width: 7, height: 7)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                    let wave = sin(context.date.timeIntervalSinceReferenceDate * 4) * 0.5 + 0.5
                    Circle()
                        .fill(Palette.active)
                        .frame(width: 7, height: 7)
                        .opacity(0.45 + 0.55 * wave)
                        .scaleEffect(0.85 + 0.2 * wave)
                }
            }
            Text(Format.rate(activity.tokensPerMinute))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.active)
                .fixedSize()
        }
    }
}

/// Pixel-art Claude mascot: still when idle, walking while tokens are being consumed.
struct PixelMascot: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pixel: CGFloat = 2
    private static let columns = 9
    private static let rows = 6
    private static let body = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let eye = Color(red: 0.10, green: 0.08, blue: 0.08)

    private static let idle = [
        ".XXXXXXX.",
        ".XEXXXEX.",
        "XXXXXXXXX",
        ".XXXXXXX.",
        ".X.X.X.X.",
    ]
    private static let walking = [
        [".XXXXXXX.", "XXEXXXEX.", ".XXXXXXXX", ".XXXXXXX.", ".X...X..."],
        [".XXXXXXX.", ".XEXXXEXX", "XXXXXXXX.", ".XXXXXXX.", "...X...X."],
    ]

    var body: some View {
        if isActive && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 1.0 / 6)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate * 6)
                sprite(Self.walking[tick % 2], lift: tick % 2 == 0 ? 0 : 1)
            }
        } else {
            sprite(Self.idle, lift: 0)
        }
    }

    private func sprite(_ grid: [String], lift: Int) -> some View {
        Canvas { context, _ in
            for (row, line) in grid.enumerated() {
                for (column, cell) in line.enumerated() where cell != "." {
                    let rect = CGRect(
                        x: CGFloat(column) * Self.pixel, y: CGFloat(row + 1 - lift) * Self.pixel,
                        width: Self.pixel, height: Self.pixel)
                    context.fill(Path(rect), with: .color(cell == "E" ? Self.eye : Self.body))
                }
            }
        }
        .frame(width: CGFloat(Self.columns) * Self.pixel, height: CGFloat(Self.rows) * Self.pixel)
    }
}

struct LimitRow: View {
    let window: LimitWindow
    var activity = ActivityState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let remaining = window.remaining
        let color = remaining.map(Palette.remaining) ?? Palette.tertiary
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                Text(Format.resetText(window))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
                Spacer()
                Text(remaining.map { "残り \(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule()
                        .fill(color)
                        .overlay {
                            if activity.isActive && !reduceMotion {
                                FlowingShimmer(tokensPerMinute: activity.tokensPerMinute)
                            }
                        }
                        .clipShape(Capsule())
                        .frame(width: proxy.size.width * (remaining ?? 0) / 100)
                        .animation(.easeOut(duration: 0.4), value: remaining)
                }
            }
            .frame(height: 6)
        }
    }
}

struct ProviderSection: View {
    let title: String
    let symbol: String
    let usage: ProviderUsage
    let activity: ActivityState
    let now: Date
    var showsMascot = false
    var showsChevron = false
    var pending: [PendingItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if showsMascot {
                    PixelMascot(isActive: activity.isActive)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                if activity.isActive {
                    ActivityBadge(activity: activity).padding(.leading, 3)
                }
                Spacer()
                Text("更新 \(Format.age(usage.updatedAt, now: now))")
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                }
            }
            ForEach(usage.windows) { LimitRow(window: $0, activity: activity) }
            ForEach(pending) { item in
                HStack(spacing: 6) {
                    Circle().fill(Palette.warn).frame(width: 6, height: 6)
                    Text(item.reason)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.warn)
                        .fixedSize()
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(Format.age(item.since, now: now))
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.tertiary)
                        .fixedSize()
                }
            }
            if let note = usage.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warn)
                    .lineLimit(1)
            }
        }
    }
}

struct MailSection: View {
    let mail: MailSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                Text("メール").font(.system(size: 13, weight: .semibold))
                if let unread = mail.unread {
                    Text("未読 \(unread)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(unread > 0 ? Palette.active : Palette.secondary)
                        .padding(.leading, 3)
                }
                Spacer()
                Text("更新 \(Format.age(mail.updatedAt, now: now))")
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            if let note = mail.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warn)
                    .lineLimit(1)
            }
        }
    }
}

/// Bubbles keep their own state so a change in CPU use alters how many appear, without
/// the ones already rising jumping or vanishing.
final class AquariumSimulation {
    struct Bubble {
        var x: Double
        var y: Double  // Points above the bottom edge.
        let radius: Double
        let speed: Double
        let wobble: Double
    }

    struct Fish {
        var x: Double          // Points from the left edge.
        var depth: Double      // 0 at the top of the swimming room, 1 at the bottom.
        var targetDepth: Double
        var direction: Double  // 1 swims right, -1 left.
        var turn: Double       // Eases from -1 to 1 so a turn isn't a flip.
        let speed: Double
        let length: Double
        let color: Int
        let phase: Double
    }

    private static let maxBubbles = 120
    private(set) var bubbles: [Bubble] = []
    private(set) var fish: [Fish] = []
    private(set) var level = 0.0
    private var spawnDebt = 0.0
    private var last: Date?

    func advance(to date: Date, targetLevel: Double, cpu: Double, size: CGSize, paused: Bool) {
        guard let previous = last else {
            // Start as if it had been running, rather than with an empty tank.
            level = targetLevel
            for _ in 0..<100 { step(0.1, cpu: cpu, size: size) }
            last = date
            return
        }
        last = date
        if paused {
            level = targetLevel
            return
        }
        // Clamped so resuming after a pause doesn't apply the whole gap at once.
        let elapsed = min(0.1, max(0, date.timeIntervalSince(previous)))
        level += (targetLevel - level) * (1 - exp(-elapsed / 0.8))
        step(elapsed, cpu: cpu, size: size)
    }

    /// Enough fish for the tank's size, keeping those already swimming.
    private func stockFish(size: CGSize) {
        let count = min(7, max(3, Int(size.width * size.height / 60_000)))
        if fish.count > count { fish.removeLast(fish.count - count) }
        while fish.count < count {
            let direction: Double = Bool.random() ? 1 : -1
            let depth = Double.random(in: 0.1...0.9)
            fish.append(Fish(
                x: Double.random(in: 0...max(1, size.width)), depth: depth, targetDepth: depth,
                direction: direction, turn: direction,
                speed: Double.random(in: 9...20), length: Double.random(in: 17...28),
                color: fish.count % 4, phase: Double.random(in: 0...(2 * .pi))))
        }
    }

    private func swim(_ elapsed: Double, cpu: Double, size: CGSize) {
        stockFish(size: size)
        // A busy machine stirs the water and the fish swim a little faster.
        let pace = 1 + 0.8 * cpu
        for index in fish.indices {
            var f = fish[index]
            f.x += f.direction * f.speed * pace * elapsed * max(0.15, abs(f.turn))
            let margin = f.length
            if f.x > size.width - margin && f.direction > 0 { f.direction = -1 }
            if f.x < margin && f.direction < 0 { f.direction = 1 }
            if Double.random(in: 0...1) < 0.03 * elapsed { f.direction *= -1 }
            f.turn += (f.direction - f.turn) * min(1, elapsed * 2.5)
            if abs(f.depth - f.targetDepth) < 0.02 || Double.random(in: 0...1) < 0.08 * elapsed {
                f.targetDepth = Double.random(in: 0.05...0.95)
            }
            f.depth += (f.targetDepth - f.depth) * min(1, elapsed * 0.35)
            fish[index] = f
        }
    }

    private func step(_ elapsed: Double, cpu: Double, size: CGSize) {
        swim(elapsed, cpu: cpu, size: size)
        spawnDebt += (0.4 + 14 * cpu) * elapsed
        while spawnDebt >= 1 {
            spawnDebt -= 1
            guard bubbles.count < Self.maxBubbles else { continue }
            let radius = Double.random(in: 1.2...3.6)
            bubbles.append(Bubble(
                x: Double.random(in: 0...1), y: -radius, radius: radius,
                // Larger bubbles rise faster, as in water.
                speed: 22 + radius * 11 + Double.random(in: 0...8),
                wobble: Double.random(in: 0...(2 * .pi))))
        }
        let surface = level * size.height
        for index in bubbles.indices { bubbles[index].y += bubbles[index].speed * elapsed }
        bubbles.removeAll { $0.y >= surface }
    }
}

/// A cross-section of a water tank behind the content: the water level follows memory use and
/// the bubbles rising through it follow CPU use.
struct AquariumBackground: View {
    let level: Double
    let cpu: Double
    let paused: Bool
    /// Kept by the model, so the fish carry on across redraws of the whole widget.
    let simulation: AquariumSimulation
    /// Set when frames are rendered one by one (the promo video) instead of in real time.
    var clock: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStill = clock == nil && (paused || reduceMotion)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: isStill)) { timeline in
            Canvas { context, size in
                let date = clock ?? timeline.date
                simulation.advance(to: date, targetLevel: level, cpu: cpu, size: size, paused: isStill)
                draw(in: &context, size: size, time: date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
    }

    private func wave(size: CGSize, surface: Double, time: Double, phase: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        var x = 0.0
        while true {
            let unit = x / size.width * 2 * .pi
            let y = surface + sin(unit * 1.3 + time * 0.9 + phase) * 2.6 + sin(unit * 2.7 - time * 0.6 + phase) * 1.2
            path.addLine(to: CGPoint(x: x, y: y))
            if x >= size.width { break }
            x = min(size.width, x + 8)
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let surface = size.height * (1 - simulation.level)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [
                Color(red: 0.24, green: 0.62, blue: 0.95).opacity(0.16),
                Color(red: 0.08, green: 0.32, blue: 0.72).opacity(0.26),
            ]),
            startPoint: CGPoint(x: 0, y: surface), endPoint: CGPoint(x: 0, y: size.height))

        context.fill(
            wave(size: size, surface: surface, time: time, phase: 2.1),
            with: .color(Color(red: 0.24, green: 0.62, blue: 0.95).opacity(0.06)))
        let front = wave(size: size, surface: surface + 2, time: time, phase: 0)
        context.fill(front, with: shading)

        // The waterline only: clip away the path's sides and bottom.
        var line = context
        line.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: surface + 9)))
        line.stroke(front, with: .color(.white.opacity(0.18)), lineWidth: 1)

        let sandTop = drawFloor(in: &context, size: size, surface: surface, time: time)
        drawFish(in: &context, size: size, surface: surface, floor: sandTop, time: time)

        for bubble in simulation.bubbles {
            let center = CGPoint(
                x: bubble.x * size.width + sin(bubble.wobble + bubble.y * 0.035) * 3.5,
                y: size.height - bubble.y)
            // Fades on reaching the surface instead of blinking out.
            let fade = min(1, max(0, (center.y - surface) / 14))
            let r = bubble.radius
            let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.fill(circle, with: .color(.white.opacity(0.07 * fade)))
            context.stroke(circle, with: .color(.white.opacity(0.30 * fade)), lineWidth: 0.7)
        }
    }
}

extension AquariumBackground {
    /// Sand, pebbles and swaying weed along the bottom. Returns the sand's top.
    fileprivate func drawFloor(in context: inout GraphicsContext, size: CGSize, surface: Double, time: Double) -> Double {
        let base = size.height - 9
        var sand = Path()
        sand.move(to: CGPoint(x: 0, y: size.height))
        var x = 0.0
        while true {
            let unit = x / size.width * 2 * .pi
            sand.addLine(to: CGPoint(x: x, y: base + sin(unit * 1.6 + 0.8) * 2.5 + sin(unit * 4.3) * 1.2))
            if x >= size.width { break }
            x = min(size.width, x + 10)
        }
        sand.addLine(to: CGPoint(x: size.width, y: size.height))
        sand.closeSubpath()
        context.fill(sand, with: .linearGradient(
            Gradient(colors: [Color(red: 0.93, green: 0.82, blue: 0.60).opacity(0.22), Color(red: 0.70, green: 0.58, blue: 0.40).opacity(0.30)]),
            startPoint: CGPoint(x: 0, y: base - 4), endPoint: CGPoint(x: 0, y: size.height)))

        // Fixed spots, spread by fractions of the width so both orientations look furnished.
        let pebbles: [(Double, Double, Double)] = [(0.07, 6, 0.30), (0.10, 4, 0.22), (0.38, 7, 0.26), (0.63, 5, 0.24), (0.66, 8, 0.30), (0.91, 6, 0.26)]
        for (fraction, radius, opacity) in pebbles {
            let rect = CGRect(x: fraction * size.width - radius, y: base - radius * 0.55, width: radius * 2, height: radius * 1.2)
            context.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.55, green: 0.60, blue: 0.66).opacity(opacity)))
            context.fill(
                Path(ellipseIn: rect.insetBy(dx: radius * 0.45, dy: radius * 0.3).offsetBy(dx: -radius * 0.25, dy: -radius * 0.2)),
                with: .color(.white.opacity(opacity * 0.35)))
        }

        let water = max(0, base - surface - 8)
        let weeds: [(Double, Double, Double)] = [(0.04, 0.9, 0), (0.09, 0.6, 1.3), (0.30, 0.7, 2.2), (0.55, 0.5, 0.7), (0.80, 0.95, 1.9), (0.85, 0.65, 3.1), (0.96, 0.75, 0.4)]
        for (fraction, tall, phase) in weeds {
            // Never above the water, and no taller than a share of the tank.
            let height = min(water, min(size.height * 0.32, 130) * tall)
            guard height > 12 else { continue }
            let rootX = fraction * size.width
            let segments = 10
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in 0...segments {
                let t = Double(i) / Double(segments)
                let sway = sin(time * 1.1 + phase + t * 2.4) * 7 * t * t
                let width = 3.2 * (1 - t) + 0.6
                let point = CGPoint(x: rootX + sway, y: base - height * t)
                left.append(CGPoint(x: point.x - width, y: point.y))
                right.append(CGPoint(x: point.x + width, y: point.y))
            }
            var blade = Path()
            blade.addLines(left)
            blade.addLines(right.reversed())
            blade.closeSubpath()
            context.fill(blade, with: .linearGradient(
                Gradient(colors: [Color(red: 0.20, green: 0.58, blue: 0.36).opacity(0.55), Color(red: 0.45, green: 0.88, blue: 0.55).opacity(0.32)]),
                startPoint: CGPoint(x: rootX, y: base), endPoint: CGPoint(x: rootX, y: base - height)))
        }
        return base
    }

    private static let fishColors: [(Color, Color)] = [
        (Color(red: 1.00, green: 0.58, blue: 0.25), Color(red: 1.00, green: 0.85, blue: 0.60)),
        (Color(red: 0.35, green: 0.80, blue: 1.00), Color(red: 0.85, green: 0.97, blue: 1.00)),
        (Color(red: 1.00, green: 0.84, blue: 0.30), Color(red: 1.00, green: 0.96, blue: 0.75)),
        (Color(red: 1.00, green: 0.50, blue: 0.68), Color(red: 1.00, green: 0.85, blue: 0.90)),
    ]

    fileprivate func drawFish(in context: inout GraphicsContext, size: CGSize, surface: Double, floor: Double, time: Double) {
        let top = surface + 12, bottom = floor - 10
        guard bottom - top > 6 else { return }
        for fish in simulation.fish {
            let y = top + (bottom - top) * fish.depth + sin(time * 1.3 + fish.phase) * 2
            let colors = Self.fishColors[fish.color % Self.fishColors.count]
            let length = fish.length, height = fish.length * 0.52
            var layer = context
            layer.opacity = 0.78
            layer.translateBy(x: fish.x, y: y)
            // Squashed through zero while turning, so it reads as the fish turning round.
            layer.scaleBy(x: fish.turn, y: 1)
            let wag = sin(time * 7 + fish.phase) * height * 0.22

            var tail = Path()
            tail.move(to: CGPoint(x: -length * 0.38, y: 0))
            tail.addLine(to: CGPoint(x: -length * 0.72, y: -height * 0.55 + wag))
            tail.addLine(to: CGPoint(x: -length * 0.64, y: wag * 0.5))
            tail.addLine(to: CGPoint(x: -length * 0.72, y: height * 0.55 + wag))
            tail.closeSubpath()
            layer.fill(tail, with: .color(colors.0.opacity(0.85)))

            var fin = Path()
            fin.move(to: CGPoint(x: -length * 0.12, y: -height * 0.42))
            fin.addQuadCurve(to: CGPoint(x: length * 0.12, y: -height * 0.45), control: CGPoint(x: -length * 0.05, y: -height * 0.85))
            fin.closeSubpath()
            layer.fill(fin, with: .color(colors.0.opacity(0.8)))

            let body = Path(ellipseIn: CGRect(x: -length * 0.45, y: -height / 2, width: length * 0.9, height: height))
            layer.fill(body, with: .linearGradient(
                Gradient(colors: [colors.1, colors.0]),
                startPoint: CGPoint(x: 0, y: -height / 2), endPoint: CGPoint(x: 0, y: height / 2)))
            let eye = length * 0.07
            layer.fill(
                Path(ellipseIn: CGRect(x: length * 0.22 - eye, y: -height * 0.12 - eye, width: eye * 2, height: eye * 2)),
                with: .color(Color.black.opacity(0.75)))
        }
    }
}

struct AgendaRow: Identifiable {
    let id: String
    let color: Color
    let label: String
    var labelColor = Palette.secondary
    let title: String
}

/// One list of up to three rows; a click on it is handled by the window like the mail section.
struct AgendaSection: View {
    let title: String
    let symbol: String
    var summary: String?
    let access: AgendaAccess
    let deniedNote: String
    let emptyNote: String
    let rows: [AgendaRow]
    /// Narrow tiles put each row's time above its title.
    var stacked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let summary {
                    Text(summary)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.active)
                        .padding(.leading, 3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            switch access {
            case .pending:
                note("読み込み中", color: Palette.tertiary)
            case .denied:
                note(deniedNote, color: Palette.warn)
            case .granted:
                if rows.isEmpty {
                    note(emptyNote, color: Palette.tertiary)
                }
                ForEach(rows) { row in
                    if stacked {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(row.color).frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.label)
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(row.labelColor)
                                    .lineLimit(1)
                                Text(row.title)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: 0)
                        }
                    } else {
                    HStack(spacing: 6) {
                        Circle().fill(row.color).frame(width: 6, height: 6)
                        Text(row.label)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(row.labelColor)
                            .lineLimit(1)
                            .frame(width: 66, alignment: .leading)
                        Text(row.title)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    }
                }
            }
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct FrameReporter: View {
    var onRemove: (@MainActor () -> Void)?
    let action: @MainActor (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear { action(frame) }
                .onChange(of: frame) { _, updated in action(updated) }
                .onDisappear { onRemove?() }
        }
    }
}

struct WiFiRow: View {
    let status: WiFiStatus
    var locationAllowed: Bool?

    private var signal: (String, Color) {
        if status.rssi >= -60 { return ("強", Palette.good) }
        return status.rssi >= -70 ? ("中", Palette.warn) : ("弱", Palette.low)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.isOn ? "wifi" : "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondary)
            Text("Wi-Fi").font(.system(size: 13, weight: .semibold))
            if status.isConnected {
                if let name = status.name {
                    Text(name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 3)
                } else if locationAllowed == false {
                    Text("名前は未許可")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.warn)
                        .lineLimit(1)
                        .padding(.leading, 3)
                }
            }
            Spacer(minLength: 4)
            Group {
                if !status.hasInterface {
                    Text("Wi-Fiなし").foregroundStyle(Palette.tertiary)
                } else if !status.isOn {
                    Text("オフ").foregroundStyle(Palette.tertiary)
                } else if !status.isConnected {
                    Text("未接続").foregroundStyle(Palette.warn)
                } else {
                    Text("信号 \(signal.0)").foregroundStyle(signal.1)
                    // The name needs the room more than the exact figure does.
                    Text(status.name == nil ? "\(status.rssi) dBm · \(Int(status.rate)) Mbps" : "\(Int(status.rate)) Mbps")
                        .foregroundStyle(Palette.secondary)
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .fixedSize()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.tertiary)
        }
    }
}

struct BluetoothRows: View {
    let status: BluetoothStatus
    var limit = 3

    private var summary: String {
        switch status.isOn {
        case nil: return "取得できません"
        case false?: return "オフ"
        case true?: return status.devices.isEmpty ? "接続なし" : "\(status.devices.count)台接続"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                Text("Bluetooth").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(summary)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            ForEach(status.devices.prefix(limit)) { device in
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let battery = device.battery {
                        Text(battery)
                            .font(.system(size: 10, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle((device.lowestBattery ?? 100) <= 20 ? Palette.low : Palette.secondary)
                            .fixedSize()
                    }
                }
            }
            if status.devices.count > limit {
                Text("ほか \(status.devices.count - limit)台")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }
}

/// Left out entirely while neither player is available. The row and each button report separate
/// frames that don't overlap, so a click can't hit the wrong one.
struct MediaSection<Reporter: View>: View {
    let items: [MediaItem]
    @ViewBuilder let reportFrame: (ClickTarget) -> Reporter

    private func detail(_ item: MediaItem) -> (String, Color) {
        switch item.access {
        case .controllable:
            return (item.artist.isEmpty ? item.label : "\(item.label) · \(item.artist)", Palette.secondary)
        case .browserSettingNeeded:
            return ("操作は Chrome の 表示 › デベロッパー › Apple EventsからのJavaScriptを許可 が必要です", Palette.warn)
        case .automationDenied:
            return ("オートメーションが未許可です（クリックで設定）", Palette.warn)
        }
    }

    private func button(_ symbol: String, _ size: CGFloat, _ action: MediaAction, _ source: MediaSource) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .background { reportFrame(.media(source, action)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                let note = detail(item)
                HStack(spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(item.isPlaying ? Palette.active : Palette.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.access == .automationDenied ? item.label : item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(note.0)
                                .font(.system(size: 10))
                                .foregroundStyle(note.1)
                                .lineLimit(item.access == .controllable ? 1 : 2)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .background { reportFrame(.mediaRow(item.source)) }
                    if item.access == .controllable {
                        switch item.skip {
                        case .track: button("backward.fill", 10, .previous, item.source)
                        case .seek: button("gobackward.10", 12, .previous, item.source)
                        case .none: EmptyView()
                        }
                        button(item.isPlaying ? "pause.fill" : "play.fill", 13, .playPause, item.source)
                        switch item.skip {
                        case .track: button("forward.fill", 10, .next, item.source)
                        case .seek: button("goforward.10", 12, .next, item.source)
                        case .none: EmptyView()
                        }
                    }
                }
            }
        }
    }
}

/// Left out entirely while nothing is connected. Rows and eject buttons report separate frames
/// that don't overlap, so a click can't hit the wrong one.
struct VolumeSection<Reporter: View>: View {
    let volumes: [ExternalVolume]
    let ejecting: Set<URL>
    let error: String?
    @ViewBuilder let reportFrame: (ClickTarget) -> Reporter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                Text("外部ストレージ").font(.system(size: 13, weight: .semibold))
            }
            ForEach(volumes) { volume in
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(volume.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let capacity = Format.capacity(volume) {
                            Text(capacity)
                                .font(.system(size: 10, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background { reportFrame(.volume(volume.url)) }
                    Group {
                        if ejecting.contains(volume.url) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "eject.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                    }
                    .frame(width: 24, height: 22)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .background { reportFrame(.eject(volume.url)) }
                    .accessibilityLabel("\(volume.name)を取り外す")
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.warn)
                    .lineLimit(1)
            }
        }
    }
}

/// A blue-tinted grayscale that sits with the water. Converts the pixels rather than using SwiftUI's
/// grayscale modifier, which left the icons in colour when rendered to a bitmap. Cached because a
/// tile's body can run repeatedly.
@MainActor
enum MonochromeIcon {
    private static var cache: [String: NSImage] = [:]
    private static let context = CIContext()

    static func image(forFile path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let filter = CIFilter(name: "CIColorMonochrome")
        else { return icon }
        filter.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        filter.setValue(CIColor(red: 0.72, green: 0.86, blue: 1.0), forKey: kCIInputColorKey)
        filter.setValue(1, forKey: kCIInputIntensityKey)
        guard let output = filter.outputImage,
              let converted = context.createCGImage(output, from: output.extent)
        else { return icon }
        let result = NSImage(cgImage: converted, size: icon.size)
        cache[path] = result
        return result
    }
}

struct ShortcutSlot: View {
    let shortcut: Shortcut?
    let onDrop: (URL) -> Void
    /// Kept by the caller rather than in @State: the State macro's plugin ships with Xcode but not
    /// with every Command Line Tools release, and the app must build with either.
    var isTargeted: Binding<Bool> = .constant(false)

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isTargeted.wrappedValue ? 0.20 : (shortcut == nil ? 0.04 : 0.08)))
            if let shortcut {
                if shortcut.kind == .file, let url = shortcut.url {
                    // App icons carry a transparent margin, so a slight overscale makes them fill the tile.
                    Image(nsImage: MonochromeIcon.image(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(1.2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    caption(shortcut.displayName, color: .white)
                } else if shortcut.kind == .file {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 26))
                        .foregroundStyle(Palette.warn)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    caption("見つかりません", color: Palette.warn)
                } else {
                    ShortcutFace(shortcut: shortcut, size: 46)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, 10)
                    caption(shortcut.displayName, color: .white)
                }
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDrop(of: [UTType.fileURL], isTargeted: isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { onDrop(url) }
            }
            return true
        }
    }

    private func caption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(
                colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Panel layout

enum PanelID: String, Codable, CaseIterable {
    case memory, codex, claude, mail, events, reminders, media, volumes, network, shortcuts
    /// The wide layout's middle column: the three tiles with media below them.
    case center

    var title: String {
        switch self {
        case .memory: return "メモリ"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .mail: return "メール"
        case .events: return "予定"
        case .reminders: return "リマインダー"
        case .media: return "メディア"
        case .volumes: return "外部ストレージ"
        case .network: return "Wi-Fi / Bluetooth"
        case .shortcuts: return "ショートカット"
        case .center: return "予定・メディアの列"
        }
    }
}

/// The order and size of the panels, kept separately for each orientation.
struct WidgetLayout: Codable, Equatable {
    static let defaultVertical: [PanelID] = [
        .memory, .codex, .claude, .mail, .events, .reminders, .media, .volumes, .network, .shortcuts,
    ]
    static let defaultTop: [PanelID] = [.memory, .codex, .claude]
    static let defaultTiles: [PanelID] = [.events, .reminders, .mail]
    static let defaultBand: [PanelID] = [.network, .center, .shortcuts]
    static let defaultWeights: [String: Double] = [PanelID.memory.rawValue: 1.125]

    static let topSpacing: CGFloat = 8
    static let tileSpacing: CGFloat = 8
    static let bandSpacing: CGFloat = 16
    static let minTop: CGFloat = 150
    static let minTile: CGFloat = 90
    static let minNetwork: CGFloat = 140
    static let maxNetwork: CGFloat = 320
    static let minCenter: CGFloat = 300
    static let rowRange = 1...6

    /// Upright: one column, any order.
    var vertical = Self.defaultVertical
    /// Wide: each row is reordered on its own.
    var top = Self.defaultTop
    var tiles = Self.defaultTiles
    var band = Self.defaultBand
    /// Relative widths within the wide layout's rows.
    var weights = Self.defaultWeights
    var networkWidth: Double = 170
    /// How many entries a list shows in the upright layout.
    var rows: [String: Int] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func ids(_ key: CodingKeys) -> [PanelID]? {
            (try? container.decodeIfPresent([String].self, forKey: key))?.compactMap(PanelID.init)
        }
        vertical = Self.fixed(ids(.vertical), Self.defaultVertical)
        top = Self.fixed(ids(.top), Self.defaultTop)
        tiles = Self.fixed(ids(.tiles), Self.defaultTiles)
        band = Self.fixed(ids(.band), Self.defaultBand)
        weights = (try? container.decodeIfPresent([String: Double].self, forKey: .weights)) ?? Self.defaultWeights
        networkWidth = (try? container.decodeIfPresent(Double.self, forKey: .networkWidth)) ?? 170
        rows = (try? container.decodeIfPresent([String: Int].self, forKey: .rows)) ?? [:]
    }

    /// Keeps a saved order to the panels that belong there, adding any it lacks at the end.
    private static func fixed(_ saved: [PanelID]?, _ defaults: [PanelID]) -> [PanelID] {
        var result: [PanelID] = []
        for id in saved ?? [] where defaults.contains(id) && !result.contains(id) { result.append(id) }
        return result + defaults.filter { !result.contains($0) }
    }

    func weight(_ id: PanelID) -> Double { max(0.1, weights[id.rawValue] ?? 1) }
    func rowCount(_ id: PanelID) -> Int { rows[id.rawValue] ?? 3 }

    private static let wideRows: [WritableKeyPath<WidgetLayout, [PanelID]>] = [\.top, \.tiles, \.band]

    func canSwap(_ a: PanelID, _ b: PanelID, horizontal: Bool) -> Bool {
        guard a != b else { return false }
        if !horizontal { return vertical.contains(a) && vertical.contains(b) }
        return Self.wideRows.contains { self[keyPath: $0].contains(a) && self[keyPath: $0].contains(b) }
    }

    /// Puts `source` where `target` is; the panels between shift over by one.
    mutating func move(_ source: PanelID, onto target: PanelID, horizontal: Bool) {
        let rows: [WritableKeyPath<WidgetLayout, [PanelID]>] = horizontal ? Self.wideRows : [\.vertical]
        for row in rows {
            var ids = self[keyPath: row]
            guard let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target) else { continue }
            ids.remove(at: from)
            ids.insert(source, at: to)
            self[keyPath: row] = ids
        }
    }

    // Wide geometry. `total` is the width inside the widget's padding.

    func clampedNetworkWidth(total: CGFloat, shortcuts: CGFloat) -> CGFloat {
        let most = min(Self.maxNetwork, total - 2 * Self.bandSpacing - shortcuts - Self.minCenter)
        return max(Self.minNetwork, min(CGFloat(networkWidth), most))
    }

    func centerWidth(total: CGFloat, shortcuts: CGFloat) -> CGFloat {
        total - 2 * Self.bandSpacing - shortcuts - clampedNetworkWidth(total: total, shortcuts: shortcuts)
    }

    func widths(_ ids: [PanelID], inner: CGFloat, spacing: CGFloat) -> [CGFloat] {
        let available = inner - spacing * CGFloat(max(0, ids.count - 1))
        let sum = ids.reduce(0) { $0 + weight($1) }
        return ids.map { available * CGFloat(weight($0) / sum) }
    }

    /// Moves the border between two neighbours by `dx` from where it was in `start`.
    mutating func resize(_ a: PanelID, _ b: PanelID, by dx: CGFloat, from start: WidgetLayout, total: CGFloat, shortcuts: CGFloat) {
        if a == .network || b == .network, let index = start.band.firstIndex(of: .network) {
            let other = a == .network ? b : a
            let sign: CGFloat = index < (start.band.firstIndex(of: other) ?? 0) ? 1 : -1
            var moved = start
            moved.networkWidth = Double(start.clampedNetworkWidth(total: total, shortcuts: shortcuts) + sign * dx)
            networkWidth = Double(moved.clampedNetworkWidth(total: total, shortcuts: shortcuts))
            return
        }
        let row: [PanelID], inner: CGFloat, spacing: CGFloat, least: CGFloat
        if start.top.contains(a) {
            (row, inner, spacing, least) = (start.top, total, Self.topSpacing, Self.minTop)
        } else if start.tiles.contains(a) {
            (row, inner, spacing, least) = (start.tiles, start.centerWidth(total: total, shortcuts: shortcuts), Self.tileSpacing, Self.minTile)
        } else {
            return
        }
        let widths = start.widths(row, inner: inner, spacing: spacing)
        guard let ia = row.firstIndex(of: a), let ib = row.firstIndex(of: b) else { return }
        let pair = widths[ia] + widths[ib]
        guard pair > 2 * least else { return }
        let newA = min(max(widths[ia] + dx, least), pair - least)
        let weightSum = start.weight(a) + start.weight(b)
        weights[a.rawValue] = weightSum * Double(newA / pair)
        weights[b.rawValue] = weightSum - weightSum * Double(newA / pair)
    }

    mutating func reset(horizontal: Bool) {
        if horizontal {
            (top, tiles, band, weights, networkWidth) = (Self.defaultTop, Self.defaultTiles, Self.defaultBand, Self.defaultWeights, 170)
        } else {
            (vertical, rows) = (Self.defaultVertical, [:])
        }
    }

    private static let defaultsKey = "PanelLayout"

    static func load() -> WidgetLayout {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let layout = try? JSONDecoder().decode(WidgetLayout.self, from: data) else { return WidgetLayout() }
        return layout
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

/// A panel being dragged while the layout is edited, in the window's top-left coordinates.
@MainActor
final class PanelDragState: ObservableObject {
    @Published var source: PanelID?
    @Published var location = CGPoint.zero
    @Published var target: PanelID?
}

/// Outlines a panel while the layout is edited, and dims it while it is being dragged.
struct EditablePanel<Content: View>: View {
    let id: PanelID
    let editing: Bool
    @ObservedObject var drag: PanelDragState
    var outset = EdgeInsets()
    var cornerRadius: CGFloat = 12
    /// Shows a stepper for how many entries the panel lists.
    var rows: Int?
    var rowsAlignment: Alignment = .topTrailing
    let onFrame: @MainActor (ClickTarget, CGRect) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let isTarget = drag.source != nil && drag.target == id
        content()
            .opacity(drag.source == id ? 0.3 : 1)
            .overlay {
                if editing {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            isTarget ? Palette.active : Color.white.opacity(0.45),
                            style: StrokeStyle(lineWidth: isTarget ? 2 : 1.2, dash: isTarget ? [] : [5, 4]))
                        .background {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Palette.active.opacity(isTarget ? 0.12 : 0))
                        }
                        .padding(negativeOutset)
                        .background {
                            FrameReporter(onRemove: { onFrame(.panel(id), .null) }) { onFrame(.panel(id), $0) }
                                .padding(negativeOutset)
                        }
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: isTarget)
                }
            }
            .overlay(alignment: rowsAlignment) {
                if editing, let rows { stepper(rows) }
            }
    }

    private var negativeOutset: EdgeInsets {
        EdgeInsets(top: -outset.top, leading: -outset.leading, bottom: -outset.bottom, trailing: -outset.trailing)
    }

    private func stepper(_ rows: Int) -> some View {
        HStack(spacing: 2) {
            stepButton("minus", delta: -1, enabled: rows > WidgetLayout.rowRange.lowerBound)
            Text("\(rows)件")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 26)
            stepButton("plus", delta: 1, enabled: rows < WidgetLayout.rowRange.upperBound)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.65)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
    }

    private func stepButton(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .frame(width: 20, height: 18)
            .background(Circle().fill(Color.white.opacity(enabled ? 0.16 : 0.05)))
            .opacity(enabled ? 1 : 0.35)
            .background {
                FrameReporter(onRemove: { onFrame(.rows(id, delta), .null) }) { onFrame(.rows(id, delta), $0) }
            }
    }
}

/// The grip on the border between two wide panels; dragging it moves the border.
struct SplitterHandle: View {
    let leading: PanelID
    let trailing: PanelID
    let onFrame: @MainActor (ClickTarget, CGRect) -> Void

    var body: some View {
        Capsule()
            .fill(Palette.active)
            .frame(width: 4, height: 28)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .background {
                FrameReporter(onRemove: { onFrame(.splitter(leading, trailing), .null) }) {
                    onFrame(.splitter(leading, trailing), $0)
                }
            }
    }
}

/// The name of the panel under the pointer while it is dragged, and the bar for leaving edit mode.
struct LayoutEditOverlay: View {
    @ObservedObject var drag: PanelDragState
    let horizontal: Bool
    let onFrame: @MainActor (ClickTarget, CGRect) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10, weight: .semibold))
                Text(horizontal ? "ドラッグで並び替え・つまみで幅を調整" : "ドラッグで並び替え・−＋で表示件数")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Text("完了")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.active))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .background {
                        FrameReporter(onRemove: { onFrame(.layoutDone, .null) }) { onFrame(.layoutDone, $0) }
                    }
            }
            .padding(.leading, 10)
            .padding(.trailing, 3)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            .padding(.top, 4)
            if let source = drag.source {
                Text(source.title)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.active.opacity(0.9)))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                    .position(drag.location)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A tile being dragged to another slot, in the window's top-left coordinates.
@MainActor
final class SlotDragState: ObservableObject {
    @Published var source: Int?
    @Published var location = CGPoint.zero
    @Published var target: Int?
    /// The slot a file from Finder is being held over.
    @Published var fileTarget: Int?
}

struct ShortcutGrid: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject var drag: SlotDragState
    var columns = 4
    let onFrame: @MainActor (Int, CGRect) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(0..<ShortcutStore.slotCount, id: \.self) { index in
                let isSource = drag.source == index
                let isTarget = drag.source != nil && drag.target == index && !isSource
                ShortcutSlot(shortcut: store.slots[index], onDrop: { store.drop($0, on: index) }, isTargeted: Binding(
                    get: { drag.fileTarget == index },
                    set: { targeted in
                        if targeted { drag.fileTarget = index } else if drag.fileTarget == index { drag.fileTarget = nil }
                    }))
                    .opacity(isSource ? 0.3 : 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Palette.active, lineWidth: 2)
                            .opacity(isTarget ? 1 : 0)
                    }
                    .animation(.easeOut(duration: 0.12), value: isTarget)
                    .background { FrameReporter { onFrame(index, $0) } }
            }
        }
    }
}

/// The tile under the pointer while it is dragged.
struct SlotDragOverlay: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject var drag: SlotDragState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let source = drag.source, let shortcut = store.slots[source] {
                ShortcutSlot(shortcut: shortcut) { _ in }
                    .frame(width: 70, height: 70)
                    .scaleEffect(1.08)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                    .opacity(0.92)
                    .position(drag.location)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Launcher

/// The picture for any kind of shortcut, in a square of the given size.
struct ShortcutFace: View {
    let shortcut: Shortcut
    let size: CGFloat

    var body: some View {
        switch shortcut.kind {
        case .launcher:
            LauncherGlyph(items: shortcut.items ?? [], size: size)
        case .file:
            if let url = shortcut.url {
                icon(url.path)
            } else {
                symbol("questionmark.folder", Palette.warn)
            }
        case .link:
            symbol("globe", Palette.active)
        case .workflow:
            icon("/System/Applications/Shortcuts.app")
        case .group:
            ZStack(alignment: .bottomTrailing) {
                symbol("square.stack.3d.up.fill", Palette.active)
                Text("\(shortcut.group?.count ?? 0)")
                    .font(.system(size: max(8, size * 0.2), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Palette.active))
            }
            .frame(width: size, height: size)
        }
    }

    private func icon(_ path: String) -> some View {
        Image(nsImage: MonochromeIcon.image(forFile: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

/// A launcher's face: its first four items in a small grid, as on a folder.
struct LauncherGlyph: View {
    let items: [Shortcut]
    let size: CGFloat

    var body: some View {
        let cell = (size - 6) / 2
        ZStack {
            Circle()
                .strokeBorder(Palette.active.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            if items.isEmpty {
                Image(systemName: "circle.grid.2x2")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(Palette.active)
            } else {
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow { cellView(0, cell); cellView(1, cell) }
                    GridRow { cellView(2, cell); cellView(3, cell) }
                }
                .frame(width: size * 0.72, height: size * 0.72)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func cellView(_ index: Int, _ cell: CGFloat) -> some View {
        let side = cell * 0.72
        if index < items.count {
            let item = items[index]
            if item.isLauncher {
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: side * 0.6))
                    .foregroundStyle(Palette.active)
                    .frame(width: side, height: side)
            } else {
                ShortcutFace(shortcut: item, size: side)
            }
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }
}

enum LauncherLayout {
    static let item: CGFloat = 50
    /// Room for twelve items plus the rim, so one panel size serves every launcher.
    static let side: CGFloat = 380

    static func radius(for positions: Int) -> CGFloat {
        max(78, CGFloat(positions) * 64 / (2 * .pi))
    }

    static func diskRadius(for positions: Int) -> CGFloat {
        radius(for: positions) + item / 2 + 18
    }

    static func offset(_ index: Int, of count: Int, radius: CGFloat) -> CGSize {
        let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(max(count, 1))
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }

    /// The position a direction points at, measured clockwise from straight up, as `offset` lays them out.
    static func index(towards dx: CGFloat, _ dy: CGFloat, of count: Int) -> Int {
        guard count > 0 else { return 0 }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        return Int((angle / (2 * .pi / CGFloat(count))).rounded()) % count
    }
}

@MainActor
final class LauncherState: ObservableObject {
    /// Empty for the ring of all tiles that the hotkey opens.
    @Published var path: [Int]
    @Published var expanded = false
    /// The item under the pointer, with -1 for the add button.
    @Published var hovered: Int?
    /// Where the ring grows from, relative to its centre: the tile that was clicked.
    var origin: CGSize

    init(path: [Int], origin: CGSize) {
        self.path = path
        self.origin = origin
    }
}

struct LauncherActions {
    var activate: @MainActor (Int) -> Void = { _ in }
    var back: @MainActor () -> Void = {}
    var add: @MainActor ([Int], AddKind) -> Void = { _, _ in }
    var addMenu: @MainActor ([Int]) -> Void = { _ in }
    var rename: @MainActor ([Int]) -> Void = { _ in }
    var remove: @MainActor ([Int]) -> Void = { _ in }
    var reveal: @MainActor (URL) -> Void = { _ in }
    var drop: @MainActor ([URL]) -> Void = { _ in }
}

struct LauncherRingView: View {
    @ObservedObject var store: ShortcutStore
    @ObservedObject var state: LauncherState
    var solidBackground = false
    var actions = LauncherActions()

    private static let spring = Animation.spring(response: 0.34, dampingFraction: 0.78)

    var body: some View {
        let isRoot = state.path.isEmpty
        let launcher = store.item(at: state.path)
        let items = launcher?.items ?? []
        let showsAdd = !isRoot && items.count < ShortcutStore.launcherLimit
        let positions = items.count + (showsAdd ? 1 : 0)
        let radius = LauncherLayout.radius(for: positions)
        let disk = LauncherLayout.diskRadius(for: positions)
        let anchor = UnitPoint(x: 0.5 + state.origin.width / (disk * 2), y: 0.5 + state.origin.height / (disk * 2))

        ZStack {
            diskView(disk)
                .scaleEffect(state.expanded ? 1 : 0.12, anchor: anchor)
                .opacity(state.expanded ? 1 : 0)
                .animation(Self.spring, value: state.expanded)
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    guard !isRoot else { return false }
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            DispatchQueue.main.async { MainActor.assumeIsolated { actions.drop([url]) } }
                        }
                    }
                    return true
                }

            centerView(launcher, items: items, isRoot: isRoot)
                .scaleEffect(state.expanded ? 1 : 0.3)
                .opacity(state.expanded ? 1 : 0)
                .offset(state.expanded ? .zero : state.origin)
                .animation(Self.spring, value: state.expanded)

            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                ringButton(index: index, positions: positions, radius: radius) {
                    itemFace(item, hovered: state.hovered == index)
                }
                .onTapGesture { actions.activate(index) }
                .contextMenu {
                    if let path = store.childPath(state.path, index) {
                        itemMenu(item, index: index, path: path, isRoot: isRoot)
                    }
                }
            }
            if showsAdd {
                ringButton(index: items.count, positions: positions, radius: radius, hoverID: -1) {
                    addFace(hovered: state.hovered == -1)
                }
                .onTapGesture { actions.addMenu(state.path) }
                .contextMenu { addButtons(state.path) }
            }
        }
        .frame(width: LauncherLayout.side, height: LauncherLayout.side)
        .foregroundStyle(Color.white.opacity(0.94))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func addButtons(_ path: [Int]) -> some View {
        ForEach(AddKind.allCases, id: \.self) { kind in
            Button(kind.title) { actions.add(path, kind) }
        }
    }

    private func ringButton<Face: View>(
        index: Int, positions: Int, radius: CGFloat, hoverID: Int? = nil, @ViewBuilder face: () -> Face
    ) -> some View {
        let id = hoverID ?? index
        return face()
            .frame(width: LauncherLayout.item, height: LauncherLayout.item)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .scaleEffect(state.expanded ? (state.hovered == id ? 1.12 : 1) : 0.3)
            .opacity(state.expanded ? 1 : 0)
            .offset(state.expanded ? LauncherLayout.offset(index, of: positions, radius: radius) : state.origin)
            .animation(Self.spring.delay(state.expanded ? Double(index) * 0.018 : 0), value: state.expanded)
            .animation(.easeOut(duration: 0.12), value: state.hovered)
            .onHover { inside in
                if inside {
                    state.hovered = id
                } else if state.hovered == id {
                    state.hovered = nil
                }
            }
    }

    @ViewBuilder
    private func diskView(_ disk: CGFloat) -> some View {
        ZStack {
            if solidBackground {
                Circle().fill(Color(red: 0.11, green: 0.12, blue: 0.14))
            } else {
                VisualEffectBackground().clipShape(Circle())
            }
            Circle().fill(LinearGradient(
                colors: [Color(red: 0.30, green: 0.58, blue: 0.95).opacity(0.05),
                         Color(red: 0.30, green: 0.58, blue: 0.95).opacity(0.22)],
                startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .frame(width: disk * 2, height: disk * 2)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private func centerView(_ launcher: Shortcut?, items: [Shortcut], isRoot: Bool) -> some View {
        var label = launcher?.displayName ?? ""
        if let hovered = state.hovered {
            if hovered == -1 {
                label = "追加"
            } else if items.indices.contains(hovered) {
                label = items[hovered].displayName
            }
        }
        return VStack(spacing: 3) {
            Image(systemName: state.path.count > 1 ? "chevron.backward" : "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.secondary)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 84)
        }
        .frame(width: 96, height: 96)
        .background(Circle().fill(Color.black.opacity(0.28)))
        .contentShape(Circle())
        .onTapGesture { actions.back() }
        .contextMenu {
            if !isRoot {
                addButtons(state.path)
                Divider()
                Button("名前を変更…") { actions.rename(state.path) }
            }
        }
    }

    private func itemFace(_ item: Shortcut, hovered: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.22 : 0.10))
            ShortcutFace(shortcut: item, size: item.isLauncher ? 40 : 42)
        }
    }

    private func addFace(hovered: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(hovered ? 0.6 : 0.3), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(hovered ? Color.white : Palette.secondary)
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: Shortcut, index: Int, path: [Int], isRoot: Bool) -> some View {
        Button("開く") { actions.activate(index) }
        if let url = item.url {
            Button("Finderで表示") { actions.reveal(url) }
        } else {
            Button("名前を変更…") { actions.rename(path) }
        }
        Divider()
        Button(isRoot ? "タイルから削除" : "ランチャーから外す") { actions.remove(path) }
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows a launcher as a ring around the tile that was clicked (or the pointer, for the hotkey),
/// above every window, and closes it on a click elsewhere, on Escape, or once something opened.
@MainActor
final class LauncherController {
    private let store: ShortcutStore
    private var panel: LauncherPanel?
    private var state: LauncherState?
    private var monitors: [Any] = []
    private var anchor = NSPoint.zero
    private var lastClosed: (path: [Int], at: Date)?
    /// While the hotkey is held, the pointer's direction picks an item; releasing opens it.
    private var flickTimer: Timer?
    private var flickChoice: Int?

    init(store: ShortcutStore) {
        self.store = store
    }

    /// A click on the open launcher's own tile closes it; the outside-click check gets there first.
    func toggle(slot: Int, around point: NSPoint) {
        if let lastClosed, lastClosed.path == [slot], Date().timeIntervalSince(lastClosed.at) < 0.4 { return }
        if state?.path.first == slot {
            close()
            return
        }
        show(path: [slot], around: point)
    }

    func hotKeyPressed() {
        if state?.path.isEmpty == true {
            close()
            return
        }
        show(path: [], around: NSEvent.mouseLocation)
        flickChoice = nil
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackFlick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flickTimer = timer
    }

    /// A quick tap leaves the ring open for clicking; a flick opens what it pointed at.
    func hotKeyReleased() {
        flickTimer?.invalidate()
        flickTimer = nil
        guard let choice = flickChoice else { return }
        flickChoice = nil
        activate(choice)
    }

    private func trackFlick() {
        guard let panel, let state, state.expanded else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - panel.frame.midX
        let dy = panel.frame.midY - mouse.y
        let items = store.item(at: state.path)?.items ?? []
        let showsAdd = !state.path.isEmpty && items.count < ShortcutStore.launcherLimit
        let positions = items.count + (showsAdd ? 1 : 0)
        guard hypot(dx, dy) > 30, positions > 0 else {
            if flickChoice != nil, state.hovered == flickChoice { state.hovered = nil }
            flickChoice = nil
            return
        }
        let index = LauncherLayout.index(towards: dx, dy, of: positions)
        guard index < items.count else { return }
        flickChoice = index
        if state.hovered != index { state.hovered = index }
    }

    func show(path: [Int], around point: NSPoint) {
        close(animated: false)
        guard let launcher = store.item(at: path), let items = launcher.items else { return }
        anchor = point
        let positions = min(items.count + (path.isEmpty ? 0 : 1), ShortcutStore.launcherLimit)
        // Kept whole on screen: near an edge the ring moves in and still grows out of the tile.
        let margin = LauncherLayout.diskRadius(for: max(positions, 1)) + 10
        var center = point
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            center.x = min(max(center.x, area.minX + margin), area.maxX - margin)
            center.y = min(max(center.y, area.minY + margin), area.maxY - margin)
        }
        let state = LauncherState(path: path, origin: CGSize(width: point.x - center.x, height: center.y - point.y))
        let side = LauncherLayout.side
        let panel = LauncherPanel(
            contentRect: NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        let hosting = NSHostingView(rootView: LauncherRingView(store: store, state: state, actions: makeActions()))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.state = state
        installMonitors()
        DispatchQueue.main.async { state.expanded = true }
    }

    func close(animated: Bool = true) {
        flickTimer?.invalidate()
        flickTimer = nil
        flickChoice = nil
        guard let panel, let state else { return }
        lastClosed = (state.path.isEmpty ? [] : [state.path[0]], Date())
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        self.panel = nil
        self.state = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        state.hovered = nil
        state.expanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { panel.orderOut(nil) }
    }

    private func installMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let isKey = event.type == .keyDown
            let isEscape = isKey && event.keyCode == 53
            let windowNumber = event.windowNumber
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel else { return false }
                if isKey {
                    if isEscape { self.back() }
                    return isEscape
                }
                if windowNumber != panel.windowNumber { self.close() }
                return false
            }
            return consumed ? nil : event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
    }

    private func back() {
        guard let state else { return }
        if state.path.count > 1 {
            navigate(to: Array(state.path.dropLast()))
        } else {
            close()
        }
    }

    /// Nested launchers open in place: the ring folds in and comes back with the new items.
    private func navigate(to path: [Int]) {
        guard let state else { return }
        state.hovered = nil
        state.origin = .zero
        state.expanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, self.state === state else { return }
            state.path = path
            state.expanded = true
        }
    }

    private func activate(_ index: Int) {
        guard let state, let path = store.childPath(state.path, index), let item = store.item(at: path) else { return }
        if item.isLauncher {
            navigate(to: path)
        } else if ShortcutRunner.run(item) {
            close()
        } else {
            NSSound.beep()
        }
    }

    /// Dialogs would sit beneath the ring, so it closes for them and comes back afterwards.
    private func reopen(_ path: [Int], after work: (@escaping @MainActor () -> Void) -> Void) {
        let point = anchor
        close(animated: false)
        work { [weak self] in
            guard let self else { return }
            var target = path
            while !target.isEmpty, self.store.item(at: target)?.isLauncher != true { target.removeLast() }
            self.lastClosed = nil
            self.show(path: target, around: point)
        }
    }

    private func add(_ kind: AddKind, to path: [Int]) {
        reopen(path) { [weak self] done in
            ItemPrompt.make(kind, multiple: true) { entries in
                self?.store.add(entries, to: path)
                done()
            }
        }
    }

    private func showAddMenu(for path: [Int]) {
        guard let panel, let view = panel.contentView else { return }
        let menu = NSMenu()
        for kind in AddKind.allCases {
            let action = MenuAction { [weak self] in self?.add(kind, to: path) }
            let item = NSMenuItem(title: kind.title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action  // Menu items hold their targets weakly.
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: panel.mouseLocationOutsideOfEventStream, in: view)
    }

    private func makeActions() -> LauncherActions {
        LauncherActions(
            activate: { [weak self] index in self?.activate(index) },
            back: { [weak self] in self?.back() },
            add: { [weak self] path, kind in self?.add(kind, to: path) },
            addMenu: { [weak self] path in self?.showAddMenu(for: path) },
            rename: { [weak self] path in
                guard let current = self?.store.item(at: path) else { return }
                let back = path.count > 1 && path != self?.state?.path ? Array(path.dropLast()) : path
                self?.reopen(back) { done in
                    if let name = NamePrompt.ask("名前を変更", initial: current.displayName) {
                        self?.store.rename(path, to: name)
                    }
                    done()
                }
            },
            remove: { [weak self] path in self?.store.removeItem(at: path) },
            reveal: { [weak self] url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
                self?.close()
            },
            drop: { [weak self] urls in
                guard let self, let state = self.state, !state.path.isEmpty else { return }
                self.store.addItems(urls, to: state.path)
            })
    }
}

/// A menu item's action as a closure.
final class MenuAction: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @MainActor @objc func fire() {
        // The menu is still closing; dialogs opened from here should wait for it.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.action() } }
    }
}

@MainActor
enum NamePrompt {
    static func ask(_ message: String, initial: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// A system-wide key combination through Carbon, which needs no extra permission.
final class HotKey {
    enum Choice: String, CaseIterable {
        case controlOptionSpace, optionSpace, controlOptionCommandSpace, off

        var title: String {
            switch self {
            case .controlOptionSpace: return "⌃⌥Space"
            case .optionSpace: return "⌥Space"
            case .controlOptionCommandSpace: return "⌃⌥⌘Space"
            case .off: return "使わない"
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .controlOptionSpace: return UInt32(controlKey | optionKey)
            case .optionSpace: return UInt32(optionKey)
            case .controlOptionCommandSpace: return UInt32(controlKey | optionKey | cmdKey)
            case .off: return 0
            }
        }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { (pressed ? hotKey.onPress : hotKey.onRelease)?() }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// False when another app already holds the combination.
    func register(_ choice: Choice) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        guard choice != .off else { return true }
        let id = EventHotKeyID(signature: OSType(0x5557_4C4E), id: 1)  // "UWLN"
        return RegisterEventHotKey(UInt32(kVK_Space), choice.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
    }
}

struct WidgetView: View {
    @ObservedObject var model: WidgetModel
    var solidBackground = false
    var onTargetFrame: @MainActor (ClickTarget, CGRect) -> Void = { _, _ in }
    var onHeight: @MainActor (CGFloat) -> Void = { _ in }

    private func reportFrame(of target: ClickTarget) -> some View {
        FrameReporter(onRemove: { onTargetFrame(target, .null) }) { onTargetFrame(target, $0) }
    }

    /// A fixed height when one is set, otherwise the content's; never past the screen's bottom.
    /// Whatever doesn't fit scrolls. The wide layout always takes its content's height.
    private var displayedHeight: CGFloat? {
        guard !model.isHorizontal else { return model.contentHeight > 0 ? model.contentHeight : nil }
        if let fixed = model.heightLimit { return min(fixed, model.screenLimit) }
        guard model.contentHeight > 0 else { return nil }
        return min(model.contentHeight, model.screenLimit)
    }

    var body: some View {
        Group {
            // The wide band is short and always shows all of itself, so it never scrolls.
            if model.isHorizontal || (solidBackground && model.heightLimit == nil) {
                content
            } else {
                ScrollView(.vertical) { content }
                    .scrollIndicators(.automatic)
                    .frame(width: widgetWidth, height: displayedHeight, alignment: .top)
            }
        }
        .onChange(of: displayedHeight) { _, height in
            if let height { onHeight(height) }
        }
        .foregroundStyle(Color.white.opacity(0.94))
        .background {
            AquariumBackground(
                level: model.memory.fraction, cpu: model.cpu ?? 0, paused: !model.isWindowVisible,
                simulation: model.aquarium, clock: model.aquariumClock)
        }
        .background {
            if solidBackground {
                Color(red: 0.11, green: 0.12, blue: 0.14)
            } else {
                VisualEffectBackground()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .overlay(alignment: model.isHorizontal ? .trailing : .bottom) {
            // The handle for dragging the edge that resizes: the bottom when upright, the right when wide.
            if !model.isLocked {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: model.isHorizontal ? 3 : 30, height: model.isHorizontal ? 30 : 3)
                    .padding(model.isHorizontal ? .trailing : .bottom, 3)
                    .allowsHitTesting(false)
            }
        }
        .overlay { SlotDragOverlay(store: model.shortcuts, drag: model.slotDrag) }
        .overlay {
            if model.isEditingLayout {
                LayoutEditOverlay(drag: model.panelDrag, horizontal: model.isHorizontal, onFrame: onTargetFrame)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var widgetWidth: CGFloat { model.isHorizontal ? model.horizontalWidth : WidgetSize.width }

    private var content: some View {
        Group {
            if model.isHorizontal { horizontalSections } else { verticalSections }
        }
        .padding(16)
        // Room for the edit bar, so it covers nothing.
        .padding(.top, model.isEditingLayout ? 22 : 0)
        .frame(width: widgetWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.contentHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, updated in model.contentHeight = updated }
            }
        }
    }

    private var eventRows: [AgendaRow] {
        model.agenda.events.map { event in
            AgendaRow(
                id: event.id, color: event.color,
                label: Format.eventTime(event, now: model.now),
                labelColor: !event.isAllDay && event.start <= model.now ? Palette.active : Palette.secondary,
                title: event.title)
        }
    }

    private var reminderRows: [AgendaRow] {
        model.agenda.reminders.map { reminder in
            AgendaRow(
                id: reminder.id, color: reminder.color,
                label: Format.reminderDue(reminder, now: model.now),
                labelColor: reminder.isOverdue(now: model.now) ? Palette.low : Palette.secondary,
                title: reminder.title)
        }
    }

    /// `inset` pulls the reported frame in, so the window's click margin stays inside a tile.
    private func eventsSection(limit: Int, stacked: Bool = false, inset: CGFloat = 0) -> some View {
        AgendaSection(
            title: "予定", symbol: "calendar", access: model.agenda.eventAccess,
            deniedNote: stacked ? "未許可（クリックで設定）" : "カレンダーへのアクセスが未許可です（クリックで設定）",
            emptyNote: stacked ? "7日以内の予定なし" : "7日以内の予定はありません",
            rows: Array(eventRows.prefix(limit)), stacked: stacked)
            .background { reportFrame(of: .calendar).padding(.horizontal, inset) }
    }

    private func remindersSection(limit: Int, stacked: Bool = false, inset: CGFloat = 0) -> some View {
        AgendaSection(
            title: "リマインダー", symbol: "checklist",
            summary: model.agenda.reminderCount > 0
                ? (stacked ? "\(model.agenda.reminderCount)" : "未完了 \(model.agenda.reminderCount)") : nil,
            access: model.agenda.reminderAccess,
            deniedNote: stacked ? "未許可（クリックで設定）" : "リマインダーへのアクセスが未許可です（クリックで設定）",
            emptyNote: stacked ? "未完了なし" : "未完了のリマインダーはありません",
            rows: Array(reminderRows.prefix(limit)), stacked: stacked)
            .background { reportFrame(of: .reminders).padding(.horizontal, inset) }
    }

    private func editable<Content: View>(
        _ id: PanelID, outset: EdgeInsets = EdgeInsets(), cornerRadius: CGFloat = 12, rows: Int? = nil,
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        // Wi-Fi's figures sit top right, so its Bluetooth stepper goes at the bottom.
        EditablePanel(
            id: id, editing: model.isEditingLayout, drag: model.panelDrag, outset: outset,
            cornerRadius: cornerRadius, rows: rows, rowsAlignment: id == .network ? .bottomTrailing : .topTrailing,
            onFrame: onTargetFrame, content: content)
    }

    private func editPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.tertiary)
            .frame(maxWidth: .infinity, minHeight: 28)
    }

    // MARK: Upright layout

    /// Media and drives only take room while there is something to show, except while editing.
    private var verticalPanels: [PanelID] {
        model.layout.vertical.filter { id in
            switch id {
            case .media: return model.isEditingLayout || !model.media.isEmpty
            case .volumes: return model.isEditingLayout || !model.volumes.isEmpty
            case .center: return false
            default: return true
            }
        }
    }

    private var verticalSections: some View {
        let panels = verticalPanels
        return VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(panels.enumerated()), id: \.element) { index, id in
                if index > 0 { Divider().overlay(Color.white.opacity(0.08)) }
                editable(
                    id, outset: EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8),
                    rows: [.events, .reminders, .network].contains(id) ? model.layout.rowCount(id) : nil
                ) { verticalPanel(id) }
            }
        }
    }

    @ViewBuilder
    private func verticalPanel(_ id: PanelID) -> some View {
        switch id {
        case .memory:
            MemorySection(memory: model.memory, cpu: model.cpu, gpu: model.gpu, disk: model.disk)
        case .codex:
            ProviderSection(
                title: "GPT / Codex", symbol: "sparkles", usage: model.codex,
                activity: model.codexActivity, now: model.now)
        case .claude:
            ProviderSection(
                title: "Claude", symbol: "asterisk", usage: model.claude,
                activity: model.claudeActivity, now: model.now, showsMascot: true, showsChevron: true,
                pending: model.pending)
                .background { reportFrame(of: .claude) }
        case .mail:
            MailSection(mail: model.mail, now: model.now)
                .background { reportFrame(of: .mail) }
        case .events:
            eventsSection(limit: model.layout.rowCount(.events))
        case .reminders:
            remindersSection(limit: model.layout.rowCount(.reminders))
        case .media:
            if model.media.isEmpty {
                editPlaceholder("メディア（再生できるときに表示）")
            } else {
                MediaSection(items: model.media, reportFrame: { reportFrame(of: $0) })
                    .background {
                        VisualizerBackground(spectrum: model.spectrum, active: model.visualizerActive)
                            .padding(.horizontal, -16)
                            .padding(.top, -6)
                            .padding(.bottom, -7)
                    }
            }
        case .volumes:
            if model.volumes.isEmpty {
                editPlaceholder("外部ストレージ（接続中に表示）")
            } else {
                VolumeSection(
                    volumes: model.volumes, ejecting: model.ejecting, error: model.volumeError,
                    reportFrame: { reportFrame(of: $0) })
            }
        case .network:
            VStack(alignment: .leading, spacing: 9) {
                WiFiRow(status: model.wifi, locationAllowed: model.locationAllowed)
                    .background { reportFrame(of: .wifi) }
                BluetoothRows(status: model.bluetooth, limit: model.layout.rowCount(.network))
                    .background { reportFrame(of: .bluetooth) }
            }
        case .shortcuts:
            ShortcutGrid(store: model.shortcuts, drag: model.slotDrag) { index, frame in
                onTargetFrame(.slot(index), frame)
            }
        case .center:
            EmptyView()
        }
    }

    // MARK: Wide layout

    /// The grip between a panel and the next one in its row, centred in the gap.
    @ViewBuilder
    private func splitter(after index: Int, in row: [PanelID], spacing: CGFloat) -> some View {
        if model.isEditingLayout, index + 1 < row.count {
            let pair = (row[index], row[index + 1])
            // In the bottom band only the Wi-Fi card has a width of its own.
            if row != model.layout.band || pair.0 == .network || pair.1 == .network {
                SplitterHandle(leading: pair.0, trailing: pair.1, onFrame: onTargetFrame)
                    .offset(x: 7 + spacing / 2)
            }
        }
    }

    private var horizontalSections: some View {
        let layout = model.layout
        let inner = model.wideInner
        let shortcuts = model.shortcutsWidth
        let topWidths = layout.widths(layout.top, inner: inner, spacing: WidgetLayout.topSpacing)
        let network = layout.clampedNetworkWidth(total: inner, shortcuts: shortcuts)
        let center = layout.centerWidth(total: inner, shortcuts: shortcuts)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: WidgetLayout.topSpacing) {
                ForEach(Array(layout.top.enumerated()), id: \.element) { index, id in
                    editable(id) { topPanel(id) }
                        .frame(width: topWidths[index])
                        .overlay(alignment: .trailing) {
                            splitter(after: index, in: layout.top, spacing: WidgetLayout.topSpacing)
                        }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: WidgetLayout.bandSpacing) {
                ForEach(Array(layout.band.enumerated()), id: \.element) { index, id in
                    Group {
                        switch id {
                        case .network:
                            editable(id) { chip { connectionChip } }.frame(width: network)
                        case .shortcuts:
                            editable(id, outset: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4), cornerRadius: 14) {
                                ShortcutGrid(store: model.shortcuts, drag: model.slotDrag, columns: model.shortcutColumns) {
                                    index, frame in onTargetFrame(.slot(index), frame)
                                }
                            }
                            .frame(width: shortcuts)
                        default:
                            editable(id, outset: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4), cornerRadius: 14) {
                                centerColumn(width: center)
                            }
                            .frame(width: center)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        splitter(after: index, in: layout.band, spacing: WidgetLayout.bandSpacing)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func topPanel(_ id: PanelID) -> some View {
        switch id {
        case .memory:
            chip { systemChip }
        case .codex:
            chip {
                providerChip(
                    title: "Codex", usage: model.codex, activity: model.codexActivity, mascot: false, pending: [])
            }
        default:
            chip {
                providerChip(
                    title: "Claude", usage: model.claude, activity: model.claudeActivity, mascot: true,
                    pending: model.pending)
            }
            // Inset so the window's click margin around sections stays inside the gap.
            .background { reportFrame(of: .claude).padding(.horizontal, 12) }
        }
    }

    /// Three tiles that together span the media below them, which sits on the bottom edge.
    /// One item each keeps the band as low as the two-column lists were.
    private func centerColumn(width: CGFloat) -> some View {
        let tiles = model.layout.tiles
        let widths = model.layout.widths(tiles, inner: width, spacing: WidgetLayout.tileSpacing)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: WidgetLayout.tileSpacing) {
                ForEach(Array(tiles.enumerated()), id: \.element) { index, id in
                    editable(id) { tilePanel(id) }
                        .frame(width: widths[index])
                        .overlay(alignment: .trailing) {
                            splitter(after: index, in: tiles, spacing: WidgetLayout.tileSpacing)
                        }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            mediaColumn
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func tilePanel(_ id: PanelID) -> some View {
        switch id {
        case .events: chip(vertical: 6) { eventsSection(limit: 1, stacked: true, inset: 6) }
        case .reminders: chip(vertical: 6) { remindersSection(limit: 1, stacked: true, inset: 6) }
        default: chip(vertical: 6) { mailTile }
        }
    }

    private func chip<Content: View>(vertical: CGFloat = 8, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func chipTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var systemChip: some View {
        let memory = model.memory
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return HStack(spacing: 10) {
            MemoryRing(fraction: memory.fraction, color: Palette.pressure(memory.pressure))
                .scaleEffect(0.76)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    chipTitle("メモリ")
                    Spacer(minLength: 4)
                    Text("\(Format.gigabytes(memory.used)) / \(Format.gigabytes(memory.total)) GB")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        Palette.appMemory.frame(width: max(0, proxy.size.width * memory.app / memory.total))
                        Palette.wired.frame(width: max(0, proxy.size.width * memory.wired / memory.total))
                        Palette.compressed.frame(width: max(0, proxy.size.width * memory.compressed / memory.total))
                        Spacer(minLength: 0)
                    }
                    .background(Palette.track)
                    .clipShape(Capsule())
                }
                .frame(height: 6)
                HStack(spacing: 12) {
                    figure("CPU", percent(model.cpu))
                    figure("GPU", percent(model.gpu))
                    Spacer(minLength: 4)
                }
                HStack(spacing: 12) {
                    figure("読み", model.disk.map { format($0.read) } ?? "--")
                    figure("書き", model.disk.map { format($0.written) } ?? "--")
                    Spacer(minLength: 4)
                }
            }
        }
    }

    private func providerChip(
        title: String, usage: ProviderUsage, activity: ActivityState, mascot: Bool, pending: [PendingItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if mascot {
                    PixelMascot(isActive: activity.isActive)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.secondary)
                }
                chipTitle(title)
                if activity.isActive {
                    ActivityBadge(activity: activity).padding(.leading, 2)
                }
                Spacer(minLength: 0)
                if !pending.isEmpty {
                    Text("承認待ち \(pending.count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Palette.warn)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            ForEach(usage.windows) { window in
                let remaining = window.remaining
                let color = remaining.map(Palette.remaining) ?? Palette.tertiary
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Palette.secondary)
                        Spacer(minLength: 2)
                        Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(color)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.track)
                            Capsule().fill(color).frame(width: proxy.size.width * (remaining ?? 0) / 100)
                        }
                    }
                    .frame(height: 4)
                }
            }
            if let note = usage.note, usage.updatedAt == nil {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.warn)
                    .lineLimit(2)
            }
        }
    }

    private func connectionRow(_ symbol: String, _ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
        }
        .contentShape(Rectangle())
    }

    /// Wi-Fi and Bluetooth with the same detail the vertical layout gives, squeezed into a narrow card.
    private var connectionChip: some View {
        let wifi = model.wifi
        let wifiText: (String, Color) = {
            if !wifi.hasInterface { return ("なし", Palette.tertiary) }
            if !wifi.isOn { return ("オフ", Palette.tertiary) }
            if !wifi.isConnected { return ("未接続", Palette.warn) }
            if wifi.rssi >= -60 { return ("強", Palette.good) }
            return wifi.rssi >= -70 ? ("中", Palette.warn) : ("弱", Palette.low)
        }()
        let bluetooth = model.bluetooth
        let bluetoothText: String = {
            switch bluetooth.isOn {
            case nil: return "--"
            case false?: return "オフ"
            case true?: return "\(bluetooth.devices.count)台"
            }
        }()
        let deviceLimit = 3
        let shown = bluetooth.devices.count > deviceLimit ? deviceLimit - 1 : deviceLimit
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                connectionRow(wifi.isOn ? "wifi" : "wifi.slash", "Wi-Fi", wifiText.0, color: wifiText.1)
                if wifi.isConnected {
                    if let name = wifi.name {
                        connectionDetail(name, color: .primary)
                    } else if model.locationAllowed == false {
                        connectionDetail("名前は未許可", color: Palette.warn)
                    }
                    HStack(spacing: 0) {
                        Text("\(wifi.rssi) dBm")
                        Spacer(minLength: 4)
                        Text("\(Int(wifi.rate)) Mbps")
                    }
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
                    .padding(.leading, 19)
                }
            }
            .background { reportFrame(of: .wifi) }
            VStack(alignment: .leading, spacing: 3) {
                connectionRow("dot.radiowaves.left.and.right", "Bluetooth", bluetoothText, color: Palette.secondary)
                ForEach(bluetooth.devices.prefix(shown)) { device in
                    HStack(spacing: 4) {
                        Text(device.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 2)
                        if let lowest = device.lowestBattery {
                            // The full left/right/case breakdown doesn't fit; the weakest part matters most.
                            Text("\(lowest)%")
                                .font(.system(size: 10, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(lowest <= 20 ? Palette.low : Palette.secondary)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 10.5))
                    .padding(.leading, 19)
                }
                if bluetooth.devices.count > shown {
                    connectionDetail("ほか \(bluetooth.devices.count - shown)台", color: Palette.tertiary)
                }
            }
            .background { reportFrame(of: .bluetooth) }
        }
    }

    private func connectionDetail(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, 19)
    }

    private var mailTile: some View {
        let mail = model.mail
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                Text("メール").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("未読")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                Text(mail.unread.map(String.init) ?? "--")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle((mail.unread ?? 0) > 0 ? Palette.active : Palette.secondary)
                Spacer(minLength: 4)
                Text(mail.note == nil ? Format.age(mail.updatedAt, now: model.now) : "要確認")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(mail.note == nil ? Palette.tertiary : Palette.warn)
                    .lineLimit(1)
            }
        }
        .background { reportFrame(of: .mail).padding(.horizontal, 6) }
    }

    @ViewBuilder private var mediaColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.volumes.isEmpty {
                VolumeSection(
                    volumes: model.volumes, ejecting: model.ejecting, error: model.volumeError,
                    reportFrame: { reportFrame(of: $0) })
            }
            if !model.media.isEmpty {
                MediaSection(items: model.media, reportFrame: { reportFrame(of: $0) })
                    .padding(.vertical, 4)
                    .background {
                        // Down through the padding, so the bars stand on the widget's bottom edge.
                        VisualizerBackground(spectrum: model.spectrum, active: model.visualizerActive)
                            .padding(.horizontal, -8)
                            .padding(.bottom, -16)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous))
                    }
            }
            if model.media.isEmpty && model.volumes.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                    Text("再生中のメディアはありません")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Palette.tertiary)
                .padding(.top, 4)
            }
        }
    }
}

enum WidgetSize {
    /// Measured from a medium system widget on the desktop.
    static let width: CGFloat = 344
    static let height: CGFloat = 375
}

// MARK: - App

enum ClickTarget: Hashable {
    case claude, mail, calendar, reminders
    case slot(Int)
    case volume(URL), eject(URL)
    case wifi, bluetooth
    case media(MediaSource, MediaAction), mediaRow(MediaSource)
    /// Only while the layout is edited.
    case panel(PanelID), splitter(PanelID, PanelID), rows(PanelID, Int), layoutDone
}

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// In SwiftUI's global coordinates, whose origin is the top left of the window.
    var targetFrames: [ClickTarget: CGRect] = [:]
    var onTargetClick: ((ClickTarget) -> Void)?
    var menuForTarget: ((ClickTarget) -> NSMenu?)?
    /// While locked, dragging doesn't move the widget; clicks still work.
    var isLocked = false
    private var pressedTarget: ClickTarget?
    /// Filled tiles can be dragged onto another slot; the window then stays put.
    var canDragSlot: ((Int) -> Bool)?
    var slotDrag: SlotDragState?
    var onSlotMove: ((Int, Int) -> Void)?
    /// The new height while the bottom edge is dragged, and whether the drag has ended.
    var onResizeHeight: ((CGFloat, Bool) -> Void)?
    /// The wide layout resizes from its right edge instead of the bottom.
    var resizesWidth = false
    var onResizeWidth: ((CGFloat, Bool) -> Void)?
    /// While the layout is edited, presses go to the panels instead of what they show.
    var isEditingLayout = false
    var panelDrag: PanelDragState?
    var canSwapPanels: ((PanelID, PanelID) -> Bool)?
    var onPanelMove: ((PanelID, PanelID) -> Void)?
    /// The border between two panels moved this far from where the drag began, and whether it ended.
    var onPanelResize: ((PanelID, PanelID, CGFloat, Bool) -> Void)?
    var onLayoutAction: ((ClickTarget) -> Void)?

    /// The innermost panel under the point that `accepts` allows.
    private func panel(at point: CGPoint, where accepts: (PanelID) -> Bool = { _ in true }) -> PanelID? {
        targetFrames.compactMap { target, rect -> (PanelID, CGFloat)? in
            guard case .panel(let id) = target, rect.contains(point), accepts(id) else { return nil }
            return (id, rect.width * rect.height)
        }.min { $0.1 < $1.1 }?.0
    }

    private func editControl(at point: CGPoint) -> ClickTarget? {
        targetFrames.first { target, rect in
            switch target {
            case .layoutDone, .rows: return rect.contains(point)
            case .splitter: return rect.insetBy(dx: -3, dy: 0).contains(point)
            default: return false
            }
        }?.key
    }

    private func handleLayoutEdit(_ event: NSEvent) {
        let start = event.locationInWindow
        let point = flipped(start)
        switch editControl(at: point) {
        case .splitter(let a, let b)?:
            let startX = NSEvent.mouseLocation.x
            NSCursor.resizeLeftRight.push()
            while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let finished = next.type == .leftMouseUp
                onPanelResize?(a, b, NSEvent.mouseLocation.x - startX, finished)
                if finished { break }
            }
            NSCursor.pop()
            return
        case let control?:
            onLayoutAction?(control)
            return
        case nil:
            break
        }
        guard let source = panel(at: point) else {
            if !isLocked { performDrag(with: event) }
            return
        }
        var dragging = false
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            if !dragging, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                dragging = true
                panelDrag?.source = source
            }
            if dragging {
                let location = flipped(next.locationInWindow)
                panelDrag?.location = location
                panelDrag?.target = panel(at: location) { [canSwapPanels] in canSwapPanels?(source, $0) == true }
            }
        }
        if dragging, let target = panelDrag?.target { onPanelMove?(source, target) }
        panelDrag?.source = nil
        panelDrag?.target = nil
    }

    private func flipped(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: frame.height - point.y)
    }

    private func slot(at point: CGPoint) -> Int? {
        targetFrames.first { target, rect in
            if case .slot = target { return rect.contains(point) }
            return false
        }.flatMap { target, _ in
            if case .slot(let index) = target { return index }
            return nil
        }
    }

    /// Follows the mouse until it is released. Returns false when it never moved far enough to
    /// count as a drag, so the press is still a click.
    private func trackSlotDrag(from index: Int, startingAt start: NSPoint) -> Bool {
        var dragging = false
        while let event = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = flipped(event.locationInWindow)
            if event.type == .leftMouseUp {
                guard dragging else { return false }
                let destination = slot(at: point)
                slotDrag?.source = nil
                slotDrag?.target = nil
                if let destination, destination != index { onSlotMove?(index, destination) }
                return true
            }
            if !dragging, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 {
                dragging = true
                slotDrag?.source = index
            }
            if dragging {
                slotDrag?.location = point
                slotDrag?.target = slot(at: point)
            }
        }
        slotDrag?.source = nil
        slotDrag?.target = nil
        return dragging
    }

    private func target(at point: NSPoint) -> ClickTarget? {
        let flipped = CGPoint(x: point.x, y: frame.height - point.y)
        return targetFrames.first { target, rect in
            // Sections get a margin up to the dividers; smaller items sit too close together for one.
            switch target {
            case .slot, .volume, .eject, .wifi, .bluetooth, .media, .mediaRow: return rect.contains(flipped)
            case .panel, .splitter, .rows, .layoutDone: return false
            case .claude, .mail, .calendar, .reminders: return rect.insetBy(dx: -16, dy: -6).contains(flipped)
            }
        }?.key
    }

    /// SwiftUI's inner views claim mouse events before the window can see them,
    /// so dragging and the context menu are handled here instead of in a view.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.control), .rightMouseDown:
            let targeted = target(at: event.locationInWindow).flatMap { menuForTarget?($0) }
            if let view = contentView, let menu = targeted ?? view.menu {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
            }
        case .leftMouseDown where !isLocked && resizesWidth && event.locationInWindow.x > frame.width - 8:
            let startX = NSEvent.mouseLocation.x
            let startWidth = frame.width
            while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let finished = next.type == .leftMouseUp
                onResizeWidth?(startWidth + NSEvent.mouseLocation.x - startX, finished)
                if finished { break }
            }
        case .leftMouseDown where !isLocked && !resizesWidth && event.locationInWindow.y < 8:
            let startY = NSEvent.mouseLocation.y
            let startHeight = frame.height
            while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let finished = next.type == .leftMouseUp
                onResizeHeight?(startHeight + startY - NSEvent.mouseLocation.y, finished)
                if finished { break }
            }
        case .leftMouseDown where isEditingLayout:
            handleLayoutEdit(event)
        case .leftMouseDown where {
            if case .slot(let index)? = target(at: event.locationInWindow) { return canDragSlot?(index) == true }
            return false
        }():
            guard case .slot(let index)? = target(at: event.locationInWindow) else { return }
            if !trackSlotDrag(from: index, startingAt: event.locationInWindow) {
                onTargetClick?(.slot(index))
            }
        case .leftMouseDown where isLocked:
            pressedTarget = target(at: event.locationInWindow)
        case .leftMouseUp where isLocked:
            // A press that ends on the item it started on is a click.
            let pressed = pressedTarget
            pressedTarget = nil
            if let pressed, target(at: event.locationInWindow) == pressed {
                onTargetClick?(pressed)
            }
        case .leftMouseDown:
            // performDrag returns on mouse up, so an unmoved window means this was a click.
            let origin = frame.origin
            let clicked = target(at: event.locationInWindow)
            performDrag(with: event)
            if frame.origin == origin, let clicked {
                onTargetClick?(clicked)
            }
        default:
            super.sendEvent(event)
        }
    }
}

/// Starts the widget at login once it lives in an Applications folder. Turned on by itself only
/// the first time, so switching it off from the menu or System Settings sticks.
@MainActor
enum LoginItem {
    private static let offeredKey = "LoginItemOffered"

    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func enableOnFirstInstall() {
        let defaults = UserDefaults.standard
        guard isInstalled, !defaults.bool(forKey: offeredKey) else { return }
        defaults.set(true, forKey: offeredKey)
        if status != .enabled { try? SMAppService.mainApp.register() }
    }

    static func toggle() {
        switch status {
        case .enabled:
            try? SMAppService.mainApp.unregister()
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
        default:
            do {
                try SMAppService.mainApp.register()
            } catch {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = WidgetModel()
    private var window: DesktopWindow?
    private var statusItem: NSStatusItem?
    private var occlusionObserver: NSObjectProtocol?
    private let loginItem = NSMenuItem(title: "ログイン時に起動", action: nil, keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "位置を固定", action: nil, keyEquivalent: "")
    private let layoutItem = NSMenuItem(title: "レイアウトを編集", action: nil, keyEquivalent: "")
    private let claudeAPIItem = NSMenuItem(title: "Claude使用量をAPIで取得", action: nil, keyEquivalent: "")
    private static let lockedKey = "PositionLocked"
    private static let heightKey = "FixedHeight"
    private static let minimumHeight: CGFloat = 240
    private let heightMenu = NSMenuItem(title: "ウィジェットの高さ", action: nil, keyEquivalent: "")
    private let orientationMenu = NSMenuItem(title: "ウィジェットの向き", action: nil, keyEquivalent: "")
    private static let horizontalKey = "Horizontal"
    private static let widthKey = "HorizontalWidth"
    private static let minimumWidth: CGFloat = 900
    private var screenObservers: [NSObjectProtocol] = []
    private lazy var launcher = LauncherController(store: model.shortcuts)
    private let hotKey = HotKey()
    private let hotKeyMenu = NSMenuItem(title: "ランチャーのホットキー", action: nil, keyEquivalent: "")
    private static let hotKeyKey = "LauncherHotKey"
    private var hotKeyFailed = false

    private func openApp(_ bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = makeMenu()
        let hosting = NSHostingView(rootView: WidgetView(model: model, onTargetFrame: { [weak self] target, frame in
            self?.window?.targetFrames[target] = frame.isNull ? nil : frame
        }, onHeight: { [weak self] height in
            self?.resizeWindow(toHeight: height)
        }))
        hosting.sizingOptions = []
        hosting.menu = menu

        model.isHorizontal = UserDefaults.standard.bool(forKey: Self.horizontalKey)
        let savedWidth = UserDefaults.standard.double(forKey: Self.widthKey)
        if savedWidth > 0 { model.horizontalWidth = savedWidth }
        let size = NSSize(
            width: model.isHorizontal ? model.horizontalWidth : WidgetSize.width,
            height: model.isHorizontal ? 240 : WidgetSize.height)
        let window = DesktopWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.isLocked = UserDefaults.standard.bool(forKey: Self.lockedKey)
        model.isLocked = window.isLocked
        let savedHeight = UserDefaults.standard.double(forKey: Self.heightKey)
        model.heightLimit = savedHeight > 0 ? savedHeight : nil
        window.onResizeHeight = { [weak self] height, finished in
            guard let self else { return }
            let clamped = min(max(Self.minimumHeight, height), self.model.screenLimit)
            self.model.heightLimit = clamped
            if finished { UserDefaults.standard.set(Double(clamped), forKey: Self.heightKey) }
        }
        window.resizesWidth = model.isHorizontal
        window.onResizeWidth = { [weak self] width, finished in
            guard let self else { return }
            let clamped = min(max(Self.minimumWidth, width), self.maximumWidth)
            self.model.horizontalWidth = clamped
            self.resizeWindow(toWidth: clamped)
            if finished { UserDefaults.standard.set(Double(clamped), forKey: Self.widthKey) }
        }
        window.slotDrag = model.slotDrag
        window.canDragSlot = { [weak self] index in self?.model.shortcuts.slots[index] != nil }
        window.onSlotMove = { [weak self] source, destination in
            self?.model.shortcuts.move(from: source, to: destination)
        }
        window.panelDrag = model.panelDrag
        window.canSwapPanels = { [weak self] a, b in
            guard let self else { return false }
            return self.model.layout.canSwap(a, b, horizontal: self.model.isHorizontal)
        }
        window.onPanelMove = { [weak self] source, target in
            withAnimation(.easeInOut(duration: 0.2)) { self?.model.movePanel(source, onto: target) }
        }
        window.onPanelResize = { [weak self] a, b, dx, finished in
            self?.model.resizePanels(a, b, by: dx, finished: finished)
        }
        window.onLayoutAction = { [weak self] action in
            switch action {
            case .layoutDone: self?.setEditingLayout(false)
            case .rows(let id, let delta): self?.model.changeRows(id, by: delta)
            default: break
            }
        }
        window.menuForTarget = { [weak self] target in
            guard case .slot(let index) = target else { return nil }
            return self?.makeSlotMenu(index)
        }
        window.onTargetClick = { [weak self] target in
            switch target {
            case .slot(let index):
                self?.openSlot(index)
            case .claude:
                NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
            case .mail:
                self?.openApp("com.apple.mail")
            case .wifi:
                if self?.model.locationAllowed == false {
                    self?.openPrivacySettings("Privacy_LocationServices")
                } else {
                    self?.openSettings("com.apple.wifi-settings-extension")
                }
            case .bluetooth:
                self?.openSettings("com.apple.BluetoothSettings")
            case .media(let source, let action):
                self?.model.sendMedia(action, to: source)
            case .mediaRow(let source):
                guard let item = self?.model.media.first(where: { $0.source == source }) else { return }
                if item.access == .automationDenied {
                    self?.openPrivacySettings("Privacy_Automation")
                } else if source == .spotify {
                    self?.openApp("com.spotify.client")
                } else {
                    Task.detached(priority: .userInitiated) { MediaReader.bringToFront(item) }
                }
            case .volume(let url):
                NSWorkspace.shared.open(url)
            case .eject(let url):
                self?.model.eject(url)
            case .calendar:
                if self?.model.agenda.eventAccess == .denied {
                    self?.openPrivacySettings("Privacy_Calendars")
                } else {
                    self?.openApp("com.apple.iCal")
                }
            case .reminders:
                if self?.model.agenda.reminderAccess == .denied {
                    self?.openPrivacySettings("Privacy_Reminders")
                } else {
                    self?.openApp("com.apple.reminders")
                }
            case .panel, .splitter, .rows, .layoutDone:
                break
            }
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // Directly above the desktop icons, below every normal window.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let autosaveName = "AquadeskFrame"
        if !window.setFrameUsingName(autosaveName), let screen = NSScreen.main {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.maxX - size.width - 24, y: area.maxY - size.height - 24))
        }
        // A saved frame can predate a size change; grow downward so the top edge stays put.
        let saved = window.frame
        if saved.size != size {
            let bottom = NSScreen.main?.visibleFrame.minY ?? 0
            window.setFrame(
                NSRect(x: saved.minX, y: max(bottom, saved.maxY - size.height), width: size.width, height: size.height),
                display: false)
        }
        window.setFrameAutosaveName(autosaveName)
        window.orderFrontRegardless()
        self.window = window
        updateScreenLimit()
        screenObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateScreenLimit() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateScreenLimit() }
            },
        ]
        // A desktop-level widget is often fully covered; the animation needn't run then.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.model.isWindowVisible = window.occlusionState.contains(.visible)
            }
        }

        // Clicks on the desktop-level window can be missed, so quitting also lives in the menu bar.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Aquadesk")
        item.menu = menu
        statusItem = item

        model.start()
        LoginItem.enableOnFirstInstall()
        hotKey.onPress = { [weak self] in MainActor.assumeIsolated { self?.launcher.hotKeyPressed() } }
        hotKey.onRelease = { [weak self] in MainActor.assumeIsolated { self?.launcher.hotKeyReleased() } }
        applyHotKey()
    }

    /// Rows come and go, so the window follows its content while the top edge stays put.
    private func updateScreenLimit() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let room = max(Self.minimumHeight, window.frame.maxY - screen.visibleFrame.minY - 8)
        if room != model.screenLimit { model.screenLimit = room }
    }

    @objc private func followContentHeight() {
        model.heightLimit = nil
        UserDefaults.standard.removeObject(forKey: Self.heightKey)
    }

    @objc private func fixCurrentHeight() {
        guard let window else { return }
        model.heightLimit = window.frame.height
        UserDefaults.standard.set(Double(window.frame.height), forKey: Self.heightKey)
    }

    private var maximumWidth: CGFloat {
        let screen = window?.screen ?? NSScreen.main
        return max(Self.minimumWidth, (screen?.visibleFrame.width ?? 1600) - 16)
    }

    private func resizeWindow(toWidth width: CGFloat) {
        guard let window, window.frame.width != width else { return }
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: true)
    }

    private static func originKey(horizontal: Bool) -> String {
        horizontal ? "TopLeftHorizontal" : "TopLeftVertical"
    }

    /// Each orientation remembers where its top left corner was, since a wide band and a tall
    /// column rarely belong in the same place.
    private func setOrientation(horizontal: Bool) {
        guard let window, horizontal != model.isHorizontal else { return }
        let defaults = UserDefaults.standard
        let frame = window.frame
        defaults.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.originKey(horizontal: !horizontal))
        var topLeft = defaults.string(forKey: Self.originKey(horizontal: horizontal)).map(NSPointFromString)
            ?? NSPoint(x: frame.minX, y: frame.maxY)
        let width = horizontal ? min(model.horizontalWidth, maximumWidth) : WidgetSize.width
        if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
            topLeft.x = min(max(area.minX, topLeft.x), area.maxX - width)
            topLeft.y = min(max(area.minY + 120, topLeft.y), area.maxY)
        }
        model.horizontalWidth = horizontal ? width : model.horizontalWidth
        model.isHorizontal = horizontal
        window.resizesWidth = horizontal
        defaults.set(horizontal, forKey: Self.horizontalKey)
        // The height follows once the new layout has measured itself.
        window.setFrame(NSRect(x: topLeft.x, y: topLeft.y - frame.height, width: width, height: frame.height), display: true)
        updateScreenLimit()
    }

    @objc private func chooseOrientation(_ item: NSMenuItem) {
        setOrientation(horizontal: item.tag == 1)
    }

    private func resizeWindow(toHeight height: CGFloat) {
        guard let window, height > 0, window.frame.height != height else { return }
        let frame = window.frame
        window.setFrame(
            NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
    }

    private func openSlot(_ index: Int) {
        let shortcuts = model.shortcuts
        guard let slot = shortcuts.slots[index] else {
            showAddMenu(forSlot: index)
            return
        }
        guard slot.isLauncher else {
            shortcuts.open(index)
            return
        }
        guard let window, let rect = window.targetFrames[.slot(index)] else { return }
        let point = NSPoint(x: window.frame.minX + rect.midX, y: window.frame.maxY - rect.midY)
        launcher.toggle(slot: index, around: point)
    }

    /// Empty tiles offer every kind of item, from a click as well as from the context menu.
    private func addItems(forSlot index: Int, to menu: NSMenu) {
        for kind in AddKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(addToSlot(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
    }

    private func showAddMenu(forSlot index: Int) {
        guard let window, let view = window.contentView, let rect = window.targetFrames[.slot(index)] else { return }
        let menu = NSMenu()
        addItems(forSlot: index, to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.midX, y: window.frame.height - rect.midY), in: view)
    }

    @objc private func addToSlot(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let kind = AddKind(rawValue: raw) else { return }
        let index = item.tag
        ItemPrompt.make(kind, multiple: false) { [weak self] entries in
            guard let self, let entry = entries.first else { return }
            self.model.shortcuts.put(entry, in: index)
            // A fresh launcher is empty; ask for its contents straight away.
            if entry.isLauncher {
                ItemPrompt.make(.files, multiple: true) { items in self.model.shortcuts.add(items, to: [index]) }
            }
        }
    }

    private func makeSlotMenu(_ index: Int) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        let slot = model.shortcuts.slots[index]
        if slot == nil {
            addItems(forSlot: index, to: menu)
        } else if slot?.isLauncher == true {
            add("開く", #selector(openShortcut(_:)))
            add("項目を追加…", #selector(addLauncherItems(_:)))
            add("名前を変更…", #selector(renameLauncher(_:)))
            add("削除", #selector(removeShortcut(_:)))
        } else if slot?.kind != .file {
            add("開く", #selector(openShortcut(_:)))
            add("名前を変更…", #selector(renameLauncher(_:)))
            add("削除", #selector(removeShortcut(_:)))
        } else {
            add("開く", #selector(openShortcut(_:)))
            add("変更…", #selector(chooseShortcut(_:)))
            add("削除", #selector(removeShortcut(_:)))
        }
        return menu
    }

    @objc private func openShortcut(_ item: NSMenuItem) { openSlot(item.tag) }

    @objc private func addLauncherItems(_ item: NSMenuItem) {
        model.shortcuts.chooseItems(for: [item.tag]) {}
    }

    @objc private func renameLauncher(_ item: NSMenuItem) {
        let index = item.tag
        guard let current = model.shortcuts.slots[index],
              let name = NamePrompt.ask("名前を変更", initial: current.displayName) else { return }
        model.shortcuts.rename([index], to: name)
    }
    @objc private func chooseShortcut(_ item: NSMenuItem) { model.shortcuts.choose(for: item.tag) }
    @objc private func removeShortcut(_ item: NSMenuItem) { model.shortcuts.remove(item.tag) }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let about = NSMenuItem(title: "Aquadesk v\(AppInfo.version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "今すぐ更新", action: #selector(refreshNow), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let hotKeys = NSMenu()
        for choice in HotKey.Choice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(chooseHotKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            hotKeys.addItem(item)
        }
        hotKeyMenu.submenu = hotKeys
        menu.addItem(hotKeyMenu)
        let heights = NSMenu()
        for (title, action) in [("内容に合わせる", #selector(followContentHeight)), ("今の高さで固定", #selector(fixCurrentHeight))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            heights.addItem(item)
        }
        heights.addItem(.separator())
        let hint = NSMenuItem(title: "位置の固定を外すと、下端のドラッグでも調整できます", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        heights.addItem(hint)
        heightMenu.submenu = heights
        let orientations = NSMenu()
        for (title, tag) in [("縦向き", 0), ("横向き（縦長の画面向け）", 1)] {
            let item = NSMenuItem(title: title, action: #selector(chooseOrientation(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            orientations.addItem(item)
        }
        orientations.addItem(.separator())
        let widthHint = NSMenuItem(title: "横向きでは、位置の固定を外すと右端のドラッグで幅を調整できます", action: nil, keyEquivalent: "")
        widthHint.isEnabled = false
        orientations.addItem(widthHint)
        orientationMenu.submenu = orientations
        menu.addItem(orientationMenu)
        menu.addItem(heightMenu)
        layoutItem.action = #selector(toggleEditingLayout)
        layoutItem.target = self
        menu.addItem(layoutItem)
        let resetLayout = NSMenuItem(title: "レイアウトを元に戻す（今の向き）", action: #selector(resetLayout), keyEquivalent: "")
        resetLayout.target = self
        menu.addItem(resetLayout)
        lockItem.action = #selector(toggleLock)
        lockItem.target = self
        menu.addItem(lockItem)
        claudeAPIItem.action = #selector(toggleClaudeAPI)
        claudeAPIItem.target = self
        menu.addItem(claudeAPIItem)
        loginItem.action = #selector(toggleLoginItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.delegate = self
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        return menu
    }

    private var hotKeyChoice: HotKey.Choice {
        UserDefaults.standard.string(forKey: Self.hotKeyKey).flatMap(HotKey.Choice.init) ?? .controlOptionSpace
    }

    private func applyHotKey() {
        hotKeyFailed = !hotKey.register(hotKeyChoice)
    }

    @objc private func chooseHotKey(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: Self.hotKeyKey)
        applyHotKey()
        if hotKeyFailed { NSSound.beep() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in orientationMenu.submenu?.items ?? [] where item.action != nil {
            item.state = (item.tag == 1) == model.isHorizontal ? .on : .off
        }
        // The wide layout always fits its content, so a fixed height has nothing to do there.
        heightMenu.isHidden = model.isHorizontal
        let fixed = model.heightLimit != nil
        heightMenu.submenu?.items.first?.state = fixed ? .off : .on
        heightMenu.submenu?.items.dropFirst().first?.state = fixed ? .on : .off
        let choice = hotKeyChoice
        hotKeyMenu.title = hotKeyFailed
            ? "ランチャーのホットキー（\(choice.title) は他のアプリが使用中）"
            : "ランチャーのホットキー（\(choice.title)）"
        for item in hotKeyMenu.submenu?.items ?? [] {
            item.state = item.representedObject as? String == choice.rawValue ? .on : .off
        }
        lockItem.state = window?.isLocked == true ? .on : .off
        layoutItem.state = model.isEditingLayout ? .on : .off
        claudeAPIItem.state = WidgetModel.claudeAPIEnabled ? .on : .off
        guard LoginItem.isInstalled else {
            loginItem.title = "ログイン時に起動（アプリケーションフォルダに入れると使えます）"
            loginItem.isEnabled = false
            loginItem.state = .off
            return
        }
        let status = LoginItem.status
        loginItem.isEnabled = true
        loginItem.state = status == .enabled ? .on : .off
        loginItem.title = status == .requiresApproval ? "ログイン時に起動（システム設定で承認待ち）" : "ログイン時に起動"
    }

    @objc private func toggleEditingLayout() {
        setEditingLayout(!model.isEditingLayout)
    }

    private func setEditingLayout(_ editing: Bool) {
        model.isEditingLayout = editing
        window?.isEditingLayout = editing
    }

    @objc private func resetLayout() {
        withAnimation(.easeInOut(duration: 0.2)) { model.resetLayout() }
    }

    @objc private func toggleLock() {
        guard let window else { return }
        window.isLocked.toggle()
        model.isLocked = window.isLocked
        UserDefaults.standard.set(window.isLocked, forKey: Self.lockedKey)
    }

    @objc private func toggleClaudeAPI() {
        model.setClaudeAPI(enabled: !WidgetModel.claudeAPIEnabled)
    }

    @objc private func toggleLoginItem() {
        LoginItem.toggle()
    }

    @objc private func refreshNow() {
        model.refreshAll()
    }
}

@MainActor
func addSampleLauncher(to store: ShortcutStore, slot: Int) {
    store.createLauncher(at: slot, name: "よく使う")
    let apps = ["/System/Applications/Utilities/Terminal.app", "/System/Applications/Notes.app",
                "/System/Applications/Calendar.app", "/Applications/Safari.app", "/Applications", "/etc/hosts"]
    store.addItems(apps.map { URL(fileURLWithPath: $0) }, to: [slot])
    store.addLauncher(named: "入れ子の見本", to: [slot])
    store.addItems([URL(fileURLWithPath: "/System/Applications/Mail.app")], to: [slot, 6])
    store.add([
        Shortcut(bookmark: nil, path: "", name: "見本サイト", link: "https://example.com"),
        Shortcut(bookmark: nil, path: "", workflow: "見本のショートカット"),
        Shortcut(bookmark: nil, path: "", name: "朝の作業", group: [
            URL(fileURLWithPath: "/System/Applications/Mail.app"), URL(fileURLWithPath: "/System/Applications/Calendar.app"),
        ].compactMap(Shortcut.file)),
    ], to: [slot])
}

@MainActor
func renderLauncherSnapshot(to path: String) {
    let store = ShortcutStore()
    store.persists = false
    addSampleLauncher(to: store, slot: 4)
    let root = CommandLine.arguments.contains("--root")
    if root {
        store.persists = false
        store.put(Shortcut(bookmark: nil, path: "", name: "見本サイト", link: "https://example.com"), in: 0)
        if let mail = Shortcut.file(URL(fileURLWithPath: "/System/Applications/Mail.app")) { store.put(mail, in: 2) }
    }
    let state = LauncherState(path: root ? [] : [4], origin: .zero)
    state.expanded = true
    state.hovered = root ? 0 : 8
    _ = NSApplication.shared
    let hosting = NSHostingView(rootView: LauncherRingView(store: store, state: state, solidBackground: true)
        .background(Color(red: 0.25, green: 0.27, blue: 0.3)))
    hosting.frame = NSRect(x: 0, y: 0, width: LauncherLayout.side, height: LauncherLayout.side)
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]),
          FileManager.default.createFile(atPath: path, contents: png) else { exit(1) }
    print("launcher snapshot items=\(store.item(at: [4])?.items?.count ?? -1) nested=\(store.item(at: [4, 6])?.items?.count ?? -1)")
}

@MainActor
func renderSnapshot(to path: String, sampleClaude: String?) {
    let model = WidgetModel()
    model.loadOffline()
    if let sampleClaude {
        guard let data = FileManager.default.contents(atPath: sampleClaude),
              let reading = ClaudeReader.parse(data, fetchedAt: Date())
        else {
            print("sample parse failed")
            exit(1)
        }
        print("parsed five=\(reading.fiveHourUsed ?? -1) seven=\(reading.sevenDayUsed ?? -1)")
        model.claude = ProviderUsage(
            windows: [
                LimitWindow(id: "five", label: "5時間", usedPercent: reading.fiveHourUsed, resetsAt: reading.fiveHourResets),
                LimitWindow(id: "seven", label: "週間", usedPercent: reading.sevenDayUsed, resetsAt: reading.sevenDayResets),
            ],
            updatedAt: reading.fetchedAt)
    }
    if CommandLine.arguments.contains("--sample-activity") {
        model.codexActivity = ActivityState(isActive: true, tokensPerMinute: 12_400)
        model.claudeActivity = ActivityState(isActive: true, tokensPerMinute: 0)
    }
    if CommandLine.arguments.contains("--sample-mail") {
        model.mail = MailReader.parse("12")
    }
    if CommandLine.arguments.contains("--sample-shortcuts") {
        model.shortcuts.persists = false
        let samples = ["/System/Applications/Mail.app", "/System/Applications/Calendar.app", "/Applications", "/etc/hosts"]
        for (index, path) in samples.enumerated() {
            model.shortcuts.assign(URL(fileURLWithPath: path), to: index)
        }
        addSampleLauncher(to: model.shortcuts, slot: 4)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--sample-horizontal") {
        model.isHorizontal = true
        if index + 1 < CommandLine.arguments.count, let width = Double(CommandLine.arguments[index + 1]) {
            model.horizontalWidth = width
        }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--sample-height"), index + 1 < CommandLine.arguments.count,
       let height = Double(CommandLine.arguments[index + 1]) {
        model.heightLimit = height
    }
    if CommandLine.arguments.contains("--sample-slot-drag") {
        model.slotDrag.source = 1
        model.slotDrag.target = 6
        model.slotDrag.location = CGPoint(x: 230, y: 690)
    }
    if CommandLine.arguments.contains("--sample-agenda") {
        let now = Date()
        let blue = Color(red: 0.3, green: 0.6, blue: 1), green = Color(red: 0.3, green: 0.8, blue: 0.5)
        func event(_ id: String, _ title: String, hours: Double, length: Double = 1, allDay: Bool = false) -> AgendaEvent {
            let start = now.addingTimeInterval(hours * 3600)
            return AgendaEvent(
                id: id, title: title, start: start, end: start.addingTimeInterval(length * 3600),
                isAllDay: allDay, color: id == "holiday" ? green : blue)
        }
        func reminder(_ id: String, _ title: String, hours: Double?, hasTime: Bool = true) -> AgendaReminder {
            AgendaReminder(
                id: id, title: title, due: hours.map { now.addingTimeInterval($0 * 3600) },
                hasTime: hasTime, color: green)
        }
        // Out of order, with one finished event and one extra of each, to exercise the sorting.
        model.agenda = AgendaSnapshot(
            eventAccess: .granted,
            events: AgendaReader.arrange([
                event("later", "週をまたぐ見本の予定", hours: 72),
                event("done", "終わった予定（出ないはず）", hours: -3),
                event("holiday", "終日の見本（時刻つきより後）", hours: -0.5, length: 24, allDay: true),
                event("now", "開催中の見本の予定 名前が長い場合の表示を確認するための行", hours: -0.5),
                event("next", "明日の見本の予定", hours: 24),
            ], now: now),
            reminderAccess: .granted,
            reminders: AgendaReader.arrange([
                reminder("none", "期限なしの見本（最後）", hours: nil),
                reminder("over", "期限切れの見本", hours: -30, hasTime: false),
                reminder("soon", "明日が期限の見本", hours: 24),
                reminder("week", "来週が期限の見本", hours: 120),
            ]),
            reminderCount: 4)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--sample-load"), index + 2 < CommandLine.arguments.count,
       let memory = Double(CommandLine.arguments[index + 1]), let cpu = Double(CommandLine.arguments[index + 2]) {
        model.memory = MemorySnapshot(app: memory * 100, wired: 0, compressed: 0, total: 100, pressure: 1)
        model.cpu = cpu
    }
    if CommandLine.arguments.contains("--sample-editing") {
        model.isEditingLayout = true
    }
    if CommandLine.arguments.contains("--sample-layout") {
        var layout = WidgetLayout()
        layout.vertical = [.claude, .codex, .memory, .shortcuts, .events, .reminders, .mail, .media, .volumes, .network]
        layout.top = [.claude, .memory, .codex]
        layout.tiles = [.mail, .events, .reminders]
        layout.band = [.center, .network, .shortcuts]
        layout.weights = [PanelID.claude.rawValue: 1.6, PanelID.mail.rawValue: 0.7]
        layout.networkWidth = 230
        layout.rows = [PanelID.events.rawValue: 1, PanelID.network.rawValue: 5]
        model.layout = layout
    }
    if CommandLine.arguments.contains("--sample-network") {
        model.wifi = WiFiStatus(hasInterface: true, isOn: true, isConnected: true, rssi: -67, rate: 866, name: "Sample-Network-5G-とても長いネットワーク名の確認")
        let sample = #"""
        {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},"device_connected":[
          {"Sample Keyboard":{"device_batteryLevelMain":"85%"}},
          {"Sample AirPods":{"device_batteryLevelLeft":"18%","device_batteryLevelRight":"72%","device_batteryLevelCase":"40%"}},
          {"バッテリー値のない見本の長い名前のデバイスを表示したときの確認用":{}},
          {"Sample Mouse":{"device_batteryLevelMain":"50%"}}]}]}
        """#
        model.bluetooth = BluetoothReader.parse(Data(sample.utf8))
    }
    model.listensToAudio = false
    if let index = CommandLine.arguments.firstIndex(of: "--sample-visualizer") {
        let phase = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Float.init) ?? 0
        model.spectrum.preview((0..<AudioSpectrum.bandCount).map { band in
            let x = Float(band) / Float(AudioSpectrum.bandCount)
            let beat = 0.55 + 0.45 * sinf(phase * 1.7)
            let wobble = 0.22 * sinf(Float(band) * 1.3 + phase * 2.3) + 0.12 * sinf(Float(band) * 0.4 - phase * 3.1)
            return min(1, max(0.05, (0.95 - x * 0.75) * beat + wobble))
        })
    }
    if let index = CommandLine.arguments.firstIndex(of: "--sample-media"), index + 1 < CommandLine.arguments.count {
        let state = #"{"playing":true,"title":"mediaSessionの見本タイトル とても長い場合の表示を確認するための行","artist":"見本チャンネル"}"#
        let paused = #"{"playing":false,"title":"一時停止中のタブ（出ないはず）","artist":""}"#
        let tabs = "\(paused)\thttps://www.youtube.com/watch?v=a\tA - YouTube\n\thttps://music.youtube.com/\t再生なし（出ないはず）\n\(state)\thttps://www.youtube.com/watch?v=b\tB - YouTube\n"
        switch CommandLine.arguments[index + 1] {
        case "blocked":
            model.media = [
                MediaItem(source: .spotify, access: .automationDenied),
                MediaReader.parseBrowser("!js\thttps://www.youtube.com/watch?v=c\tタブ題名の見本 - YouTube\n"),
            ].compactMap { $0 }
        case let mode where mode.hasPrefix("https://"):
            // A site's address and tab title separated by "|", to see that site's buttons.
            let parts = mode.split(separator: "|", maxSplits: 1).map(String.init)
            let state = #"{"playing":true,"title":"","artist":""}"#
            model.media = [MediaReader.parseBrowser("\(state)\t\(parts[0])\t\(parts.count > 1 ? parts[1] : "")\n")].compactMap { $0 }
        case "stopped":
            model.media = [MediaReader.parseSpotify("stopped\n")]
        default:
            model.media = [
                MediaReader.parseSpotify("paused\n見本の曲\n見本のアーティスト\n"),
                MediaReader.parseBrowser(tabs),
            ].compactMap { $0 }
        }
    }
    if CommandLine.arguments.contains("--sample-volumes") {
        let first = URL(fileURLWithPath: "/Volumes/Sample SSD")
        model.volumes = [
            ExternalVolume(url: first, name: "Sample SSD", total: 2_000_000_000_000, available: 812_000_000_000),
            ExternalVolume(
                url: URL(fileURLWithPath: "/Volumes/Long"),
                name: "とても長い名前の外部ストレージを表示したときの確認用ボリューム",
                total: 64_000_000_000, available: 12_300_000_000),
        ]
        model.ejecting = [first]
        model.volumeError = "「Sample SSD」を取り外せません（使用中の可能性）"
    }
    if CommandLine.arguments.contains("--sample-pending") {
        model.pending = [
            PendingItem(id: 1, title: "見本セッション 名前が長い場合の表示を確認するための行", reason: "承認待ち", since: Date()),
            PendingItem(id: 2, title: "見本セッション 2", reason: "入力待ち", since: Date().addingTimeInterval(-300)),
            PendingItem(id: 3, title: "見本セッション 3", reason: "入力待ち", since: Date().addingTimeInterval(-7200)),
        ]
    }
    _ = NSApplication.shared
    let hosting = NSHostingView(rootView: WidgetView(model: model, solidBackground: true))
    hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("snapshot failed: no bitmap for \(hosting.bounds.size)")
        exit(1)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]),
          FileManager.default.createFile(atPath: path, contents: png)
    else {
        print("snapshot failed: could not write png")
        exit(1)
    }
    print("snapshot \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) memory=\(Int(model.memory.fraction * 100))% gpu=\(model.gpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "nil")")
}

enum AppInfo {
    /// From Info.plist, which build.sh writes; the fallback covers runs outside the app bundle.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
    }
}

/// The app used to be called UsageWidget. On the first start under the new name, its settings
/// and Claude cache come along, so nothing has to be set up again.
enum RenameMigration {
    private static let oldDomain = "local.usagewidget"
    private static let doneKey = "MigratedFromUsageWidget"

    static func run() {
        // Only the app itself; the promo renderer and other builds keep their own settings.
        guard Bundle.main.bundleIdentifier == "local.aquadesk" else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        if let old = defaults.persistentDomain(forName: oldDomain) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                switch key {
                // Left out so the renamed app adds itself as a login item on its first start.
                case "LoginItemOffered": continue
                case "NSWindow Frame UsageWidgetFrame": defaults.set(value, forKey: "NSWindow Frame AquadeskFrame")
                default: defaults.set(value, forKey: key)
                }
            }
        }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let oldFolder = support.appendingPathComponent("UsageWidget")
        let newFolder = support.appendingPathComponent("Aquadesk")
        if FileManager.default.fileExists(atPath: oldFolder.path), !FileManager.default.fileExists(atPath: newFolder.path) {
            try? FileManager.default.moveItem(at: oldFolder, to: newFolder)
        }
    }
}

@main
enum AquadeskApp {
    @MainActor
    static func main() {
        RenameMigration.run()
        let arguments = CommandLine.arguments
        #if DEMO
        if let index = arguments.firstIndex(of: "--demo"), index + 1 < arguments.count {
            runDemo(output: arguments[index + 1], stillOnly: arguments.contains("--still"))
            return
        }
        #endif
        if let index = arguments.firstIndex(of: "--snapshot-launcher"), index + 1 < arguments.count {
            renderLauncherSnapshot(to: arguments[index + 1])
            return
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            var sample: String?
            if let sampleIndex = arguments.firstIndex(of: "--sample-claude"), sampleIndex + 1 < arguments.count {
                sample = arguments[sampleIndex + 1]
            }
            renderSnapshot(to: arguments[index + 1], sampleClaude: sample)
            return
        }
        if arguments.contains("--list-network") {
            let wifi = WiFiReader.read()
            print("wifi on=\(wifi.isOn) connected=\(wifi.isConnected) rssi=\(wifi.rssi) rate=\(wifi.rate) hasName=\(wifi.name != nil)")
            let bluetooth = BluetoothReader.read()
            print("bluetooth on=\(String(describing: bluetooth.isOn)) devices=\(bluetooth.devices.count) withBattery=\(bluetooth.devices.filter { $0.battery != nil }.count)")
            return
        }
        if arguments.contains("--list-disk") {
            var iterator: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
                while case let service = IOIteratorNext(iterator), service != 0 {
                    let statistics = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                    print("\(DiskMeter.parentClass(of: service) ?? "?") read=\(statistics?["Bytes (Read)"] ?? "-") write=\(statistics?["Bytes (Write)"] ?? "-")")
                    IOObjectRelease(service)
                }
                IOObjectRelease(iterator)
            }
            print("total \(String(describing: DiskMeter.read()))")
            return
        }
        if let index = arguments.firstIndex(of: "--spectrum-test"), index + 1 < arguments.count,
           let seconds = Int(arguments[index + 1]) {
            // Prints counts and peak levels only, never audio.
            let spectrum = AudioSpectrum()
            spectrum.setRunning(true)
            for second in 0..<seconds {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let levels = spectrum.current()
                print("t=\(second + 1) stage=\(spectrum.stage) callbacks=\(spectrum.callbacks) peakSample=\(spectrum.loudestSample) maxBand=\(levels.max() ?? 0)")
            }
            spectrum.setRunning(false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            return
        }
        if arguments.contains("--list-media") {
            // Never prints what is playing, only whether each read worked.
            for item in [MediaReader.readSpotify(previous: nil), MediaReader.readBrowser(previous: nil)] {
                if let item {
                    print("\(item.label) access=\(item.access) playing=\(item.isPlaying) hasTitle=\(!item.title.isEmpty) hasArtist=\(!item.artist.isEmpty)")
                } else {
                    print("(no item)")
                }
            }
            return
        }
        if arguments.contains("--list-volumes") {
            for volume in VolumeReader.read() {
                print("\(volume.name) | \(volume.url.path) | \(Format.capacity(volume) ?? "-")")
            }
            return
        }
        if arguments.contains("--codex-query") {
            switch CodexLiveReader.fetch() {
            case .success(let usage):
                for window in usage.windows {
                    print("\(window.label) used=\(window.usedPercent ?? -1) resets=\(window.resetsAt.map(String.init(describing:)) ?? "-")")
                }
            case .failure(let error):
                print("failed: \(error.message)")
            }
            return
        }
        if let index = arguments.firstIndex(of: "--monitor-test"), index + 1 < arguments.count,
           let seconds = Int(arguments[index + 1]) {
            let monitor = ActivityMonitor()
            monitor.start()
            for second in 0..<seconds {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let states = monitor.states()
                print("t=\(second + 1) codex=\(states.codex) claude=\(states.claude)")
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
