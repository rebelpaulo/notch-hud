import Darwin
import Foundation

/// What the Mac is doing to itself while nobody is sitting at it.
///
/// The phone already showed the two readings that can end a run outright —
/// battery and heat. These are the ones that end it slowly: a machine that has
/// started swapping, filled its disk, or pinned every core is still "on", still
/// green in the session list, and getting less done every minute. From another
/// room there was no way to tell.
///
/// Every field is optional for the same reason the rest of this app treats
/// absence as absence: a syscall that fails, or a first CPU sample with nothing
/// to subtract from, must produce a MISSING reading and never a zero. "0% CPU"
/// and "we could not measure the CPU" would draw the same calm gauge.
struct MachineVitals: Sendable, Equatable {
    /// Busy percentage across all cores, from the delta between two samples.
    /// nil until a second sample exists — there is no such thing as an
    /// instantaneous CPU percentage.
    let cpuPercent: Int?
    let memory: MemoryReading?
    let swapUsedMB: Int?
    let disk: DiskReading?
    /// Whole hours since boot. Answers "did it reboot while I was out?", which
    /// no other reading here can.
    let uptimeHours: Int?
    let isLowPowerMode: Bool
    /// Heaviest processes by memory, aggregated by name. Empty when the scan
    /// found nothing readable rather than nil: an empty list and a failed scan
    /// look the same to a reader, and neither is worth a separate state.
    let topMemory: [ProcessMemory]

    struct MemoryReading: Sendable, Equatable {
        let usedMB: Int
        let totalMB: Int
        /// macOS's own verdict, not ours. Activity Monitor's colour comes from
        /// the same number, and it accounts for compression and file caching in
        /// ways a used/total ratio does not: this Mac reads 80% used while the
        /// kernel still calls the pressure merely elevated.
        let pressure: MemoryPressure?

        var usedPercent: Int {
            guard totalMB > 0 else { return 0 }
            return Int((Double(usedMB) / Double(totalMB) * 100).rounded())
        }
    }

    struct DiskReading: Sendable, Equatable {
        let freeGB: Int
        let totalGB: Int
    }

    /// One name, every process that shares it.
    ///
    /// Aggregated rather than listed one PID at a time because the honest
    /// answer to "what is eating my memory" is "Chrome, 4.5 GB across nine
    /// helpers", not nine separate rows that each look modest. `instances` is
    /// kept so the sum can be read as the sum it is.
    struct ProcessMemory: Sendable, Equatable {
        let name: String
        let megabytes: Int
        let instances: Int
    }

    enum MemoryPressure: String, Sendable, Equatable {
        case normal
        case warning
        case critical

        /// `kern.memorystatus_vm_pressure_level` is a bitmask-shaped enum: 1
        /// normal, 2 warning, 4 critical. Anything else returns nil — a value
        /// we do not recognise is not evidence of calm, and this is the same
        /// mistake (unknown severity → `.normal`) that has already been fixed
        /// twice elsewhere in this app.
        init?(sysctlLevel: Int32) {
            switch sysctlLevel {
            case 1: self = .normal
            case 2: self = .warning
            case 4: self = .critical
            default: return nil
            }
        }
    }
}

protocol MachineVitalsProviding: Sendable {
    func vitals() -> MachineVitals
}

/// Reads the machine through public APIs only.
///
/// Deliberately NOT the CPU temperature in degrees, which is the first thing
/// anyone asks for. macOS exposes no unprivileged way to read it: the sensors
/// live behind SMC keys and a private IOKit HID page, and `powermetrics`
/// refuses without root. `ProcessInfo.thermalState` — already published beside
/// the battery — is the supported reading, and it is the one macOS itself acts
/// on. A number scraped out of a private API would be more precise and less
/// true, and would put this app in the category of software that reads things
/// it was not offered.
final class SystemMachineVitalsProvider: MachineVitalsProviding, @unchecked Sendable {
    /// The previous CPU tick sample. CPU percentage is a rate, so it needs two
    /// readings and a lock: the bridge polls from the main actor but nothing
    /// promises that forever.
    private let lock = NSLock()
    private var previousTicks: (busy: Double, total: Double)?

    func vitals() -> MachineVitals {
        MachineVitals(
            cpuPercent: cpuPercent(),
            memory: memoryReading(),
            swapUsedMB: swapUsedMB(),
            disk: diskReading(),
            uptimeHours: Int(ProcessInfo.processInfo.systemUptime / 3600),
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            topMemory: topMemory()
        )
    }

