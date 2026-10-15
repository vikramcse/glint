import GlintCore
import SwiftUI

/// The toolbar's sort menu: a field, then a direction worded for that field ("Newest First").
struct SortMenu: View {
    @Binding var sort: ResultSort
    /// Relevance only means something for search results.
    let offersRelevance: Bool

    var body: some View {
        Menu {
            Picker(selection: field) {
                ForEach(fields, id: \.self) { field in
                    Text(field.title).tag(field)
                }
            } label: {
                Text("Sort By")
            }
            .pickerStyle(.inline)
            if sort.field != .relevance {
                Picker(selection: $sort.ascending) {
                    ForEach([sort.field.defaultAscending, !sort.field.defaultAscending], id: \.self) { ascending in
                        Text(sort.field.directionTitle(ascending: ascending)).tag(ascending)
                    }
                } label: {
                    Text("Order")
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help(Text("Change the order of results"))
    }

    private var fields: [ResultSort.Field] {
        offersRelevance ? ResultSort.Field.allCases : ResultSort.Field.allCases.filter { $0 != .relevance }
    }

    /// Picking a field starts it in its natural direction.
    private var field: Binding<ResultSort.Field> {
        Binding {
            sort.field
        } set: {
            if $0 != sort.field { sort = ResultSort(field: $0) }
        }
    }
}

extension ResultSort.Field {
    var title: String {
        switch self {
        case .relevance: String(localized: "Relevance", comment: "Sort field")
        case .modified: String(localized: "Date Modified", comment: "Sort field")
        case .name: String(localized: "Name", comment: "Sort field")
        case .size: String(localized: "Size", comment: "Sort field")
        case .kind: String(localized: "Kind", comment: "Sort field")
        case .duration: String(localized: "Length", comment: "Sort field: length of audio and video")
        }
    }

    func directionTitle(ascending: Bool) -> String {
        switch (self, ascending) {
        case (.modified, true): String(localized: "Oldest First", comment: "Sort direction")
        case (.modified, false), (.relevance, _): String(localized: "Newest First", comment: "Sort direction")
        case (.size, true): String(localized: "Smallest First", comment: "Sort direction")
        case (.size, false): String(localized: "Largest First", comment: "Sort direction")
        case (.duration, true): String(localized: "Shortest First", comment: "Sort direction")
        case (.duration, false): String(localized: "Longest First", comment: "Sort direction")
        case (.name, true), (.kind, true): String(localized: "A to Z", comment: "Sort direction")
        case (.name, false), (.kind, false): String(localized: "Z to A", comment: "Sort direction")
        }
    }
}
