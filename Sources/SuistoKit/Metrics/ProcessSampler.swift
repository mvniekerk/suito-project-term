import Foundation

/// Samples CPU for each session's process tree on a timer.
///
/// CPU is a rate, so it needs two samples: total CPU-seconds consumed is read
/// each tick and divided by the elapsed wall time. 100% means one core fully
/// busy; a parallel build can legitimately exceed that.
@MainActor
final class ProcessSampler {
    /// Percent of one core, keyed by the root pid that was asked about.
    typealias Reading = [pid_t: Double]

    private var timer: Timer?
    private var previous: [pid_t: (cpuSeconds: Double, at: CFAbsoluteTime)] = [:]
    private var inFlight = false

    let interval: TimeInterval

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    /// `roots` supplies the pids to measure each tick; `apply` receives the
    /// percentages back on the main actor.
    func start(
        roots: @escaping @MainActor () -> [pid_t],
        apply: @escaping @MainActor (Reading) -> Void
    ) {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.tick(roots: roots, apply: apply)
            }
        }
        // Keep sampling while a menu is open or the window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(
        roots: @MainActor () -> [pid_t],
        apply: @escaping @MainActor (Reading) -> Void
    ) {
        // Walking a few hundred processes is cheap but not free; never let
        // ticks pile up behind a slow one.
        guard !inFlight else { return }
        let pids = roots().filter { $0 > 0 }
        guard !pids.isEmpty else {
            previous.removeAll(keepingCapacity: true)
            apply([:])
            return
        }

        inFlight = true
        DispatchQueue.global(qos: .utility).async {
            let totals = Self.cpuSecondsPerTree(roots: pids)
            let now = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.inFlight = false
                    apply(self.rates(from: totals, at: now))
                }
            }
        }
    }

    /// Turns cumulative CPU-seconds into a percentage of one core.
    private func rates(from totals: [pid_t: Double], at now: CFAbsoluteTime) -> Reading {
        var reading: Reading = [:]
        for (pid, total) in totals {
            defer { previous[pid] = (total, now) }
            guard let last = previous[pid] else {
                // First sample for this pid: no interval to divide by yet.
                reading[pid] = 0
                continue
            }
            let elapsed = now - last.at
            guard elapsed > 0 else { continue }
            // A process that exited and had its pid reused can report less CPU
            // than last time; clamp rather than show a negative.
            reading[pid] = max(0, (total - last.cpuSeconds) / elapsed * 100)
        }
        // Forget pids we were not asked about, so the table cannot grow for
        // the life of the app.
        previous = previous.filter { totals.keys.contains($0.key) }
        return reading
    }

    private nonisolated static func cpuSecondsPerTree(roots: [pid_t]) -> [pid_t: Double] {
        guard let table = ProcessTable.snapshot() else { return [:] }
        var totals: [pid_t: Double] = [:]
        for root in roots {
            var sum = 0.0
            for pid in table.subtree(of: root) {
                sum += ProcessTable.cpuSeconds(of: pid) ?? 0
            }
            totals[root] = sum
        }
        return totals
    }
}
