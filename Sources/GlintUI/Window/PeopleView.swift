import GlintCore
import SwiftUI

/// Everyone found in the library's photos and videos, as a grid of faces.
struct PeopleView: View {
    let people: PeopleModel
    let onOpen: (PersonID) -> Void
    let onRename: (PersonSummary) -> Void
    let onError: (String) -> Void

    var body: some View {
        Group {
            if people.people.isEmpty {
                if people.hasLoaded { emptyState }
            } else {
                ScrollView {
                    if people.needsRescan { rescanBanner.padding([.horizontal, .top]) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 18)], spacing: 20) {
                        ForEach(people.people) { person in
                            PersonCell(person: person)
                                .contentShape(.rect)
                                .onTapGesture { onOpen(person.id) }
                                .contextMenu {
                                    Button(person.name == nil ? "Add Name…" : "Rename…") { onRename(person) }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No People Yet", systemImage: "person.2")
        } description: {
            Text("People appear here as photos and videos are indexed, once someone is in at least two of them.")
        } actions: {
            if people.needsRescan { rescanButton }
        }
    }

    private var rescanBanner: some View {
        HStack {
            Label("Photos and videos indexed before this update haven’t been checked for faces.", systemImage: "person.crop.rectangle")
                .foregroundStyle(.secondary)
            Spacer()
            rescanButton
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private var rescanButton: some View {
        Button("Find People") {
            Task {
                do {
                    try await people.rescan()
                } catch {
                    onError(String(localized: "Couldn’t start looking for people: \(error.localizedDescription)"))
                }
            }
        }
        .help(Text("Index photos and videos again to find the faces in them"))
    }
}

struct PersonCell: View {
    let person: PersonSummary

    var body: some View {
        VStack(spacing: 6) {
            FaceImage(url: person.faceThumbnailURL)
                .aspectRatio(1, contentMode: .fit)
            Text(person.name ?? String(localized: "Add Name"))
                .font(.callout)
                .foregroundStyle(person.name == nil ? .secondary : .primary)
                .lineLimit(1)
            Text("\(person.fileCount) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A person's face in a circle, or a silhouette while it loads or when there is none.
struct FaceImage: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill").resizable().scaledToFit().padding(28).foregroundStyle(.secondary)
                }
            }
            .clipShape(.circle)
            .overlay(Circle().strokeBorder(.quaternary))
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url else { return }
                if let cached = ThumbnailCache.shared.cached(url) {
                    image = cached
                } else {
                    image = await ThumbnailCache.shared.load(url)
                }
            }
    }
}
