import Darwin
import Foundation
import Testing
@testable import SuistoKit

@Suite("Process tree and CPU accounting")
struct ProcessTreeTests {

    /// librio only reports the directly spawned pid, so the CPU badge is only
    /// right if the whole subtree is found.
    @Test("A subtree includes grandchildren, not just direct children")
    func subtreeIsRecursive() {
        let table = ProcessTable(parents: [
            100: 1,     // the session's shell
            200: 100,   // a build it started
            300: 200,   // a compiler the build started
            400: 100,   // a sibling
            999: 1,     // unrelated
        ])

        let found = Set(table.subtree(of: 100))
        #expect(found == [100, 200, 300, 400])
        #expect(!found.contains(999))
    }

    @Test("A leaf process is its own subtree")
    func leafSubtree() {
        let table = ProcessTable(parents: [100: 1])
        #expect(table.subtree(of: 100) == [100])
    }

    @Test("A pid that is not in the table still yields itself")
    func unknownPid() {
        let table = ProcessTable(parents: [100: 1])
        #expect(table.subtree(of: 555) == [555])
    }

    @Test("A cycle in a racing snapshot terminates instead of hanging")
    func cyclesTerminate() {
        // Impossible in a real table, but a snapshot read while processes come
        // and go must never spin the sampler forever.
        let table = ProcessTable(parents: [100: 200, 200: 100])
        #expect(Set(table.subtree(of: 100)) == [100, 200])
    }

    @Test("The live process table can be read and contains this process")
    func snapshotFindsSelf() throws {
        let table = try #require(ProcessTable.snapshot())
        #expect(table.subtree(of: getpid()).contains(getpid()))
    }

    /// Guards the units: `ri_user_time` is mach absolute time, not
    /// nanoseconds. Reading it as nanoseconds under-reports CPU by about
    /// 41.7x on Apple Silicon, which showed up in the UI as a fully busy core
    /// reporting 2%.
    ///
    /// Checked against `getrusage`, which reports the same quantity for this
    /// process in plain seconds and microseconds. Comparing two independent
    /// sources makes this immune to how much CPU the test actually gets —
    /// an absolute threshold over a wall-clock busy loop is flaky under
    /// parallel test execution.
    @Test("CPU time is in seconds, cross-checked against getrusage")
    func cpuSecondsUseMachTimebase() throws {
        // Do some work first, so both readings are comfortably non-zero.
        var sink = 0.0
        for i in 1...2_000_000 { sink += Double(i).squareRoot() }
        #expect(sink > 0)

        var reference = rusage()
        #expect(getrusage(RUSAGE_SELF, &reference) == 0)
        let referenceSeconds =
            Double(reference.ru_utime.tv_sec) + Double(reference.ru_utime.tv_usec) / 1_000_000
            + Double(reference.ru_stime.tv_sec) + Double(reference.ru_stime.tv_usec) / 1_000_000

        let measured = try #require(ProcessTable.cpuSeconds(of: getpid()))

        #expect(referenceSeconds > 0.01, "the reference reading is too small to compare against")
        // The two are sampled microseconds apart, so allow a little drift but
        // nothing like the 41.7x a units mistake would produce.
        let ratio = measured / referenceSeconds
        #expect(ratio > 0.8 && ratio < 1.25,
                """
                cpuSeconds=\(measured)s disagrees with getrusage=\(referenceSeconds)s \
                (ratio \(ratio)): the mach timebase conversion is probably wrong
                """)
    }
}
