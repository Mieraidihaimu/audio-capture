import AppKit

struct SavedTranscript: Identifiable, Hashable {
    let url: URL
    let date: Date
    let source: String
    let preview: String

    var id: String { url.path }
    var session: URL { url.deletingLastPathComponent() }
}

@MainActor
final class TranscriptLibrary: ObservableObject {
    @Published private(set) var entries: [SavedTranscript] = []
    @Published private(set) var problem: String?
    @Published private(set) var notice: String?
    @Published var busySession: URL?

    private let recordings: URL
    private let defaults: UserDefaults
    private let importedSessionsKey = "AudioCapture.importedTranscriptSessions"

    init(recordings: URL, defaults: UserDefaults = .standard) {
        self.recordings = recordings
        self.defaults = defaults
    }

    func rememberSession(_ session: URL) {
        let session = Self.normalizedDirectory(session)
        let hasTranscript = RecordingTrack.allCases.contains {
            FileManager.default.fileExists(atPath: $0.transcriptURL(in: session).path)
        }
        if hasTranscript, session.deletingLastPathComponent() != Self.normalizedDirectory(recordings) {
            var paths = defaults.stringArray(forKey: importedSessionsKey) ?? []
            if !paths.contains(session.path) {
                paths.append(session.path)
                defaults.set(paths, forKey: importedSessionsKey)
            }
        }
        reload()
    }

    func reload() {
        do {
            var sessions: [URL] = []
            if FileManager.default.fileExists(atPath: recordings.path) {
                sessions = try FileManager.default.contentsOfDirectory(
                    at: recordings, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
                ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            }
            sessions += (defaults.stringArray(forKey: importedSessionsKey) ?? []).map { URL(fileURLWithPath: $0) }
            let uniqueSessions = Set(sessions.map(Self.normalizedDirectory))
            var found: [SavedTranscript] = []
            for session in uniqueSessions {
                for track in RecordingTrack.allCases {
                    let url = track.transcriptURL(in: session)
                    guard let values = try? url.resourceValues(
                        forKeys: [.isRegularFileKey, .contentModificationDateKey]
                    ), values.isRegularFile == true else { continue }
                    found.append(SavedTranscript(
                        url: url, date: values.contentModificationDate ?? .distantPast,
                        source: track.title, preview: preview(of: url)
                    ))
                }
            }
            entries = found.sorted {
                $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
            }
            problem = nil
        } catch {
            problem = "Could not load transcripts. \(error.localizedDescription)"
        }
    }

    func content(of entry: SavedTranscript) throws -> String {
        guard entries.contains(where: { $0.id == entry.id }) else {
            throw CaptureError("This transcript is no longer in the library.")
        }
        return try String(contentsOf: entry.url, encoding: .utf8)
    }

    func copy(_ entry: SavedTranscript, to pasteboard: NSPasteboard = .general) {
        do {
            let text = Self.plainText(try content(of: entry))
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw CaptureError("The clipboard could not be updated.")
            }
            problem = nil
            notice = "Transcript copied."
        } catch {
            problem = error.localizedDescription
        }
    }

    func isBusy(_ entry: SavedTranscript) -> Bool {
        guard let busySession else { return false }
        return Self.normalizedDirectory(entry.session) == Self.normalizedDirectory(busySession)
    }

    @discardableResult
    func moveToTrash(_ entry: SavedTranscript) -> URL? {
        guard !isBusy(entry) else {
            problem = "This session is still being recorded or transcribed."
            return nil
        }
        do {
            guard entries.contains(where: { $0.id == entry.id }) else {
                throw CaptureError("This transcript is no longer in the library.")
            }
            var trashed: NSURL?
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &trashed)
            reload()
            notice = "Transcript moved to Trash."
            return trashed as URL?
        } catch {
            problem = "Could not move the transcript to Trash. \(error.localizedDescription)"
            return nil
        }
    }

    func reveal(_ entry: SavedTranscript) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    static func plainText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?m)^\[\d{2,}:\d{2}:\d{2}\][ \t]*"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDirectory(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
    }

    private func preview(of url: URL) -> String {
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 512) ?? Data()
            return Self.plainText(String(decoding: data, as: UTF8.self))
                .replacingOccurrences(of: "\n", with: " ")
        } catch {
            return "Unable to read this transcript."
        }
    }
}
