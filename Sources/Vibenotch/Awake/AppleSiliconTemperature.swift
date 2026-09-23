import Foundation

/// The die temperature, in Celsius, off the Apple Silicon PMU sensors.
///
/// THIS USES A PRIVATE API, deliberately and with its eyes open. An earlier
/// version of this app said in a comment that macOS exposes no unprivileged
/// way to read the temperature and that `powermetrics` needs root. The second
/// half is true; the first is not. `IOHIDEventSystemClient` publishes the same
/// PMU sensors `powermetrics` reads, to any process, with no privileges at all
/// — which is how every menu-bar temperature monitor on GitHub does it
/// (thermalbar, Stats, macmon among them). Saying it was impossible was easier
/// than checking, and it was wrong.
///
/// What is genuinely true, and the reason every call site treats a missing
/// reading as normal:
///
/// - The symbols are private. They are not in any header, Apple owes nobody
///   their continued existence, and a macOS update may remove or rename them.
///   Everything below is resolved with `dlsym` at runtime and every failure
///   returns nil, so the day that happens the temperature disappears from the
///   phone and nothing else changes.
/// - It rules out the Mac App Store. Vibenotch is distributed as a GitHub
///   release and signed with a local certificate, so this costs nothing here —
///   but it is a door that closes.
///
/// Intel Macs are not supported: their sensors live behind the SMC and answer
/// to different keys entirely. They get nil, which is the same "not measured"
/// every other absent reading uses.
final class AppleSiliconTemperatureReader: @unchecked Sendable {
    // The HID usage page Apple files its own sensors under, and the usage that
    // selects the temperature ones. Both are documented only by everyone
    // having used them for a decade.
    private static let appleVendorUsagePage: Int32 = 0xFF00
    private static let temperatureSensorUsage: Int32 = 0x0005
    private static let temperatureEventType: Int64 = 15

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int32) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (AnyObject, Int32) -> Double

    private struct Symbols {
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyProperty: CopyProperty
        let copyEvent: CopyEvent
        let getFloatValue: GetFloatValue
    }

    private let lock = NSLock()
    /// Resolved once. The client is expensive to build and the poll runs every
    /// few seconds, so it is created on first use and kept — but only after the
    /// matching dictionary has been applied, since a client with no matching
    /// returns every HID service on the machine.
    private var resolved: (symbols: Symbols, client: AnyObject)??

    /// nil when the sensors cannot be read at all — wrong architecture, symbols
    /// gone, or a client that returned nothing. Never a zero: 0 °C is a reading
    /// a Mac in a freezer would give, not the absence of one.
    func dieTemperatureCelsius() -> Double? {
        guard let (symbols, client) = connection() else { return nil }
        guard let services = symbols.copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return nil
        }

        // `tdie` is the die sensor proper — the number every monitor reports as
        // the CPU temperature. The same machine also exposes `tdev` (device),
        // `tcal` (calibration), NAND and battery sensors; averaging those in
        // would quietly drag the answer toward whatever is coolest.
        //
        // Averaged across the dies rather than taking the hottest. A single
        // core cluster spikes for a fraction of a second under any load, and a
        // maximum would make the phone read like the Mac is in trouble every
        // time it compiles something.
        var total = 0.0
        var count = 0
        for service in services {
            guard let name = symbols.copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String,
                name.hasPrefix("PMU tdie")
            else { continue }
            guard let event = symbols.copyEvent(service, Self.temperatureEventType, 0, 0)?
                .takeRetainedValue()
            else { continue }

            let value = symbols.getFloatValue(event, Int32(Self.temperatureEventType << 16))
            // A sensor that answers zero has not been read, it has been
            // skipped: real dies do not sit at absolute nothing, and letting
            // one into the average would pull the whole reading down.
            guard value > 0, value < 150 else { continue }
            total += value
            count += 1
        }

        guard count > 0 else { return nil }
        return total / Double(count)
    }

    private func connection() -> (Symbols, AnyObject)? {
        lock.lock()
        defer { lock.unlock() }

        // Double-optional on purpose: the outer one is "have we tried yet",
        // the inner "did it work". Without it a machine with no sensors would
        // dlopen IOKit and rebuild a client on every single poll, forever.
        if let resolved { return resolved.map { ($0.symbols, $0.client) } }

        let connection = resolve()
        resolved = connection
        return connection.map { ($0.symbols, $0.client) }
    }

    private func resolve() -> (symbols: Symbols, client: AnyObject)? {
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            RTLD_LAZY
        ) else { return nil }

        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard let create = symbol("IOHIDEventSystemClientCreate", ClientCreate.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloatValue = symbol("IOHIDEventGetFloatValue", GetFloatValue.self)
        else { return nil }

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        _ = setMatching(client, [
            "PrimaryUsagePage": Self.appleVendorUsagePage,
            "PrimaryUsage": Self.temperatureSensorUsage,
        ] as CFDictionary)

        return (
            Symbols(
                setMatching: setMatching,
                copyServices: copyServices,
                copyProperty: copyProperty,
                copyEvent: copyEvent,
                getFloatValue: getFloatValue
            ),
            client
        )
    }
}
