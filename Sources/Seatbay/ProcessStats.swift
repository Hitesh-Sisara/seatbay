import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import SeatbayCore

/// One sample of every process on the system: parent links, memory and CPU time.
struct ProcessTable {
    struct Entry {
        let pid: pid_t
        let ppid: pid_t
        let footprint: UInt64      // bytes (what Activity Monitor calls "Memory")
        let cpuSeconds: Double     // user + system CPU time so far
        let startTime: Date
    }

    let entries: [pid_t: Entry]
    let children: [pid_t: [pid_t]]
    let takenAt: Date

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func sample() -> ProcessTable {
        var entries: [pid_t: Entry] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for pid in ProcessInspector.allPIDs() {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
            }
            let cpu = ok ? Double(usage.ri_user_time + usage.ri_system_time) * timebase / 1e9 : 0
            let start = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)
            let ppid = pid_t(bsd.pbi_ppid)
            entries[pid] = Entry(pid: pid, ppid: ppid, footprint: ok ? usage.ri_phys_footprint : 0, cpuSeconds: cpu, startTime: start)
            children[ppid, default: []].append(pid)
        }
        return ProcessTable(entries: entries, children: children, takenAt: Date())
    }

    /// The process and all of its descendants (Electron helpers, Claude Code, MCP servers, tool commands).
    func tree(of root: pid_t) -> [Entry] {
        var result: [Entry] = []
        var stack = [root]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted, let entry = entries[pid] else { continue }
            result.append(entry)
            stack += children[pid] ?? []
        }
        return result
    }
}

struct TreeStats: Equatable {
    var memory: UInt64 = 0
    var cpuSeconds: Double = 0
    var processCount = 0
}

enum SystemState {
    /// PIDs holding a "don't idle-sleep" power assertion. Claude takes one while a Code session works
    /// (Settings → Claude Code → Keep computer awake while Claude works).
    static func pidsKeepingAwake() -> Set<pid_t> {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dict = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let awakeTypes: Set<String> = ["NoIdleSleepAssertion", "PreventUserIdleSystemSleep", "PreventSystemSleep"]
        var result = Set<pid_t>()
        for (pid, assertions) in dict where assertions.contains(where: { awakeTypes.contains(($0["AssertType"] as? String) ?? "") }) {
            result.insert(pid.int32Value)
        }
        return result
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    static var userIdleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func file(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum DiskUsage {
    /// Folders inside a Claude data folder that Claude rebuilds or re-downloads by itself.
    static let regenerable = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                              "GraphiteDawnCache", "GPUPersistentCache", "Shared Dictionary", "Crashpad"]

    static func allocatedSize(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func cacheSize(in dataDir: URL) -> UInt64 {
        regenerable.reduce(0) { $0 + allocatedSize(of: dataDir.appendingPathComponent($1)) }
    }

    /// Deletes the regenerable caches of a Claude that is not running.
    static func clearCaches(in dataDir: URL) throws -> UInt64 {
        var freed: UInt64 = 0
        for name in regenerable {
            let url = dataDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            freed += allocatedSize(of: url)
            try FileManager.default.removeItem(at: url)
        }
        return freed
    }
}
