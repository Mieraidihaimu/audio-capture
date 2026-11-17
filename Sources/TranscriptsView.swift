import SwiftUI

struct TranscriptsView: View {
    @ObservedObject var library: TranscriptLibrary
    @Binding var selection: SavedTranscript.ID?
    @Binding var filter: TranscriptFilter
    @State private var confirmsBulkTrash = false
    @State private var pendingTrash: Set<SavedTranscript.ID> = []

    private var visibleEntries: [SavedTranscript] { library.transcripts(matching: filter) }

    private var selected: SavedTranscript? {
        visibleEntries.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleEntries, selection: $selection) { entry in
                HStack(alignment: .top, spacing: 8) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TranscriptStarButton(library: library, entry: entry)
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
                if visibleEntries.isEmpty {
                    ContentUnavailableView(
                        filter.emptyTitle,
                        systemImage: filter == .starred ? "star" : "text.bubble"
                    )
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    TranscriptFilterMenu(filter: $filter)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button("Trash Unstarred…", systemImage: "trash", role: .destructive) {
                    pendingTrash = Set(library.trashableUnstarred.map(\.id))
                    confirmsBulkTrash = !pendingTrash.isEmpty
                }
                .disabled(library.trashableUnstarred.isEmpty)
                .frame(maxWidth: .infinity)
                .padding(12)
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
        .alert("Move unstarred transcripts to the Trash?", isPresented: $confirmsBulkTrash, presenting: pendingTrash) { ids in
            Button("Move to Trash", role: .destructive) { library.moveUnstarredToTrash(confirmedIDs: ids) }
            Button("Cancel", role: .cancel) { }
        } message: { ids in
            Text("\(ids.count) \(ids.count == 1 ? "transcript" : "transcripts") will move to the Trash. Audio recordings will stay in place.")
        }
        .onAppear(perform: library.reload)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.reload()
        }
        .onChange(of: visibleEntries.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0 == selection }) { selection = ids.first }
        }
    }
}

struct TranscriptFilterMenu: View {
    @Binding var filter: TranscriptFilter

    var body: some View {
        Menu {
            Picker("Show Transcripts", selection: $filter) {
                ForEach(TranscriptFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(filter == .all ? "Filter" : filter.rawValue, systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("Filter transcripts")
    }
}

struct TranscriptStarButton: View {
    @ObservedObject var library: TranscriptLibrary
    let entry: SavedTranscript

    var body: some View {
        let isStarred = library.isStarred(entry)
        let title = isStarred ? "Unstar Transcript" : "Star Transcript"
        Button {
            library.toggleStar(entry)
        } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
                .foregroundStyle(isStarred ? Color.orange : Color.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .help(title)
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
