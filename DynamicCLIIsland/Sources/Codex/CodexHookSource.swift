//
//  CodexHookSource.swift
//  HermitFlow
//
//  Optional real-time Codex file event source. File-based polling remains the fallback path.
//

import Foundation

final class CodexHookSource: @unchecked Sendable {
    typealias EventSink = @Sendable ([IslandEvent]) -> Void
    typealias SessionIDProvider = @Sendable () -> Set<String>

    private let source: LocalCodexSource
    private let sessionReader: CodexSessionReader
    private let queue: DispatchQueue
    private var sessionFD: CInt = -1
    private var sessionMonitor: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?
    private var running = false

    init(
        source: LocalCodexSource = LocalCodexSource(),
        sessionReader: CodexSessionReader = CodexSessionReader(),
        queue: DispatchQueue = DispatchQueue(label: "HermitFlow.codexHookSource", qos: .utility)
    ) {
        self.source = source
        self.sessionReader = sessionReader
        self.queue = queue
    }

    deinit {
        stop()
    }

    @discardableResult
    func start(
        knownSessionIDs: @escaping SessionIDProvider,
        eventSink: @escaping EventSink
    ) -> Bool {
        queue.sync {
            if running {
                return true
            }

            guard sessionReader.sessionsDirectoryExists() else {
                return false
            }

            let path = FilePaths.codexHome.appendingPathComponent("sessions", isDirectory: true).path
            sessionFD = open(path, O_EVTONLY)
            guard sessionFD >= 0 else {
                sessionFD = -1
                return false
            }

            let monitor = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: sessionFD,
                eventMask: [.write, .rename, .delete, .extend],
                queue: queue
            )

            monitor.setEventHandler { [weak self] in
                self?.scheduleRefresh(knownSessionIDs: knownSessionIDs, eventSink: eventSink)
            }
            monitor.setCancelHandler { [weak self] in
                guard let self, self.sessionFD >= 0 else {
                    return
                }
                close(self.sessionFD)
                self.sessionFD = -1
            }
            monitor.resume()
            sessionMonitor = monitor
            running = true
            return true
        }
    }

    func stop() {
        queue.sync {
            pendingRefresh?.cancel()
            pendingRefresh = nil
            sessionMonitor?.cancel()
            sessionMonitor = nil
            running = false
        }
    }

    func healthReport() -> SourceHealthReport {
        if running {
            return SourceHealthReport(sourceName: "Codex", issues: [])
        }

        if sessionReader.sessionsDirectoryExists() {
            return SourceHealthReport(
                sourceName: "Codex",
                issues: [
                    SourceErrorMapper.issue(
                        source: "Codex",
                        severity: .info,
                        message: "Real-time Codex file watching is idle. Polling fallback remains active.",
                        recoverySuggestion: nil,
                        isRepairable: false
                    )
                ]
            )
        }

        return SourceHealthReport(sourceName: "Codex", issues: [])
    }

    private func scheduleRefresh(
        knownSessionIDs: @escaping SessionIDProvider,
        eventSink: @escaping EventSink
    ) {
        pendingRefresh?.cancel()
        let workItem = DispatchWorkItem { [source] in
            let snapshot = source.fetchActivity()
            let events = ActivitySnapshotEventAdapter.events(
                from: snapshot,
                knownSessionIDs: knownSessionIDs()
            )
            eventSink(events)
        }
        pendingRefresh = workItem
        queue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}
