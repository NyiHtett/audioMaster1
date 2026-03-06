import Foundation
import SwiftUI
import Combine

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var runtime = RecordingRuntimeSnapshot()
    @Published var sessions: [RecordingSessionDTO] = []
    @Published var selectedSession: RecordingSessionDTO?
    @Published var selectedSegments: [TranscriptionSegmentDTO] = []

    @Published var searchQuery: String = ""
    @Published var selectedQuality: RecordingQualityPreset = .balanced
    @Published var apiToken: String = ""
    @Published var showingTokenSheet = false

    private let audio = AudioActor.shared
    private let data = DataManagerActor.shared
    private let tokenVault = TokenVaultActor.shared

    private var sessionOffset = 0
    private let pageSize = 40
    private var hasMoreSessions = true
    private var lastObservedTotalSegments = 0
    private var lastObservedTranscribedSegments = 0

    // start live listeners and bootstrap initial data when the view appears
    func start() {
        Task {
            let stream = await audio.runtimeUpdates()
            for await snapshot in stream {
                self.runtime = snapshot
                await self.handleRuntimeSnapshot(snapshot)
            }
        }

        Task {
            await loadInitialSessions()
            apiToken = await tokenVault.loadElevenLabsToken() ?? ""
        }
    }

    // start recording with the quality selected from UI
    func startRecording() {
        Task {
            await audio.startRecording(sessionName: nil, quality: selectedQuality)
            await loadInitialSessions()
        }
    }

    func stopRecording() {
        Task {
            await audio.stopRecording()
            await loadInitialSessions()
        }
    }

    func pauseRecording() {
        Task { await audio.pauseRecording() }
    }

    func resumeRecording() {
        Task { await audio.resumeRecording() }
    }

    func saveToken() {
        Task {
            do {
                try await tokenVault.saveElevenLabsToken(apiToken.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                runtime.lastError = "Token save failed: \(error.localizedDescription)"
            }
        }
    }

    // reload from first page so search and selection stay in sync
    func loadInitialSessions() async {
        sessionOffset = 0
        hasMoreSessions = true
        do {
            let loaded = try await data.fetchSessions(limit: pageSize, offset: sessionOffset, search: searchQuery)
            sessions = loaded
            sessionOffset = loaded.count
            hasMoreSessions = loaded.count == pageSize
            if let selected = selectedSession,
               loaded.contains(where: { $0.id == selected.id }) {
                try await loadSegments(for: selected.id)
            } else if let first = loaded.first {
                selectedSession = first
                try await loadSegments(for: first.id)
            } else {
                selectedSession = nil
                selectedSegments = []
            }
        } catch {
            runtime.lastError = error.localizedDescription
        }
    }

    // pagination hook for the session list (called on last row)
    func loadMoreSessionsIfNeeded(current item: RecordingSessionDTO) {
        guard hasMoreSessions, let last = sessions.last, item.id == last.id else { return }
        Task {
            do {
                let next = try await data.fetchSessions(limit: pageSize, offset: sessionOffset, search: searchQuery)
                sessions.append(contentsOf: next)
                sessionOffset += next.count
                hasMoreSessions = next.count == pageSize
            } catch {
                runtime.lastError = error.localizedDescription
            }
        }
    }

    func selectSession(_ session: RecordingSessionDTO) {
        selectedSession = session
        Task {
            do {
                try await loadSegments(for: session.id)
            } catch {
                runtime.lastError = error.localizedDescription
            }
        }
    }

    func deleteSession(_ session: RecordingSessionDTO) {
        Task {
            do {
                try await data.deleteSession(id: session.id)
                if selectedSession?.id == session.id {
                    selectedSession = nil
                    selectedSegments = []
                }
                await loadInitialSessions()
            } catch {
                runtime.lastError = error.localizedDescription
            }
        }
    }

    func refreshSearch() {
        Task { await loadInitialSessions() }
    }

    // fetch all visible segments for one selected session
    private func loadSegments(for sessionID: UUID) async throws {
        selectedSegments = try await data.fetchSegments(sessionID: sessionID, limit: 300, offset: 0)
    }

    // only refresh UI when segment counters actually changed
    private func handleRuntimeSnapshot(_ snapshot: RecordingRuntimeSnapshot) async {
        guard let selected = selectedSession,
              snapshot.sessionID == selected.id else { return }

        let didProgressChange =
            snapshot.totalSegments != lastObservedTotalSegments ||
            snapshot.transcribedSegments != lastObservedTranscribedSegments

        guard didProgressChange else { return }

        lastObservedTotalSegments = snapshot.totalSegments
        lastObservedTranscribedSegments = snapshot.transcribedSegments

        do {
            try await loadSegments(for: selected.id)
            // Refresh current selected session stats in list.
            await loadInitialSessions()
        } catch {
            runtime.lastError = error.localizedDescription
        }
    }
}
