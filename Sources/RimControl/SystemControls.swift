import AppKit
import CoreAudio
import ServiceManagement

/// A device that sound can be sent to. `uid` survives reconnects and restarts, and `id` does not.
struct AudioOutput: Identifiable, Equatable {
    let id: UInt32
    let uid: String
    let name: String
    let symbol: String
}

/// System output volume and output devices through CoreAudio.
final class VolumeController {
    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` ('vmvc'). Devices without one
    /// fall back to their main element, then to the two stereo channels.
    static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663
    private var virtualMainVolume: AudioObjectPropertySelector { Self.virtualMainVolume }

    private func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func readUInt32(_ device: AudioObjectID, _ target: AudioObjectPropertyAddress) -> UInt32? {
        var target = target
        guard AudioObjectHasProperty(device, &target) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func readString(_ device: AudioObjectID, _ target: AudioObjectPropertyAddress) -> String? {
        var target = target
        guard AudioObjectHasProperty(device, &target) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// The devices macOS itself would offer as an output, without the hidden ones apps create.
    func outputs() -> [AudioOutput] {
        var target = systemAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &target, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &target, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap(describe)
    }

    private func describe(_ device: AudioObjectID) -> AudioOutput? {
        var streams = address(kAudioDevicePropertyStreams)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
              readUInt32(device, address(kAudioDevicePropertyDeviceCanBeDefaultDevice)) == 1,
              readUInt32(device, systemAddress(kAudioDevicePropertyIsHidden)) != 1,
              let uid = readString(device, systemAddress(kAudioDevicePropertyDeviceUID)),
              let name = readString(device, systemAddress(kAudioObjectPropertyName))
        else { return nil }
        let transport = readUInt32(device, systemAddress(kAudioDevicePropertyTransportType)) ?? 0
        return AudioOutput(id: device, uid: uid, name: name, symbol: Self.symbol(transport: transport))
    }

    private static func symbol(transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "cable.connector"
        default: return "hifispeaker.fill"
        }
    }

    @discardableResult
    func setOutput(_ device: AudioObjectID) -> Bool {
        var target = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &target, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &device) == noErr
    }

    func outputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func address(
        _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func read(_ device: AudioObjectID, _ target: AudioObjectPropertyAddress) -> Float32? {
        var target = target
        guard AudioObjectHasProperty(device, &target) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func isSettable(_ device: AudioObjectID, _ target: AudioObjectPropertyAddress) -> Bool {
        var target = target
        guard AudioObjectHasProperty(device, &target) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &target, &settable) == noErr && settable.boolValue
    }

    /// Whether the current output's volume can be changed. Some can be read but not set.
    func isAdjustable() -> Bool {
        guard let device = outputDevice() else { return false }
        return isSettable(device, address(virtualMainVolume))
            || isSettable(device, address(kAudioDevicePropertyVolumeScalar))
            || isSettable(device, address(kAudioDevicePropertyVolumeScalar, element: 1))
            || isSettable(device, address(kAudioDevicePropertyVolumeScalar, element: 2))
    }

    func canMute() -> Bool {
        guard let device = outputDevice() else { return false }
        return isSettable(device, address(kAudioDevicePropertyMute))
    }

    private func write(_ device: AudioObjectID, _ target: AudioObjectPropertyAddress, _ value: Float32) -> Bool {
        var target = target
        guard isSettable(device, target) else { return false }
        var value = value
        return AudioObjectSetPropertyData(
            device, &target, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    /// Current volume from 0 to 1, or nil when the output has no adjustable volume, as with HDMI.
    func volume() -> Double? {
        guard let device = outputDevice() else { return nil }
        if let value = read(device, address(virtualMainVolume)) { return Double(value) }
        if let value = read(device, address(kAudioDevicePropertyVolumeScalar)) { return Double(value) }
        let channels = [1, 2].compactMap { read(device, address(kAudioDevicePropertyVolumeScalar, element: $0)) }
        return channels.isEmpty ? nil : Double(channels.reduce(0, +)) / Double(channels.count)
    }

    func setVolume(_ newValue: Double) {
        guard let device = outputDevice() else { return }
        let value = Float32(min(max(newValue, 0), 1))
        if write(device, address(virtualMainVolume), value) { return }
        if write(device, address(kAudioDevicePropertyVolumeScalar), value) { return }
        for channel: AudioObjectPropertyElement in [1, 2] {
            _ = write(device, address(kAudioDevicePropertyVolumeScalar, element: channel), value)
        }
    }

    func isMuted() -> Bool {
        guard let device = outputDevice() else { return false }
        var target = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &target) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    func setMuted(_ muted: Bool) {
        guard let device = outputDevice() else { return }
        var target = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &target) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &target, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// Reports volume changes from any source, and changes to the output devices.
final class OutputWatcher {
    var onVolumeChanged: (() -> Void)?
    var onOutputsChanged: (() -> Void)?

    private var watchedDevice: AudioObjectID?
    private var watchedAddresses: [AudioObjectPropertyAddress] = []

    private lazy var volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.onVolumeChanged?()
    }
    private lazy var outputsBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.onOutputsChanged?()
    }

    func start() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var target = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &target, DispatchQueue.main, outputsBlock)
        }
    }

    /// Moves the volume listeners to `device`. Harmless to call when it has not changed.
    func watch(_ device: AudioObjectID?) {
        guard device != watchedDevice else { return }
        if let old = watchedDevice {
            for var target in watchedAddresses {
                AudioObjectRemovePropertyListenerBlock(old, &target, DispatchQueue.main, volumeBlock)
            }
        }
        watchedDevice = device
        watchedAddresses = []
        guard let device else { return }

        let candidates: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (VolumeController.virtualMainVolume, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyVolumeScalar, 2),
        ]
        for (selector, element) in candidates {
            var target = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(device, &target),
                  AudioObjectAddPropertyListenerBlock(device, &target, DispatchQueue.main, volumeBlock) == noErr
            else { continue }
            watchedAddresses.append(target)
        }
    }
}

/// Built-in display brightness through the private DisplayServices framework.
final class BrightnessController {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32

    private let getter: Getter?
    private let setter: Setter?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let handle = dlopen(path, RTLD_LAZY)
        getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Getter.self) }
        setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Setter.self) }
    }

    /// The built-in panel when there is one. External monitors usually refuse these calls.
    var displayID: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(16, &ids, &count) == .success,
           let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            return builtIn
        }
        return CGMainDisplayID()
    }

    func brightness() -> Double? {
        guard let getter else { return nil }
        var value: Float = 0
        return getter(displayID, &value) == 0 ? Double(value) : nil
    }

    func setBrightness(_ value: Double) {
        _ = setter?(displayID, Float(min(max(value, 0), 1)))
    }
}

/// Sends the same system-defined events as the keyboard's media keys.
enum MediaKeys {
    private static let play = 16, next = 17, previous = 18

    static func send(_ command: MediaCommandKey) {
        let key: Int
        switch command {
        case .next: key = next
        case .previous: key = previous
        case .playPause: key = play
        }
        post(key: key, down: true)
        post(key: key, down: false)
    }

    private static func post(key: Int, down: Bool) {
        let state = down ? 0xA : 0xB
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (key << 16) | (state << 8),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

enum MediaCommandKey { case next, previous, playPause }

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[RimControl] Launch at login error: \(error)")
        }
    }
}
