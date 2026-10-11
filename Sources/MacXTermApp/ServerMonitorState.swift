import Foundation
import MacXTermCore
import Observation

@MainActor @Observable final class ServerMonitorState {
    var metrics: ServerMetrics?
    var history = [ServerMetrics]()
    var error = ""
    var paused = false
    var isRunning = false
    @ObservationIgnored private var observers = 0
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var service: SSHSessionService?
    @ObservationIgnored private var sampler = ServerSampler()
    @ObservationIgnored private var segment = 0

    /// The bottom bar and detail sheet share one sampler and one bounded history.
    func observe(using session: SSHSessionService) async {
        observers += 1
        if service !== session {
            runner?.cancel()
            runner = nil
            service = session
            sampler = ServerSampler()
            metrics = nil
            history = []
        }
        if runner == nil { start(session) }
        defer {
            observers -= 1
            if observers == 0 {
                runner?.cancel()
                runner = nil
                generation = UUID()
                isRunning = false
            }
        }
        do { while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) } } catch {}
    }
    func retry() {
        guard observers > 0, let service else { return }
        runner?.cancel()
        start(service)
    }
    private func start(_ session: SSHSessionService) {
        let token = UUID()
        generation = token
        segment += 1
        isRunning = true
        runner = Task { [weak self] in await self?.run(session, token: token) }
    }
    private func run(_ session: SSHSessionService, token: UUID) async {
        var previous: ServerSample?
        var failures = 0
        var wasPaused = false
        do {
            while !Task.isCancelled && generation == token {
                if paused {
                    previous = nil
                    wasPaused = true
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                if wasPaused {
                    segment += 1
                    wasPaused = false
                }
                let start = ContinuousClock.now
                do {
                    let sample = try await sampler.sample(using: session)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    let point = ServerMetrics(sample: sample, previous: previous, segment: segment)
                    metrics = point
                    history.append(point)
                    history.removeAll { $0.sample.date < sample.date.addingTimeInterval(-300) }
                    if history.count > 301 { history.removeFirst(history.count - 301) }
                    previous = sample
                    failures = 0
                    error = await sampler.diskWarning
                    try await Task.sleep(until: start.advanced(by: .seconds(1)), clock: .continuous)
                } catch {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    self.error = error.localizedDescription
                    previous = nil
                    segment += 1
                    failures += 1
                    if self.error.contains("requires Linux") || self.error.contains("Linux /proc") { break }
                    try await Task.sleep(for: .seconds(min(60, pow(2, Double(min(6, failures))))))
                }
            }
        } catch {}
        if generation == token { isRunning = false }
    }
}
