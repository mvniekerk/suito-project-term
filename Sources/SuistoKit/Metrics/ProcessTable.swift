import Darwin

/// A snapshot of every process's parent, so a session's whole subtree can be
/// found from the one pid librio gives us.
///
/// `rio_surface_child_pid` reports only the directly spawned program. The work
/// usually happens in its children — a shell's build, an agent's subprocesses —
/// so CPU has to be summed over the subtree, not that single pid.
struct ProcessTable {
    private let childrenByParent: [pid_t: [pid_t]]

    init(parents: [pid_t: pid_t]) {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents {
            children[parent, default: []].append(pid)
        }
        self.childrenByParent = children
    }

    /// Every descendant of `root`, including `root` itself.
    func subtree(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var seen: Set<pid_t> = []
        var queue: [pid_t] = [root]

        while let pid = queue.popLast() {
            // A cycle cannot happen in a real process table, but a corrupt or
            // racing snapshot should not hang the sampler.
            guard seen.insert(pid).inserted else { continue }
            found.append(pid)
            if let children = childrenByParent[pid] { queue.append(contentsOf: children) }
        }
        return found
    }

    /// Reads the live process table via sysctl.
    static func snapshot() -> ProcessTable? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]

        var length = 0
        let sizeRC = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, 4, nil, &length, nil, 0)
        }
        guard sizeRC == 0, length > 0 else { return nil }

        // The table can grow between sizing and fetching, so ask for slack and
        // trust the byte count the kernel reports back.
        let capacity = length + 128 * MemoryLayout<kinfo_proc>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: capacity, alignment: MemoryLayout<kinfo_proc>.alignment)
        defer { raw.deallocate() }

        var got = capacity
        let fetchRC = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, 4, raw, &got, nil, 0)
        }
        guard fetchRC == 0 else { return nil }

        let count = got / MemoryLayout<kinfo_proc>.stride
        let procs = raw.bindMemory(to: kinfo_proc.self, capacity: count)
        var parents: [pid_t: pid_t] = [:]
        parents.reserveCapacity(count)
        for i in 0..<count {
            parents[procs[i].kp_proc.p_pid] = procs[i].kp_eproc.e_ppid
        }
        return ProcessTable(parents: parents)
    }

    /// Converts mach time units to seconds.
    ///
    /// `ri_user_time` and `ri_system_time` are mach absolute time, not
    /// nanoseconds. On Apple Silicon one tick is 125/3 ns, so reading them as
    /// nanoseconds under-reports CPU by about 41.7x.
    private static let machTicksToSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Total CPU time a process has consumed, in seconds, or nil when it is
    /// gone or not ours to inspect.
    static func cpuSeconds(of pid: pid_t) -> Double? {
        var usage = rusage_info_v4()
        var rc: Int32 = -1
        withUnsafeMutablePointer(to: &usage) { pointer in
            // proc_pid_rusage takes the address of the struct itself, cast to
            // rusage_info_t* — not the address of a pointer to it.
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                rc = proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard rc == 0 else { return nil }
        return Double(usage.ri_user_time + usage.ri_system_time) * machTicksToSeconds
    }
}
