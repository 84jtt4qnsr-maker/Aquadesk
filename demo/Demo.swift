// Renders the 36-second promo video from the real widget views, filled with made-up sample data.
// Built only by demo/make_demo.sh (with -D DEMO); the installed app does not contain it.
import AppKit
import SwiftUI

// MARK: - Sample data

@MainActor
enum DemoData {
    static func model() -> WidgetModel {
        let model = WidgetModel()
        model.listensToAudio = false
        let now = Date()
        let gib = 1_073_741_824.0
        model.now = now
        model.memory = MemorySnapshot(app: 14.2 * gib, wired: 3.4 * gib, compressed: 1.1 * gib, total: 32 * gib, pressure: 1)
        model.cpu = 0.18
        model.gpu = 0.24
        model.disk = DiskTotals(read: 48_300_000_000, written: 21_700_000_000)
        model.codex = ProviderUsage(
            windows: [
                LimitWindow(id: "five", label: "5時間", usedPercent: 38, resetsAt: now.addingTimeInterval(2.4 * 3600)),
                LimitWindow(id: "seven", label: "週間", usedPercent: 22, resetsAt: now.addingTimeInterval(4 * 86400)),
            ],
            updatedAt: now.addingTimeInterval(-40))
        model.claude = ProviderUsage(
            windows: [
                LimitWindow(id: "five", label: "5時間", usedPercent: 54, resetsAt: now.addingTimeInterval(1.6 * 3600)),
                LimitWindow(id: "seven", label: "週間", usedPercent: 31, resetsAt: now.addingTimeInterval(3 * 86400)),
            ],
            updatedAt: now.addingTimeInterval(-90))
        model.codexActivity = ActivityState(isActive: true, tokensPerMinute: 12_400)
        model.claudeActivity = ActivityState(isActive: true, tokensPerMinute: 0)
        model.pending = [PendingItem(id: 1, title: "website — デザイン調整", reason: "承認待ち", since: now)]
        model.mail = MailReader.parse("3")

        let blue = Color(red: 0.3, green: 0.6, blue: 1), green = Color(red: 0.3, green: 0.8, blue: 0.5)
        func event(_ id: String, _ title: String, hours: Double) -> AgendaEvent {
            let start = now.addingTimeInterval(hours * 3600)
            return AgendaEvent(id: id, title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: false, color: blue)
        }
        func reminder(_ id: String, _ title: String, hours: Double) -> AgendaReminder {
            AgendaReminder(id: id, title: title, due: now.addingTimeInterval(hours * 3600), hasTime: true, color: green)
        }
        model.agenda = AgendaSnapshot(
            eventAccess: .granted,
            events: AgendaReader.arrange([
                event("a", "デザインレビュー", hours: 1.2),
                event("b", "チーム定例", hours: 25),
            ], now: now),
            reminderAccess: .granted,
            reminders: AgendaReader.arrange([
                reminder("a", "請求書を送る", hours: 5),
                reminder("b", "README を更新する", hours: 30),
            ]),
            reminderCount: 2)

        model.media = [MediaReader.parseSpotify("playing\nMidnight Drive\nSample Beats\n")]
        model.wifi = WiFiStatus(hasInterface: true, isOn: true, isConnected: true, rssi: -52, rate: 1201, name: "Home-5G")
        let bluetooth = #"""
        {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},"device_connected":[
          {"Magic Keyboard":{"device_batteryLevelMain":"82%"}},
          {"AirPods Pro":{"device_batteryLevelLeft":"76%","device_batteryLevelRight":"74%","device_batteryLevelCase":"60%"}},
          {"Trackball":{"device_batteryLevelMain":"64%"}}]}]}
        """#
        model.bluetooth = BluetoothReader.parse(Data(bluetooth.utf8))
        model.volumes = [ExternalVolume(
            url: URL(fileURLWithPath: "/Volumes/Backup SSD"), name: "Backup SSD",
            total: 2_000_000_000_000, available: 1_240_000_000_000)]
        fillShortcuts(model.shortcuts)
        // The default arrangement, whatever this machine has saved.
        model.layout = WidgetLayout()
        model.horizontalWidth = 1000
        return model
    }

    /// Never saved, so the user's own tiles stay as they are.
    static func fillShortcuts(_ store: ShortcutStore) {
        store.persists = false
        for index in 0..<ShortcutStore.slotCount { store.remove(index) }
        let apps = ["/System/Cryptexes/App/System/Applications/Safari.app", "/System/Applications/Mail.app",
                    "/System/Applications/Calendar.app", "/System/Applications/Notes.app"]
        for (index, path) in apps.enumerated() { store.assign(URL(fileURLWithPath: path), to: index) }

        store.createLauncher(at: 4, name: "仕事")
        store.addItems([
            "/System/Applications/Utilities/Terminal.app", "/System/Applications/Reminders.app",
            "/System/Applications/Preview.app", "/System/Applications/Music.app",
        ].map { URL(fileURLWithPath: $0) }, to: [4])
        store.addLauncher(named: "制作", to: [4])
        store.addItems([
            "/System/Applications/Photos.app", "/System/Applications/Freeform.app",
        ].map { URL(fileURLWithPath: $0) }, to: [4, 4])
        store.add([
            Shortcut(bookmark: nil, path: "", name: "GitHub", link: "https://github.com"),
            Shortcut(bookmark: nil, path: "", workflow: "集中モード開始"),
            Shortcut(bookmark: nil, path: "", name: "朝の作業", group: [
                "/System/Applications/Mail.app", "/System/Applications/Calendar.app",
            ].compactMap { Shortcut.file(URL(fileURLWithPath: $0)) }),
        ], to: [4])

        store.createLauncher(at: 5, name: "ツール")
        store.addItems([
            "/System/Applications/Calculator.app", "/System/Applications/Utilities/Activity Monitor.app",
            "/System/Applications/System Settings.app", "/System/Applications/Utilities/Screenshot.app",
        ].map { URL(fileURLWithPath: $0) }, to: [5])
        store.put(Shortcut(bookmark: nil, path: "", name: "ドキュメント", link: "https://developer.apple.com/documentation/"), in: 6)
    }

    /// Bands for the visualizer at time t: a beat plus drifting ripples, louder in the bass.
    static func spectrum(at t: Double) -> [Float] {
        let phase = Float(t)
        let beat = 0.5 + 0.5 * powf(max(0, sinf(phase * 2 * .pi * 1.9)), 3)
        return (0..<AudioSpectrum.bandCount).map { band in
            let x = Float(band) / Float(AudioSpectrum.bandCount)
            let wobble = 0.2 * sinf(Float(band) * 0.9 + phase * 5.3) + 0.12 * sinf(Float(band) * 0.37 - phase * 7.1)
            return min(1, max(0.04, (0.92 - x * 0.7) * (0.45 + 0.55 * beat) + wobble))
        }
    }
}

// MARK: - Rendering

@MainActor
func renderView<V: View>(_ view: V, size: CGSize? = nil, scale: CGFloat) -> NSImage {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size ?? hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(hosting.bounds.width * scale), pixelsHigh: Int(hosting.bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = hosting.bounds.size
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = NSImage(size: hosting.bounds.size)
    image.addRepresentation(rep)
    return image
}

// MARK: - Timeline

struct Camera {
    var scale: CGFloat
    /// The widget's y (in its own points) shown at the canvas' vertical centre.
    var focus: CGFloat
}

func ease(_ x: Double) -> Double {
    let t = min(1, max(0, x))
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}

/// A spring-like overshoot for things that pop open.
func popIn(_ x: Double) -> Double {
    let t = min(1, max(0, x))
    return 1 - exp(-6 * t) * cos(9 * t)
}

struct Caption {
    var start: Double
    var end: Double
    var title: String
    var english: String
    var detail: String
    var detailEnglish: String
    var top: Bool = false
    var keys: [String] = []
}

let demoCaptions = [
    Caption(start: 3.4, end: 7.6, title: "デスクトップに置く\n小さな水槽",
            english: "A little aquarium on your desktop",
            detail: "水位はメモリ、泡はCPU。魚も泳いでいます",
            detailEnglish: "Water level is memory, bubbles are CPU. And yes, fish."),
    Caption(start: 7.9, end: 12.6, title: "AIの残りと\nMacの負荷を常にチェック",
            english: "Keep an eye on AI limits and your Mac",
            detail: "Codex・Claude の残量と消費トークン、承認待ち、CPU・GPU・メモリ・ディスク",
            detailEnglish: "Codex & Claude limits and token rate, pending sessions, CPU · GPU · memory · disk"),
    Caption(start: 12.9, end: 17.4, title: "音に合わせて動く\nビジュアライザー",
            english: "A visualizer that dances to your music",
            detail: "Spotify や YouTube など14サイトの再生をその場で操作",
            detailEnglish: "Control Spotify, YouTube and 12 more sites in place"),
    Caption(start: 17.7, end: 22.2, title: "入れ子にできる\n円形ランチャー",
            english: "Nested radial launchers",
            detail: "アプリ・URL・ショートカット・まとめて起動",
            detailEnglish: "Apps, links, Shortcuts, and sets that open together", top: true),
    Caption(start: 22.4, end: 25.8, title: "カーソルの位置に\nリングを呼び出す",
            english: "Summon the ring right at your cursor",
            detail: "押したまま、はじいて起動",
            detailEnglish: "Hold, flick, launch.", top: true, keys: ["⌃", "⌥", "Space"]),
    Caption(start: 26.6, end: 31.5, title: "縦長の画面には横向き。\nパネルは自由に並べ替え",
            english: "Goes wide for portrait screens. Arrange it your way.",
            detail: "ドラッグで並び替え、つまみで幅を調整",
            detailEnglish: "Drag to reorder, pull the handles to resize", top: true),
]

// MARK: - Water

enum Water {
    static let skyTop = Color(red: 0.62, green: 0.93, blue: 1.0)
    static let mid = Color(red: 0.22, green: 0.66, blue: 0.98)
    static let deep = Color(red: 0.13, green: 0.33, blue: 0.86)
    static let flood = Color(red: 0.09, green: 0.36, blue: 0.92)
    static let floodDeep = Color(red: 0.06, green: 0.18, blue: 0.62)
    static let navy = Color(red: 0.04, green: 0.12, blue: 0.36)
    static let sun = Color(red: 1.0, green: 0.86, blue: 0.32)
    static let coral = Color(red: 1.0, green: 0.48, blue: 0.5)
}

/// The region below a wavy line, from `level` down to the bottom edge.
func wavePath(width: CGFloat, height: CGFloat, level: CGFloat, amplitude: CGFloat, length: CGFloat, phase: Double) -> Path {
    Path { path in
        path.move(to: CGPoint(x: 0, y: height))
        var x: CGFloat = 0
        while x <= width + 8 {
            let y = level + amplitude * CGFloat(sin(Double(x / length) * 2 * .pi + phase))
                + amplitude * 0.35 * CGFloat(sin(Double(x / length) * 5.1 + phase * 1.7))
            path.addLine(to: CGPoint(x: x, y: y))
            x += 8
        }
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
    }
}

struct Bubble {
    var x: Double, size: Double, speed: Double, offset: Double, sway: Double

    /// The same bubbles every run, so renders match.
    static func field(count: Int, seed: UInt64) -> [Bubble] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        return (0..<count).map { _ in
            Bubble(x: next() * 1920, size: 6 + pow(next(), 2) * 34, speed: 60 + next() * 120,
                   offset: next() * 1300, sway: next() * 6)
        }
    }
}

let backBubbles = Bubble.field(count: 46, seed: 7)
let floodBubbles = Bubble.field(count: 30, seed: 99)

struct BubbleLayer: View {
    var bubbles: [Bubble]
    var t: Double
    var opacity: Double = 1

    var body: some View {
        ZStack {
            ForEach(Array(bubbles.enumerated()), id: \.offset) { _, bubble in
                let travel = (bubble.offset + t * bubble.speed).truncatingRemainder(dividingBy: 1300)
                let y = 1140 - travel
                let x = bubble.x + 18 * sin(t * 1.3 + bubble.sway)
                ZStack {
                    Circle().fill(.white.opacity(0.1))
                    Circle().stroke(.white.opacity(0.7), lineWidth: max(1.2, bubble.size / 14))
                    Circle().fill(.white.opacity(0.85))
                        .frame(width: bubble.size * 0.28, height: bubble.size * 0.28)
                        .offset(x: -bubble.size * 0.2, y: -bubble.size * 0.2)
                }
                .frame(width: bubble.size, height: bubble.size)
                .position(x: x, y: y)
            }
        }
        .frame(width: 1920, height: 1080)
        .opacity(opacity)
    }
}

// MARK: - Frame view

struct Ripple {
    var center: CGPoint
    var age: Double
}

struct DemoFrame: View {
    var t: Double
    var widget: NSImage
    var camera: Camera
    var tileRing: (image: NSImage, center: CGPoint, amount: Double)?
    var rootRing: (image: NSImage, center: CGPoint, amount: Double)?
    var cursor: (point: CGPoint, pressed: Bool)?
    var ripples: [Ripple]
    var widgetX: CGFloat
    var widgetRise: Double
    var dim: Double
    var icon: NSImage

    static let size = CGSize(width: 1920, height: 1080)

    /// Where the flood's surface is: above the top while it covers everything, below the bottom when gone.
    private var floodLevel: CGFloat? {
        if t < 2.7 { return -60 }
        if t < 3.6 { return -60 + 1250 * CGFloat(ease((t - 2.7) / 0.9)) }
        if t > 31.9 { return 1190 - 1250 * CGFloat(ease((t - 31.9) / 0.9)) }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            Image(nsImage: widget)
                .resizable()
                .frame(width: widget.size.width * camera.scale, height: widget.size.height * camera.scale)
                .clipShape(RoundedRectangle(cornerRadius: 16 * camera.scale, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16 * camera.scale, style: .continuous)
                        .stroke(.white.opacity(0.55), lineWidth: 3))
                .position(
                    x: widgetX,
                    y: Self.size.height / 2 + (widget.size.height / 2 - camera.focus) * camera.scale
                        + (1 - widgetRise) * 1100 + 5 * sin(t * 1.7))
            Water.navy.opacity(dim * 0.5)
            if let tileRing { ring(tileRing) }
            if let rootRing { ring(rootRing) }
            ForEach(Array(ripples.enumerated()), id: \.offset) { _, ripple in rippleView(ripple) }
            ForEach(Array(demoCaptions.enumerated()), id: \.offset) { _, caption in
                captionView(caption)
            }
            if let level = floodLevel { flood(level) }
            intro
            outro
            if let cursor { cursorView(cursor.point, pressed: cursor.pressed) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Water.skyTop, Water.mid, Water.deep], startPoint: .top, endPoint: .bottom)
            // Light shafts from the surface.
            ForEach(0..<6, id: \.self) { index in
                let x = 160 + Double(index) * 330 + 50 * sin(t * 0.5 + Double(index))
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(width: 70 + CGFloat(index % 3) * 45, height: 1300)
                    .rotationEffect(.degrees(16 + 3 * sin(t * 0.7 + Double(index) * 2)))
                    .position(x: x, y: 520)
                    .opacity(0.6 + 0.4 * sin(t * 0.9 + Double(index) * 1.7))
            }
            BubbleLayer(bubbles: backBubbles, t: t)
            wavePath(width: 1920, height: 1080, level: 930, amplitude: 22, length: 760, phase: t * 1.4)
                .fill(.white.opacity(0.1))
            wavePath(width: 1920, height: 1080, level: 975, amplitude: 18, length: 540, phase: -t * 1.9 + 1)
                .fill(Water.deep.opacity(0.55))
            wavePath(width: 1920, height: 1080, level: 1015, amplitude: 14, length: 420, phase: t * 2.4 + 2)
                .fill(Water.floodDeep.opacity(0.6))
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func flood(_ level: CGFloat) -> some View {
        ZStack {
            wavePath(width: 1920, height: 2400, level: level - 30, amplitude: 26, length: 620, phase: t * 3)
                .fill(.white.opacity(0.35))
            wavePath(width: 1920, height: 2400, level: level, amplitude: 30, length: 800, phase: -t * 2.4)
                .fill(LinearGradient(colors: [Water.flood, Water.floodDeep], startPoint: .top, endPoint: .bottom))
            BubbleLayer(bubbles: floodBubbles, t: t, opacity: 0.8)
                .mask(wavePath(width: 1920, height: 1080, level: level + 40, amplitude: 30, length: 800, phase: -t * 2.4))
        }
        .frame(width: 1920, height: 1080, alignment: .topLeading)
        .clipped()
    }

    private func ring(_ ring: (image: NSImage, center: CGPoint, amount: Double)) -> some View {
        let grow = popIn(ring.amount)
        return Image(nsImage: ring.image)
            .resizable()
            .frame(width: ring.image.size.width * camera.scale, height: ring.image.size.height * camera.scale)
            .scaleEffect(0.15 + 0.85 * grow)
            .opacity(min(1, ring.amount * 3))
            .position(ring.center)
    }

    private func rippleView(_ ripple: Ripple) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let age = ripple.age - Double(index) * 0.12
                if age > 0 && age < 0.9 {
                    Circle()
                        .stroke(.white.opacity(0.9 * (1 - age / 0.9)), lineWidth: 5 * (1 - age / 0.9) + 1)
                        .frame(width: 30 + 260 * age, height: (30 + 260 * age) * 0.92)
                }
            }
        }
        .position(ripple.center)
    }

    private func fade(_ start: Double, _ end: Double) -> Double {
        min(ease((t - start) / 0.45), ease((end - t) / 0.35))
    }

    @ViewBuilder private func captionView(_ caption: Caption) -> some View {
        let amount = fade(caption.start, caption.end)
        if amount > 0 {
            VStack(alignment: .leading, spacing: 0) {
                Text(caption.title)
                    .font(.system(size: 58, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineSpacing(4)
                Text(caption.english)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Water.sun)
                    .padding(.top, 12)
                Capsule().fill(.white.opacity(0.35)).frame(width: 80, height: 5).padding(.vertical, 22)
                Text(caption.detail)
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(caption.detailEnglish)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 6)
                if !caption.keys.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(caption.keys, id: \.self) { key in
                            Text(key)
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Water.navy)
                                .padding(.horizontal, 20).frame(height: 58)
                                .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                                .background(RoundedRectangle(cornerRadius: 14).fill(Water.navy.opacity(0.35)).offset(y: 5))
                        }
                    }
                    .padding(.top, 22)
                }
            }
            .padding(.horizontal, 46).padding(.vertical, 40)
            .frame(width: 860, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(Water.navy.opacity(0.42)))
            .overlay(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .stroke(.white.opacity(0.45), lineWidth: 3))
            .position(x: 90 + 430, y: caption.top ? 250 : 540)
            .scaleEffect(0.9 + 0.1 * popIn(amount), anchor: .leading)
            .offset(y: (1 - amount) * 40)
            .opacity(amount)
        }
    }

    @ViewBuilder private var intro: some View {
        let amount = min(ease(t / 0.5), ease((3.0 - t) / 0.4))
        if amount > 0 {
            VStack(spacing: 22) {
                Image(nsImage: icon).resizable().frame(width: 230, height: 230)
                    .scaleEffect(0.6 + 0.4 * popIn(t / 1.0))
                    .offset(y: 10 * sin(t * 2.6))
                Text("Aquadesk")
                    .font(.system(size: 104, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("Macのデスクトップに、いま知りたいことをひとまとめに")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("Everything you want to know, right on your Mac's desktop")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Water.sun)
            }
            .position(x: Self.size.width / 2, y: Self.size.height / 2)
            .opacity(amount)
        }
    }

    @ViewBuilder private var outro: some View {
        let amount = ease((t - 32.5) / 0.6)
        if amount > 0 {
            VStack(spacing: 26) {
                Image(nsImage: icon).resizable().frame(width: 170, height: 170)
                    .scaleEffect(0.6 + 0.4 * popIn((t - 32.5) / 1.0))
                    .offset(y: 8 * sin(t * 2.6))
                Text("Aquadesk")
                    .font(.system(size: 92, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                HStack(spacing: 16) {
                    Text("git clone")
                    Image(systemName: "arrow.right")
                    Text("zsh install.sh")
                }
                .font(.system(size: 38, weight: .bold, design: .monospaced))
                .foregroundStyle(Water.navy)
                .padding(.horizontal, 40).padding(.vertical, 20)
                .background(Capsule().fill(.white))
                .background(Capsule().fill(Water.navy.opacity(0.4)).offset(y: 7))
                Text("インストールはこれだけ  ·  That's all it takes to install")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Water.sun)
                Text("v1.0  ·  macOS 14.2+  ·  MIT License")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .position(x: Self.size.width / 2, y: Self.size.height / 2 + (1 - amount) * 40)
            .opacity(amount)
        }
    }

    private func cursorView(_ point: CGPoint, pressed: Bool) -> some View {
        let arrow = Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 34))
            path.addLine(to: CGPoint(x: 8.5, y: 26))
            path.addLine(to: CGPoint(x: 14.5, y: 39))
            path.addLine(to: CGPoint(x: 20, y: 36.5))
            path.addLine(to: CGPoint(x: 14, y: 24))
            path.addLine(to: CGPoint(x: 25, y: 24))
            path.closeSubpath()
        }
        return ZStack(alignment: .topLeading) {
            arrow.fill(.black)
            arrow.stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
        }
        .frame(width: 26, height: 40, alignment: .topLeading)
        .scaleEffect(pressed ? 0.85 : 1, anchor: .topLeading)
        .position(x: point.x + 13, y: point.y + 20)
    }
}


// MARK: - Driver

@MainActor
func runDemo(output: String, stillOnly: Bool) {
    _ = NSApplication.shared
    let model = DemoData.model()
    let scale: CGFloat = 2
    let clockStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // 26.4 s on, the widget comes back up in its wide layout.
    let wideFrom = 26.4
    let editFrom = 27.0, editUntil = 30.9

    /// The wide layout's top row at time t: Claude is dragged to the front, then widened.
    func wideLayout(at t: Double) -> WidgetLayout {
        var layout = WidgetLayout()
        if t >= 28.9 { layout.move(.claude, onto: .memory, horizontal: true) }
        if t >= 29.7 {
            let start = layout
            layout.resize(.claude, .memory, by: 120 * CGFloat(ease((t - 29.7) / 0.7)), from: start,
                          total: model.wideInner, shortcuts: model.shortcutsWidth)
        }
        return layout
    }

    func widgetImage(at t: Double) -> NSImage {
        model.spectrum.preview(DemoData.spectrum(at: t))
        let step = Int(t * 2)  // load readings change twice a second
        model.cpu = 0.16 + 0.1 * abs(sin(Double(step) * 1.7))
        model.gpu = 0.2 + 0.12 * abs(cos(Double(step) * 1.3))
        model.memory.app = (14.2 + 0.3 * sin(Double(step) * 0.6)) * 1_073_741_824
        model.aquariumClock = clockStart.addingTimeInterval(t)
        model.isHorizontal = t >= wideFrom
        model.isEditingLayout = t >= editFrom && t < editUntil
        model.layout = model.isHorizontal ? wideLayout(at: t) : WidgetLayout()
        return renderView(WidgetView(model: model, solidBackground: true), scale: scale)
    }

    let still = widgetImage(at: 0)
    if stillOnly {
        for (name, t) in [("", 0.0), ("-wide", 28.5), ("-resize", 30.2)] {
            let image = widgetImage(at: t)
            let rep = image.representations.first as! NSBitmapImageRep
            let path = name.isEmpty ? output : output.replacingOccurrences(of: ".png", with: "\(name).png")
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            print("widget\(name) \(image.size.width)x\(image.size.height)")
        }
        return
    }

    // Widget points measured from the still: where things are in the widget's own coordinates.
    let env = ProcessInfo.processInfo.environment
    func value(_ key: String, _ fallback: CGFloat) -> CGFloat { env[key].flatMap(Double.init).map { CGFloat($0) } ?? fallback }
    let size = still.size
    let mediaY = value("DEMO_MEDIA_Y", 600)
    let tilesY = value("DEMO_TILES_Y", size.height - 80)
    let tile = CGPoint(x: value("DEMO_TILE_X", 50), y: value("DEMO_TILE_Y", size.height - 40))
    let doneX = value("DEMO_DONE_X", 640), doneY = value("DEMO_DONE_Y", 17)

    let fit = min(1.0, (DemoFrame.size.height - 70) / size.height)
    let keys: [(Double, Camera)] = [
        (0, Camera(scale: fit, focus: size.height / 2)),
        (7.8, Camera(scale: fit, focus: size.height / 2)),
        (8.8, Camera(scale: 1.75, focus: 290)),
        (12.4, Camera(scale: 1.75, focus: 290)),
        (13.3, Camera(scale: 1.9, focus: mediaY)),
        (17.2, Camera(scale: 1.9, focus: mediaY)),
        (18.1, Camera(scale: 1.6, focus: tilesY)),
        (26.0, Camera(scale: 1.6, focus: tilesY)),
    ]
    // The wide widget sits below the caption, centred across the frame.
    let wideScale: CGFloat = 1.5
    let wideCamera = Camera(scale: wideScale, focus: 273 / 2 - 190 / wideScale)
    func camera(_ t: Double) -> Camera {
        if t >= wideFrom { return wideCamera }
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.0 {
            let k = CGFloat(ease((t - a.0) / (b.0 - a.0)))
            return Camera(scale: a.1.scale + (b.1.scale - a.1.scale) * k, focus: a.1.focus + (b.1.focus - a.1.focus) * k)
        }
        return keys.last!.1
    }
    func widgetX(_ t: Double) -> CGFloat { t >= wideFrom ? 960 : 1390 }

    func toCanvas(_ p: CGPoint, _ cam: Camera, size: CGSize, x: CGFloat) -> CGPoint {
        CGPoint(x: x + (p.x - size.width / 2) * cam.scale,
                y: DemoFrame.size.height / 2 + (p.y - cam.focus) * cam.scale)
    }

    /// The centre of a top-row card, and the border after the first one, in widget points.
    func topCenter(_ id: PanelID, _ layout: WidgetLayout, editing: Bool) -> CGPoint {
        let widths = layout.widths(layout.top, inner: model.wideInner, spacing: WidgetLayout.topSpacing)
        var x: CGFloat = 16
        for (panel, width) in zip(layout.top, widths) {
            if panel == id { return CGPoint(x: x + width / 2, y: 16 + (editing ? 22 : 0) + 44) }
            x += width + WidgetLayout.topSpacing
        }
        return .zero
    }
    func firstBorder(_ layout: WidgetLayout) -> CGPoint {
        let widths = layout.widths(layout.top, inner: model.wideInner, spacing: WidgetLayout.topSpacing)
        return CGPoint(x: 16 + widths[0] + WidgetLayout.topSpacing / 2, y: 16 + 22 + 44)
    }
    func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    // Rings, drawn once per highlighted item.
    let store = model.shortcuts
    var ringCache: [String: NSImage] = [:]
    func ringImage(path: [Int], hovered: Int?) -> NSImage {
        let key = "\(path)-\(hovered ?? -9)"
        if let image = ringCache[key] { return image }
        let state = LauncherState(path: path, origin: .zero)
        state.expanded = true
        state.hovered = hovered
        let image = renderView(
            LauncherRingView(store: store, state: state, solidBackground: false),
            size: CGSize(width: LauncherLayout.side, height: LauncherLayout.side), scale: scale)
        ringCache[key] = image
        return image
    }
    let rootCount = store.filledSlots.count
    let tileItems = store.item(at: [4])?.items?.count ?? 0

    let iconURL = URL(fileURLWithPath: CommandLine.arguments.first!)
        .deletingLastPathComponent().appendingPathComponent("../../../AppIcon.icns").standardized
    let icon = NSImage(contentsOf: iconURL) ?? NSApp.applicationIconImage!

    // ffmpeg reads raw frames on stdin.
    let fps = 30.0, duration = 36.0
    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba",
                        "-s", "1920x1080", "-r", "30", "-i", "-",
                        "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p",
                        "-movflags", "+faststart", output]
    let pipe = Pipe()
    ffmpeg.standardInput = pipe
    try! ffmpeg.run()

    let frames = Int(fps * duration)
    for frame in 0..<frames { autoreleasepool {
        // Each frame's hosting views go at the end of the pool, or SwiftUI's graph runs out of room.
        let t = Double(frame) / fps
        let cam = camera(t)
        let x = widgetX(t)

        // The drag in edit mode, set before the widget is drawn so the dragged card shows.
        let drag = model.panelDrag
        drag.source = nil
        drag.target = nil
        if t >= 28.0 && t < 28.9 {
            let layout = wideLayout(at: t)
            let k = ease((t - 28.0) / 0.8)
            drag.source = .claude
            drag.location = mix(topCenter(.claude, layout, editing: true), topCenter(.memory, layout, editing: true), k)
            drag.target = k > 0.45 ? .memory : nil
        }
        let widget = widgetImage(at: t)
        let size = widget.size

        // The widget bobs up out of the water as the flood drains, and again in its wide form.
        let rise: Double
        if t < 3.0 { rise = 0 }
        else if t < 25.9 { rise = popIn((t - 3.0) / 1.2) }
        else if t < wideFrom { rise = 1 - ease((t - 25.9) / 0.5) }
        else { rise = popIn((t - wideFrom) / 1.0) }

        var tileRing: (image: NSImage, center: CGPoint, amount: Double)?
        var rootRing: (image: NSImage, center: CGPoint, amount: Double)?
        var cursor: (point: CGPoint, pressed: Bool)?
        var dim = 0.0
        let tileCenter = toCanvas(tile, cam, size: size, x: x)

        // 18.4–22.2: the cursor comes to the 仕事 tile, clicks, and runs over the ring's items.
        if t >= 18.4 && t < 22.3 {
            let start = CGPoint(x: 900, y: 980)
            let arrive = ease((t - 18.4) / 0.8)
            var point = CGPoint(x: start.x + (tileCenter.x - start.x) * arrive, y: start.y + (tileCenter.y - start.y) * arrive)
            let pressed = t > 19.2 && t < 19.4
            if t >= 19.3 {
                let open = (t - 19.3) / 0.55
                let close = t > 21.9 ? (t - 21.9) / 0.3 : 0
                let hoverTime = t - 19.9
                var hovered: Int?
                if hoverTime > 0 {
                    let index = min(tileItems - 1, Int(hoverTime / 0.32))
                    hovered = index
                    let target = LauncherLayout.offset(index, of: tileItems + 1, radius: LauncherLayout.radius(for: tileItems + 1))
                    let from = index == 0 ? CGSize.zero
                        : LauncherLayout.offset(index - 1, of: tileItems + 1, radius: LauncherLayout.radius(for: tileItems + 1))
                    let k = CGFloat(ease((hoverTime - Double(index) * 0.32) / 0.22))
                    point = CGPoint(
                        x: tileCenter.x + (from.width + (target.width - from.width) * k) * cam.scale,
                        y: tileCenter.y + (from.height + (target.height - from.height) * k) * cam.scale)
                }
                tileRing = (ringImage(path: [4], hovered: hovered), tileCenter, max(0, min(open, 1 - close)))
            }
            cursor = (point, pressed)
        }

        // 22.4–26.0: the hotkey ring opens at the cursor, a flick picks Safari, and it closes.
        if t >= 22.4 && t < 26.1 {
            let center = CGPoint(x: 600, y: 760)
            dim = min(ease((t - 22.6) / 0.3), ease((25.9 - t) / 0.3))
            var point = center
            var hovered: Int?
            let flick = ease((t - 24.0) / 0.25)
            if t >= 24.0 {
                hovered = 0
                let target = LauncherLayout.offset(0, of: rootCount, radius: LauncherLayout.radius(for: rootCount))
                point = CGPoint(x: center.x + target.width * 0.55 * cam.scale * CGFloat(flick),
                                y: center.y + target.height * 0.55 * cam.scale * CGFloat(flick))
            }
            if t >= 23.0 {
                let close = t > 25.2 ? (t - 25.2) / 0.3 : 0
                rootRing = (ringImage(path: [], hovered: hovered), center, max(0, min((t - 23.0) / 0.55, 1 - close)))
            }
            cursor = (point, t > 22.9 && t < 23.05)
        }

        // 27.3–31.3: in edit mode, Claude's card is dragged to the front and widened, then 完了.
        var wideClicks: [(Double, CGPoint)] = []
        if t >= 27.3 && t < 31.4 {
            let before = WidgetLayout()
            var after = WidgetLayout()
            after.move(.claude, onto: .memory, horizontal: true)
            let claudeAt = toCanvas(topCenter(.claude, before, editing: true), cam, size: size, x: x)
            let memoryAt = toCanvas(topCenter(.memory, before, editing: true), cam, size: size, x: x)
            let borderAt = toCanvas(firstBorder(wideLayout(at: t)), cam, size: size, x: x)
            let borderStart = toCanvas(firstBorder(after), cam, size: size, x: x)
            let doneAt = toCanvas(CGPoint(x: doneX, y: doneY), cam, size: size, x: x)
            var point: CGPoint
            var pressed = false
            switch t {
            case ..<27.9: point = mix(CGPoint(x: 960, y: 1080), claudeAt, ease((t - 27.3) / 0.6))
            case ..<28.0: point = claudeAt; pressed = true
            case ..<28.9: point = mix(claudeAt, memoryAt, ease((t - 28.0) / 0.8)); pressed = true
            case ..<29.6: point = mix(memoryAt, borderStart, ease((t - 29.0) / 0.5))
            case ..<30.4: point = borderAt; pressed = t >= 29.65
            case ..<30.8: point = mix(borderAt, doneAt, ease((t - 30.4) / 0.4))
            default: point = doneAt; pressed = t < 30.9
            }
            cursor = (point, pressed)
            wideClicks = [(27.95, claudeAt), (28.9, memoryAt), (30.85, doneAt)]
        }

        // Each click sends out a ripple.
        let rootTarget = LauncherLayout.offset(0, of: rootCount, radius: LauncherLayout.radius(for: rootCount))
        let clicks: [(Double, CGPoint)] = [
            (19.25, tileCenter),
            (22.95, CGPoint(x: 600, y: 760)),
            (24.25, CGPoint(x: 600 + rootTarget.width * cam.scale, y: 760 + rootTarget.height * cam.scale)),
        ] + wideClicks
        let ripples = clicks.compactMap { time, point in
            t >= time && t < time + 1.2 ? Ripple(center: point, age: t - time) : nil
        }

        let view = DemoFrame(
            t: t, widget: widget, camera: cam, tileRing: tileRing, rootRing: rootRing, cursor: cursor,
            ripples: ripples, widgetX: x, widgetRise: rise, dim: dim, icon: icon)
        let image = renderView(view, size: DemoFrame.size, scale: 1)
        let rep = image.representations.first as! NSBitmapImageRep
        let bytes = rep.bytesPerRow * rep.pixelsHigh
        if rep.bytesPerRow == 1920 * 4 {
            pipe.fileHandleForWriting.write(Data(bytes: rep.bitmapData!, count: bytes))
        } else {
            var data = Data(capacity: 1920 * 4 * 1080)
            for row in 0..<rep.pixelsHigh {
                data.append(rep.bitmapData! + row * rep.bytesPerRow, count: 1920 * 4)
            }
            pipe.fileHandleForWriting.write(data)
        }
        if frame % 90 == 0 { print("frame \(frame)/\(frames)") }
    } }
    try! pipe.fileHandleForWriting.close()
    ffmpeg.waitUntilExit()
    print("wrote \(output)")
}