    // MARK: CPU

    private func cpuPercent() -> Int? {
        guard let sample = cpuTickSample() else { return nil }
        lock.lock()
        let previous = previousTicks
        previousTicks = sample
        lock.unlock()

        // First call has nothing to subtract from. Returning 0 here would be a
        // lie told once per launch, on the reading most likely to be looked at
        // first.
        guard let previous else { return nil }
        let busy = sample.busy - previous.busy
        let total = sample.total - previous.total
        guard total > 0, busy >= 0 else { return nil }
        return min(100, max(0, Int((busy / total * 100).rounded())))
    }

    private func cpuTickSample() -> (busy: Double, total: Double)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = withUnsafePointer(to: info.cpu_ticks) {
            $0.withMemoryRebound(to: UInt32.self, capacity: Int(CPU_STATE_MAX)) { buffer in
                (0..<Int(CPU_STATE_MAX)).map { Double(buffer[$0]) }
            }
        }
        let total = ticks.reduce(0, +)
        return (busy: total - ticks[Int(CPU_STATE_IDLE)], total: total)
    }

    // MARK: Memory

    private func memoryReading() -> MachineVitals.MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // Active + wired + compressed is what Activity Monitor calls "Memory
        // Used". Inactive and speculative pages are excluded on purpose: they
        // are cache the kernel will hand back the moment anything asks, and
        // counting them would report a healthy Mac as permanently full.
        // `sysconf`, not the `vm_kernel_page_size` global: the global is a
        // mutable symbol and Swift 6 refuses to read it across concurrency
        // domains. Same 16K answer, asked in a way that is safe to ask twice.
        let page = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        let used = (UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }

        return MachineVitals.MemoryReading(
            usedMB: Int(used / 1_048_576),
            totalMB: Int(total / 1_048_576),
            pressure: sysctlInt32("kern.memorystatus_vm_pressure_level")
                .flatMap(MachineVitals.MemoryPressure.init(sysctlLevel:))
        )
    }

    /// Swap in use, which on a Mac with pressure to spare stays at zero for
    /// months and then does not. It is the clearest single sign that a machine
    /// has stopped coping, and unlike the percentage it cannot be explained
    /// away by caching.
    private func swapUsedMB() -> Int? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int(usage.xsu_used / 1_048_576)
    }

    private func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: Disk

    /// `volumeAvailableCapacityForImportantUsage`, which is what Finder shows
    /// and what a build actually gets — it counts space macOS would purge to
    /// make room. The raw free-block count reads far lower on an APFS volume
    /// full of local snapshots and would cry wolf.
    private func diskReading() -> MachineVitals.DiskReading? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]),
            let available = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else { return nil }

        return MachineVitals.DiskReading(
            freeGB: Int(available / 1_073_741_824),
            totalGB: total / 1_073_741_824
        )
    }

    // MARK: Processes

    /// The five heaviest process names by memory footprint.
    ///
    /// `libproc` rather than shelling out to `ps`: no subprocess per poll, and
    /// `ri_phys_footprint` is the number Activity Monitor shows, which includes
    /// the process's share of compressed memory. RSS — all `ps` can give —
    /// omits exactly that, and on a Mac deep into compression it understates
    /// the worst offenders most.
    ///
    /// Processes owned by other users answer EPERM and are skipped. That leaves
    /// the user's own, which is where anything worth killing lives; the system
    /// daemons that stay hidden are not ones anybody would act on anyway.
    private func topMemory(limit: Int = 5) -> [MachineVitals.ProcessMemory] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let byteCount = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard byteCount > 0 else { return [] }

        var totals: [String: (bytes: UInt64, instances: Int)] = [:]
        for pid in pids.prefix(Int(byteCount) / MemoryLayout<pid_t>.size) where pid > 0 {
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard read == 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            let name = String(cString: nameBuffer)
            guard !name.isEmpty else { continue }

            let existing = totals[name] ?? (0, 0)
            totals[name] = (existing.bytes + usage.ri_phys_footprint, existing.instances + 1)
        }

        return totals
            .map {
                MachineVitals.ProcessMemory(
                    name: $0.key,
                    megabytes: Int($0.value.bytes / 1_048_576),
                    instances: $0.value.instances
                )
            }
            // Name breaks ties so the order cannot flap between two equal rows,
            // which would republish the whole blob for nothing.
            .sorted { ($0.megabytes, $1.name) > ($1.megabytes, $0.name) }
            .prefix(limit)
            .filter { $0.megabytes > 0 }
    }
}
