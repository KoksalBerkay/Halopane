import UniformTypeIdentifiers
import SwiftUI
import WebKit
import SpatialMath
import AdapterTracking

/// Reorder, regroup and remove Home page shortcuts.
struct HomeShortcutOrganizer: View {
    @ObservedObject var store: HomeShortcutStore
    @State private var draft: HomeShortcut?
    @State private var reset = false

    var body: some View {
        List {
            ForEach(store.groups, id: \.self) { group in
                let items = store.items.filter { $0.group == group }
                Section(group) {
                    ForEach(items) { item in
                        Button {
                            draft = item
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                Text(URL(string: item.url)?.host ?? item.url).font(.caption).foregroundStyle(
                                    .secondary)
                            }
                        }.foregroundStyle(.primary)
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    store.remove(item.id)
                                }
                            }
                    }
                    .onMove { from, to in
                        store.move(group: group, from: from, to: to)
                    }
                    .onDelete { indices in
                        store.remove(indices.map { items[$0].id })
                    }
                }
            }
            Section {
                Button("Add shortcut", systemImage: "plus") {
                    draft = HomeShortcut.blank
                }
                if store.canUndo {
                    Button("Undo last change") {
                        store.undo()
                    }
                }
                Button("Restore defaults", role: .destructive) {
                    reset = true
                }
            }
            if let error = store.error {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Home shortcuts")
        .toolbar {
            EditButton()
        }
        .sheet(item: $draft) { item in
            HomeShortcutEditor(store: store, item: item)
        }
        .confirmationDialog(
            "Replace your shortcuts with the defaults?", isPresented: $reset, titleVisibility: .visible
        ) {
            Button("Restore defaults", role: .destructive) {
                store.restoreDefaults()
            }
        }
    }
}

/// Add or edit one Home page shortcut.
private struct HomeShortcutEditor: View {
    @ObservedObject var store: HomeShortcutStore
    @Environment(\.dismiss) private var dismiss
    @State var item: HomeShortcut
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $item.name)
                TextField("Website address", text: $item.url).keyboardType(.URL).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Group (existing or new)", text: $item.group)
                if !store.groups.isEmpty {
                    Menu("Choose an existing group") {
                        ForEach(store.groups, id: \.self) { group in
                            Button(group) {
                                item.group = group
                            }
                        }
                    }
                }
                if invalid {
                    Text("Enter a valid website address and a name.").foregroundStyle(.red)
                }
            }
            .navigationTitle("Home shortcut")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if store.update(item) {
                            dismiss()
                        } else {
                            invalid = true
                        }
                    }
                }
            }
        }
    }
}
