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

    static func of(pid: pid_t) -> AppInfo {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        let running = NSRunningApplication(processIdentifier: pid)
        // Helpers (e.g. "Google Chrome Helper") belong to the app whose bundle contains them
        let outer = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
        let bundle = outer.flatMap { Bundle(path: $0) }
        let name = bundle.flatMap { ($0.infoDictionary?["CFBundleDisplayName"] ?? $0.infoDictionary?["CFBundleName"]) as? String }
            ?? running?.localizedName ?? (path as NSString).lastPathComponent
        let system = path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/")
        let regular = NSWorkspace.shared.runningApplications.contains {
            $0.activationPolicy == .regular && ($0.bundleURL?.path == outer || $0.processIdentifier == pid)
        }
        return AppInfo(name: system ? friendlySystemName(path, fallback: name) : name,
                       bundleID: bundle?.bundleIdentifier ?? running?.bundleIdentifier,
                       path: outer ?? path, system: system, background: !regular)
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
        return Array(Set(pids)).filter { $0 != getpid() }
    }

    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static var frontmost: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

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
