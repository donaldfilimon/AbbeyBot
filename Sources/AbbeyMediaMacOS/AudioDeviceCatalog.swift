import CoreAudio
import Foundation

public struct AudioDeviceSnapshot: Equatable, Identifiable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let supportsInput: Bool
    public let supportsOutput: Bool
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        supportsInput: Bool,
        supportsOutput: Bool,
        isDefaultInput: Bool = false,
        isDefaultOutput: Bool = false
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.supportsInput = supportsInput
        self.supportsOutput = supportsOutput
        self.isDefaultInput = isDefaultInput
        self.isDefaultOutput = isDefaultOutput
    }
}

public protocol AudioDeviceProviding: Sendable {
    func deviceSnapshots() async -> [AudioDeviceSnapshot]
}

public actor AudioDeviceCatalog {
    private let provider: any AudioDeviceProviding
    private var devices: [AudioDeviceSnapshot] = []
    private var selectedInput: AudioDeviceSnapshot?
    private var selectedOutput: AudioDeviceSnapshot?

    public init(provider: any AudioDeviceProviding) {
        self.provider = provider
    }

    public init() {
        provider = CoreAudioDeviceProvider()
    }

    public func refresh() async -> [AudioDeviceSnapshot] {
        let refreshed = await provider.deviceSnapshots()
            .sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.uid < rhs.uid : order == .orderedAscending
            }
        devices = refreshed
        return refreshed
    }

    public func currentSnapshots() -> [AudioDeviceSnapshot] {
        devices
    }

    /// Selection is deliberately process-memory-only. Callers may persist an operator preference
    /// in a separate product layer, but this boundary never writes hardware identifiers.
    public func selectInput(uid: String?) throws -> AudioDeviceSnapshot? {
        guard let uid else {
            selectedInput = nil
            return nil
        }
        guard let device = devices.first(where: { $0.uid == uid && $0.supportsInput }) else {
            throw MediaRuntimeError.unsupportedInputDevice
        }
        selectedInput = device
        return device
    }

    public func selectOutput(uid: String?) throws -> AudioDeviceSnapshot? {
        guard let uid else {
            selectedOutput = nil
            return nil
        }
        guard let device = devices.first(where: { $0.uid == uid && $0.supportsOutput }) else {
            throw MediaRuntimeError.unsupportedOutputDevice
        }
        selectedOutput = device
        return device
    }

    public func selection() -> AudioDeviceSelection {
        AudioDeviceSelection(input: selectedInput, output: selectedOutput)
    }
}

public struct AudioDeviceSelection: Equatable, Sendable {
    public let input: AudioDeviceSnapshot?
    public let output: AudioDeviceSnapshot?

    public init(input: AudioDeviceSnapshot? = nil, output: AudioDeviceSnapshot? = nil) {
        self.input = input
        self.output = output
    }
}

public struct CoreAudioDeviceProvider: AudioDeviceProviding {
    public init() {}

    public func deviceSnapshots() async -> [AudioDeviceSnapshot] {
        let deviceIDs = audioObjectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let defaultInput = audioObjectID(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutput = audioObjectID(selector: kAudioHardwarePropertyDefaultOutputDevice)

        return deviceIDs.compactMap { deviceID in
            let input = hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
            let output = hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
            guard input || output else { return nil }
            return AudioDeviceSnapshot(
                id: deviceID,
                uid: stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
                    ?? "coreaudio-\(deviceID)",
                name: stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName)
                    ?? "Audio Device \(deviceID)",
                supportsInput: input,
                supportsOutput: output,
                isDefaultInput: deviceID == defaultInput,
                isDefaultOutput: deviceID == defaultOutput
            )
        }
    }

    private func hasStreams(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private func audioObjectID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr, value != kAudioObjectUnknown else {
            return nil
        }
        return value
    }

    private func audioObjectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else {
            return []
        }
        guard size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return [] }
        var values = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        let status = values.withUnsafeMutableBytes { storage in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage.baseAddress!)
        }
        return status == noErr ? values : []
    }

    private func stringProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value
        else {
            return nil
        }
        return value.takeUnretainedValue() as String
    }
}
