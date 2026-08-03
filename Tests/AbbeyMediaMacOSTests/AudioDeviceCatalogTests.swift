import CoreAudio
import Testing
@testable import AbbeyMediaMacOS

@Suite("Audio device catalog")
struct AudioDeviceCatalogTests {
    @Test("construction does not enumerate physical devices")
    func initializationDoesNotFetch() async {
        let provider = AudioDeviceProviderSpy(devices: [])
        let catalog = AudioDeviceCatalog(provider: provider)
        #expect(await provider.fetchCount() == 0)
        #expect(await catalog.currentSnapshots().isEmpty)
    }

    @Test("refresh stores immutable sorted snapshots from injected provider")
    func refreshUsesInjectedSnapshots() async {
        let output = AudioDeviceSnapshot(
            id: AudioObjectID(22),
            uid: "output-z",
            name: "Studio Output",
            supportsInput: false,
            supportsOutput: true,
            isDefaultOutput: true
        )
        let input = AudioDeviceSnapshot(
            id: AudioObjectID(11),
            uid: "input-a",
            name: "Built-in Microphone",
            supportsInput: true,
            supportsOutput: false,
            isDefaultInput: true
        )
        let provider = AudioDeviceProviderSpy(devices: [output, input])
        let catalog = AudioDeviceCatalog(provider: provider)

        let refreshed = await catalog.refresh()
        #expect(refreshed == [input, output])
        #expect(await catalog.currentSnapshots() == refreshed)
        #expect(await provider.fetchCount() == 1)
    }
}

private actor AudioDeviceProviderSpy: AudioDeviceProviding {
    private let devices: [AudioDeviceSnapshot]
    private var count = 0

    init(devices: [AudioDeviceSnapshot]) {
        self.devices = devices
    }

    func deviceSnapshots() -> [AudioDeviceSnapshot] {
        count += 1
        return devices
    }

    func fetchCount() -> Int { count }
}
