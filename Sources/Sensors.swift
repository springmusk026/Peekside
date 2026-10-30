// Reads what's using the microphone, camera and keyboard right now. Public APIs only:
//   microphone – CoreAudio process objects (macOS 14+): which processes are recording
//   camera     – CoreMediaIO: whether any camera is running. macOS doesn't say which app.
//   keyboard   – Quartz event taps that receive key events: apps that can read keystrokes
// Each read takes well under a millisecond, so Peekside polls once a second.

import AppKit
import CoreAudio
import CoreMediaIO

/// A process, described for people.
struct AppInfo: Codable, Hashable {
    let name: String
    let bundleID: String?
    let path: String
    /// Part of macOS (Siri, dictation, system services) rather than an app you installed.
    let system: Bool
    /// Runs without a window or Dock icon.
    let background: Bool

    /// Nil when the process has already exited.
    static func of(pid: pid_t) -> AppInfo? {
        Sensors.path(of: pid).map { of(pid: pid, path: $0) }
    }

    static func of(pid: pid_t, path raw: String) -> AppInfo {
        let path = visiblePath(raw)
        let running = NSRunningApplication(processIdentifier: pid)
        // Helpers (e.g. "Google Chrome Helper") belong to the app whose bundle contains them
        let outer = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
        let bundle = outer.flatMap { Bundle(path: $0) }
        let name = bundle.flatMap { ($0.infoDictionary?["CFBundleDisplayName"] ?? $0.infoDictionary?["CFBundleName"]) as? String }
            ?? running?.localizedName ?? (path as NSString).lastPathComponent
        let regular = isWebKit(path) || NSWorkspace.shared.runningApplications.contains {
            $0.activationPolicy == .regular && ($0.bundleURL.map { visiblePath($0.path) } == outer || $0.processIdentifier == pid)
        }
        return AppInfo(name: name, bundleID: bundle?.bundleIdentifier ?? running?.bundleIdentifier,
                       path: outer ?? path, system: false, background: !regular).classified(executable: path)
    }

    /// Sets `system` and a readable name from where the executable lives. Also used on saved
    /// history, so it can be corrected after Peekside gets better at telling the two apart.
    func classified(executable: String? = nil) -> AppInfo {
        let exe = executable ?? path
        // Web pages in Safari (and apps' web views) capture through WebKit's own processes
        if Self.isWebKit(exe) {
            return AppInfo(name: "Safari or a web view", bundleID: bundleID, path: path, system: false, background: false)
        }
        // Calls you placed yourself are carried by macOS daemons, but they're yours, not macOS's
        let file = (exe as NSString).lastPathComponent
        if Self.calls.contains(file) {
            return AppInfo(name: Self.friendlySystemName(exe, fallback: name), bundleID: bundleID, path: path,
                           system: false, background: false)
        }
        // Apple's apps (FaceTime, Voice Memos, Safari) live under /System too, but they're apps
        let app = path.hasSuffix(".app") && path.contains("/Applications/")
        let system = !app && (exe.hasPrefix("/System/") || exe.hasPrefix("/usr/") || exe.hasPrefix("/Library/Apple/"))
        return AppInfo(name: system ? Self.friendlySystemName(exe, fallback: name) : name, bundleID: bundleID,
                       path: path, system: system, background: background)
    }

    private static let calls: Set<String> = ["avconferenced", "callservicesd"]

    private static func isWebKit(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("com.apple.WebKit.")
    }

    /// Safari and other apps updated outside macOS run from a cryptex; show where people see them.
    static func visiblePath(_ path: String) -> String {
        for (hidden, shown) in [("/System/Volumes/Preboot/Cryptexes/App/System/Applications/", "/Applications/"),
                                ("/System/Volumes/Preboot/Cryptexes/OS/", "/")] where path.hasPrefix(hidden) {
            return shown + path.dropFirst(hidden.count)
        }
        return path
    }

    /// What a macOS process is for, when its name doesn't say.
    private static func friendlySystemName(_ path: String, fallback: String) -> String {
        let names = ["corespeechd": "Siri (listening for “Hey Siri”)", "historicalaudiod": "macOS audio history",
                     "SiriNCService": "Siri", "universalaccessd": "Accessibility", "ViewBridgeAuxiliary": "macOS text input",
                     "avconferenced": "FaceTime calls", "callservicesd": "Phone calls", "Dictation": "Dictation",
                     "VoiceOver": "VoiceOver", "assistantd": "Siri"]
        return names[(path as NSString).lastPathComponent] ?? fallback
    }
}

enum Sensors {
    /// Processes recording from any input device.
    static func microphone() -> [pid_t] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard read(object, kAudioProcessPropertyIsRunningInput, as: UInt32.self) == 1 else { return nil }
            return read(object, kAudioProcessPropertyPID, as: pid_t.self)
        }
    }

    /// Whether any camera is capturing.
    static func cameraOn() -> Bool {
        var address = cmio(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0, used: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }
        return devices.contains { device in
            var running: UInt32 = 0, got: UInt32 = 0
            var a = cmio(kCMIODevicePropertyDeviceIsRunningSomewhere)
            return CMIOObjectGetPropertyData(device, &a, 0, nil, 4, &got, &running) == 0 && running != 0
        }
    }

    /// Processes with an active event tap that receives key presses: they can read what you type.
    static func keyboardMonitors() -> [pid_t] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [] }
        let keys: UInt64 = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let pids = taps.filter { $0.enabled && $0.eventsOfInterest & keys != 0 }.map { pid_t($0.tappingProcess) }
        return Array(Set(pids)).filter { $0 > 0 && $0 != getpid() }
    }

    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static var frontmost: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// The executable's path, or nil once the process has exited.
    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr ? value.pointee : nil
    }

    private static func cmio(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
}
