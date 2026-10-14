import Foundation
import GlintCore
import GlintEmbedding
import GlintExtractors
import GlintStore

// MARK: Queue loop

extension Indexer {
    func runLoop() async {
        while !Task.isCancelled {
            if userPaused {
                setPhase(.paused(.user))
                await waitForWake()
                continue
            }
            if let reason = power.pauseReason() {
                setPhase(.paused(reason))
                await waitForWake(timeout: .seconds(30))
                continue
            }
            setPhase(.indexing)
            await runPool()
            if userPaused || power.pauseReason() != nil { continue }
            _ = try? await writer.failExhausted()
            setPhase(.idle)
            await publishStatus(force: true)
            await waitForWake(timeout: .seconds(300))
        }
    }

    /// Runs a pool of workers until the queue is empty, indexing pauses, or the task is
    /// cancelled. Each worker takes the next file as soon as it finishes one, so a long video
    /// never holds up the files behind it. On battery or when warm, fewer workers and OCR
    /// lanes run instead of pausing.
    func runPool() async {
        let constrained = power.isConstrained
        let workers = options.workers(constrained: constrained)
        ExtractionLanes.ocr.setWidth(options.ocrLanes(constrained: constrained))
        queueExhausted = false
        activePools += 1
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask { [weak self] in
                    while let self, !Task.isCancelled, let record = await self.claimNext() {
                        _ = await self.pipelineSnapshot().process(record)
                        await self.finished(record.id)
                    }
                }
            }
        }
        activePools -= 1
        guard activePools == 0 else { return }
        // Return anything prefetched but not started (pause or cancel) to the queue.
        let unstarted = prefetched
        prefetched.removeAll()
        for record in unstarted {
            inFlight.remove(record.id)
            try? await writer.release(record.id)
        }
    }

    private func pipelineSnapshot() -> FilePipeline { pipeline }

    private func finished(_ id: FileID) async {
        inFlight.remove(id)
        await publishStatus()
    }

    /// The next file for a worker, or `nil` when the worker should stop (queue empty, paused,
    /// item limit reached).
    private func claimNext() async -> FileRecord? {
        while true {
            if Task.isCancelled || userPaused || power.pauseReason() != nil { return nil }
            if !prefetched.isEmpty { return prefetched.removeFirst() }
            if queueExhausted { return nil }
            // One refill at a time; it clears `refill` itself before finishing, so waiters never
            // spin on a completed task.
            let task = refill ?? Task { await self.refillQueue() }
            refill = task
            await task.value
        }
    }

    /// Claims the next few files in queue order, skipping files already in flight.
    private func refillQueue() async {
        defer { refill = nil }
        let limit = max(2, options.concurrentFiles * 2)
        var kinds = Set(MediaKind.allCases)
        if options.videoOnlyOnPower, power.isOnBattery { kinds.remove(.video) }
        let claimed = (try? await writer.claimPending(limit: limit, kinds: kinds, excluding: inFlight)) ?? []
        if claimed.isEmpty {
            queueExhausted = true
            return
        }
        for record in claimed { inFlight.insert(record.id) }
        prefetched.append(contentsOf: claimed)
    }

    private func waitForWake(timeout: Duration? = nil) async {
        if wakePending {
            wakePending = false
            return
        }
        let timer = timeout.map { duration in
            Task { [weak self] in
                try? await Task.sleep(for: duration)
                await self?.wake()
            }
        }
        await withCheckedContinuation { wakeContinuation = $0 }
        timer?.cancel()
    }

    func wake() {
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        } else {
            wakePending = true
        }
    }
}
