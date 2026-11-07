import SwiftUI

/// متصفح مجلدات الـ NAS (FTP) لاختيار مكان حفظ المستندات
struct FolderPicker: View {
    let cfg: NASConfig
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    @State private var store: RemoteStore?
    @State private var path: [String] = []
    @State private var folders: [String] = []
    @State private var loading = false
    @State private var error = ""
    @State private var showNew = false
    @State private var newName = ""

    private var current: String { path.joined(separator: "/") }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Image(systemName: "externaldrive")
                        Text("/" + current)
                            .lineLimit(2)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .foregroundColor(.secondary)
                    if !path.isEmpty {
                        Button {
                            path.removeLast()
                            Task { await load() }
                        } label: {
                            Label("رجوع للمجلد الأعلى", systemImage: "arrow.turn.left.up")
                        }
                    }
                }

                Section(header: Text("المجلدات")) {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if folders.isEmpty && error.isEmpty {
                        Text("لا توجد مجلدات هنا").foregroundColor(.secondary)
                    }
                    ForEach(folders, id: \.self) { f in
                        Button {
                            path.append(f)
                            Task { await load() }
                        } label: {
                            HStack {
                                Label(f, systemImage: "folder.fill")
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.left")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(loading)
                    }
                }

                Section {
                    Button {
                        newName = "Salha-Scan"
                        showNew = true
                    } label: {
                        Label("مجلد جديد هنا", systemImage: "folder.badge.plus")
                    }
                    .disabled(loading || store == nil)
                }

                if !error.isEmpty {
                    Section { Text(error).foregroundColor(.red).font(.footnote) }
                }

                Section(footer: Text("المستندات تُحفظ كملفات PDF داخل المجلد الذي تختاره.")) {
                    Button {
                        selection = current
                        dismiss()
                    } label: {
                        Label("اختيار هذا المجلد", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    }
                    .disabled(loading || store == nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("اختر مكان النسخ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
            }
            .alert("مجلد جديد", isPresented: $showNew) {
                TextField("اسم المجلد", text: $newName)
                Button("إنشاء") { Task { await create() } }
                Button("إلغاء", role: .cancel) {}
            }
            .task {
                let start = cfg.cleanFolder
                path = start.isEmpty ? [] : start.split(separator: "/").map(String.init)
                await load()
                if !error.isEmpty && !path.isEmpty {   // المجلد المحفوظ غير موجود → نبدأ من الجذر
                    path = []
                    await load()
                }
            }
            .onDisappear {
                let s = store
                Task { await s?.close() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        loading = true
        error = ""
        defer { loading = false }
        do {
            if store == nil { store = try await Remote.open(cfg) }
            guard let store = store else { return }
            folders = try await store.listDirs(current)
                .filter { !$0.hasPrefix(".") && !$0.hasPrefix("$") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            folders = []
            self.error = NASError.describe(error)
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !name.isEmpty, let store = store else { return }
        let target = current.isEmpty ? name : current + "/" + name
        do {
            await store.makeDir(target)
            path.append(name)
            await load()
        } catch {
            self.error = NASError.describe(error)
        }
    }
}
