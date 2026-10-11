import Foundation
import Testing

@testable import MacXTermCore

@Suite("任务恢复与服务器状态") struct RecoveryAndMonitorTests {
    private func sample(cpu: String = "100 0 100 700 100 0 0 0 90 0", uptime: Int = 100, rx: Int = 1000, tx: Int = 2000)
        -> String
    {
        """
        __MXT_ID__
        fixture
        Linux 6.8
        __MXT_MODEL__
        Test CPU
        __MXT_STAT__
        cpu  \(cpu)
        cpu0 50 0 50 350 50 0 0 0
        cpu1 50 0 50 350 50 0 0 0
        __MXT_MEM__
        MemTotal: 1024 kB
        MemAvailable: 512 kB
        SwapTotal: 256 kB
        SwapFree: 128 kB
        __MXT_UPTIME__
        \(uptime).00 100.00
        __MXT_LOAD__
        0.10 0.20 0.30 1/100 101
        __MXT_NET__
        eth0: \(rx) 0 0 0 0 0 0 0 \(tx) 0 0 0 0 0 0 0
        lo: 100 0 0 0 0 0 0 0 100 0 0 0 0 0 0 0
        __MXT_DISK__
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/vda1 1000 700 250 74% /data with spaces
        __MXT_END__
        """
    }
    @Test func ratesUseDeltasExcludeGuestAndRespectMemoryAvailable() throws {
        let previous = try ServerMonitor.parse(sample())
        let current = try ServerMonitor.parse(
            sample(cpu: "150 0 100 850 100 0 0 0 110 0", uptime: 110, rx: 2000, tx: 4000))
        let metrics = ServerMetrics(sample: current, previous: previous)
        #expect(previous.cpuTotal == 1000)
        #expect(metrics.cpuPercent == 25)
        #expect(current.cores == 2)
        #expect(current.memoryUsed == 512 * 1024)
        #expect(current.memoryPercent == 50)
        #expect(metrics.interfaces.count == 1)
        #expect(metrics.interfaces.first?.received == 100)
        #expect(metrics.interfaces.first?.sent == 200)
        #expect(current.disks.first?.mount == "/data with spaces")
        #expect(current.disks.first?.usedPercent == 74)
    }
    @Test func firstSampleAndCounterResetsDoNotInventRates() throws {
        let old = try ServerMonitor.parse(sample())
        let reset = try ServerMonitor.parse(sample(cpu: "1 0 1 8 0 0 0 0", uptime: 1, rx: 1, tx: 1))
        #expect(ServerMetrics(sample: old, previous: nil).cpuPercent == nil)
        let metrics = ServerMetrics(sample: reset, previous: old)
        #expect(metrics.cpuPercent == nil)
        #expect(metrics.interfaces.first?.received == nil)
        #expect(throws: MacXError.self) { try ServerMonitor.parse("unexpected output") }
        #expect(throws: MacXError.self) { try ServerMonitor.parse(sample(cpu: "nan 0 0 0")) }
    }
    @Test func recoveryPausesInsteadOfStartingConnections() throws {
        var job = TransferTask(name: "test.txt", direction: .upload)
        job.state = .running
        job.completedBytes = 123
        var journal = TransferJournal()
        journal.records = [
            PendingTransfer(
                task: job, hostID: UUID(), remotePath: "/test.txt", scopeBookmark: Data([1]), destinationName: nil,
                replaceExisting: false)
        ]
        let data = try JSONEncoder().encode(journal)
        var restored = try JSONDecoder().decode(TransferJournal.self, from: data)
        try restored.prepareForRecovery()
        #expect(restored.records.first?.task.state == .paused)
        #expect(restored.records.first?.task.completedBytes == 0)
        #expect(restored.records.first?.id == job.id)
        restored.version = 999
        #expect(throws: MacXError.self) { try restored.prepareForRecovery() }
    }
    @Test func recoveryRejectsEscapingDownloadNames() throws {
        let record = PendingTransfer(
            task: TransferTask(name: "bad", direction: .download), hostID: UUID(), remotePath: "/file",
            scopeBookmark: Data(), destinationName: "../outside", replaceExisting: false)
        #expect(throws: MacXError.self) { try record.localURL(in: URL(fileURLWithPath: "/safe")) }
    }
}
