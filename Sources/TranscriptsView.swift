import SwiftUI

struct TranscriptsView: View {
    @ObservedObject var library: TranscriptLibrary
    @State private var selection: SavedTranscript.ID?

    private var selected: SavedTranscript? {
        library.entries.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(library.entries, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(entry.source).fontWeight(.medium)
                        if library.isBusy(entry) {
                            Image(systemName: "waveform").foregroundStyle(.secondary)
                        }
                    }
                    Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.preview)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 5)
                .tag(entry.id)
                .contextMenu {
                    Button("Copy Text") { library.copy(entry) }
                    Button("Show in Finder") { library.reveal(entry) }
                    Divider()
                    Button("Move to Trash", role: .destructive) { library.moveToTrash(entry) }
                        .disabled(library.isBusy(entry))
                }
            }
            .navigationTitle("Transcripts")
            .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
            .overlay {
                if library.entries.isEmpty {
                    ContentUnavailableView(
                        "No transcripts yet", systemImage: "text.bubble",
                        description: Text("Dictate or transcribe a recording to add it here.")
                    )
                }
            }
        } detail: {
            if let selected {
                TranscriptDetail(entry: selected, library: library)
            } else {
                ContentUnavailableView("Select a transcript", systemImage: "text.alignleft")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise", action: library.reload)
                if let selected {
                    Button("Copy Text", systemImage: "doc.on.doc") { library.copy(selected) }
                    Button("Show in Finder", systemImage: "folder") { library.reveal(selected) }
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        library.moveToTrash(selected)
                    }
                    .disabled(library.isBusy(selected))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = library.problem ?? library.notice {
                HStack {
                    Text(message).font(.caption)
                        .foregroundStyle(library.problem == nil ? Color.secondary : .orange)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.bar)
            }
        }
        .frame(minWidth: 740, minHeight: 450)
        .onAppear {
            library.reload()
            if selection == nil { selection = library.entries.first?.id }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.reload()
        }
        .onChange(of: library.entries) { _, entries in
            if !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id }
        }
    }
}

private struct TranscriptDetail: View {
    let entry: SavedTranscript
    @ObservedObject var library: TranscriptLibrary
    @State private var content = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.source).font(.title2.weight(.semibold))
                    Text(entry.date, format: .dateTime.year().month(.wide).day().hour().minute())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Divider()
                Text(content)
                    .font(.body).lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: entry) {
            do {
                content = try library.content(of: entry)
            } catch {
                content = "Could not open this transcript. \(error.localizedDescription)"
            }
        }
    }
}
