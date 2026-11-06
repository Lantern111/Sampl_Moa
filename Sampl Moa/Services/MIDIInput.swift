import CoreMIDI
import Foundation

/// Listens to every MIDI device connected to the Mac, including any plugged in later.
nonisolated final class MIDIInput: @unchecked Sendable {
    enum Event: Sendable {
        case noteOn(channel: Int, note: Int, velocity: Int)
        case noteOff(channel: Int, note: Int)
        case sustain(isDown: Bool)
        case pitchBend(value: Int)
        case controlChange(controller: Int, value: Int)
    }

    private let onEvent: @Sendable (Event) -> Void
    private let onDevicesChanged: @Sendable ([String]) -> Void
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []

    /// `onEvent` runs on the system's MIDI thread, so that a hit can reach the sound without waiting for the screen.
    /// Returns nil if the system's MIDI service can't be reached.
    init?(onEvent: @escaping @Sendable (Event) -> Void, onDevicesChanged: @escaping @Sendable ([String]) -> Void) {
        self.onEvent = onEvent
        self.onDevicesChanged = onDevicesChanged

        let created = MIDIClientCreateWithBlock("Sampl Moa" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.connectToAllDevices() }
        }
        guard created == noErr else { return nil }

        let opened = MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port) { [onEvent] list, _ in
            Self.read(list, into: onEvent)
        }
        guard opened == noErr else { return nil }

        connectToAllDevices()
    }

    deinit {
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    private func connectToAllDevices() {
        let sources = Set((0..<MIDIGetNumberOfSources()).map(MIDIGetSource))

        for source in sources.subtracting(connected) {
            MIDIPortConnectSource(port, source, nil)
        }
        for source in connected.subtracting(sources) {
            MIDIPortDisconnectSource(port, source)
        }
        connected = sources

        onDevicesChanged(Self.deviceNames(of: sources))
    }

    /// A device can have several ports, but people only want to see its name once. The system's own IAC and network
    /// sources, and virtual ports other apps make (like Logic Pro Virtual Out), are still listened to, but they aren't
    /// something a person plugged in, so they don't get a device's layout or its notice.
    private static func deviceNames(of sources: Set<MIDIEndpointRef>) -> [String] {
        var names: Set<String> = []
        for source in sources {
            var entity = MIDIEntityRef()
            var device = MIDIDeviceRef()
            guard MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0 else { continue }
            MIDIEntityGetDevice(entity, &device)
            let owner = device == 0 ? source : device

            let driver = string(kMIDIPropertyDriverOwner, of: owner) ?? ""
            if driver.contains("IAC") || driver.contains("RTP") { continue }
            if let name = string(kMIDIPropertyName, of: owner) { names.insert(name) }
        }
        return names.sorted()
    }

    private static func string(_ property: CFString, of object: MIDIObjectRef) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func read(_ list: UnsafePointer<MIDIEventList>, into onEvent: (Event) -> Void) {
        for packet in list.unsafeSequence() {
            let wordCount = Int(packet.pointee.wordCount)
            let offset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) ?? 0
            let words = (UnsafeRawPointer(packet) + offset).assumingMemoryBound(to: UInt32.self)

            var index = 0
            while index < wordCount {
                let word = words[index]
                index += length(ofMessageStartingWith: word)
                if let event = event(from: word) { onEvent(event) }
            }
        }
    }

    /// How many words a message takes up, which the first word's top four bits decide.
    private static func length(ofMessageStartingWith word: UInt32) -> Int {
        switch word >> 28 {
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        case 0x5, 0xD, 0xE, 0xF: 4
        default: 1
        }
    }

    /// Everything arrives as a MIDI 1.0 message, because that's what the port asked for, whatever the device speaks.
    private static func event(from word: UInt32) -> Event? {
        guard word >> 28 == 0x2 else { return nil }

        let status = Int(word >> 16) & 0xF0
        let channel = Int(word >> 16) & 0x0F
        let first = Int(word >> 8) & 0x7F
        let second = Int(word) & 0x7F

        switch status {
        case 0x90:
            return second > 0 ? .noteOn(channel: channel, note: first, velocity: second) : .noteOff(channel: channel, note: first)
        case 0x80:
            return .noteOff(channel: channel, note: first)
        case 0xB0 where first == 64:
            return .sustain(isDown: second >= 64)
        case 0xB0:
            return .controlChange(controller: first, value: second)
        case 0xE0:
            return .pitchBend(value: second << 7 | first)
        default:
            return nil
        }
    }
}
