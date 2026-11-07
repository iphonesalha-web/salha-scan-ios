import SwiftUI
import UIKit

/// إعدادات الـ NAS داخل «صالحة سكان»
struct NASSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cfg = NASConfig.load()
    @State private var password = NASConfig.load().password
    @State private var busy = false
    @State private var testResult = ""
    @State private var showFolders = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("الـ FRITZ!Box"),
                        footer: Text("الاتصال عبر FTP. المستخدم وكلمة المرور هما حساب FRITZ!NAS.")) {
                    field("العنوان", $cfg.host)
                    field("اسم المستخدم", $cfg.username)
                    SecureField("كلمة المرور", text: $password, prompt: Text("كلمة المرور"))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .environment(\.layoutDirection, .leftToRight)
                }

                Section(header: Text("مكان حفظ المستندات")) {
                    Button {
                        save()
                        showFolders = true
                    } label: {
                        HStack {
                            Label("المجلد", systemImage: "folder")
                            Spacer()
                            Text("/" + cfg.cleanFolder)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                    .disabled(busy || password.isEmpty)
                }

                Section(footer: Text(testResult)) {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("اختبار الاتصال", systemImage: "antenna.radiowaves.left.and.right")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy)
                }
            }
            .sheet(isPresented: $showFolders) {
                FolderPicker(cfg: cfg, selection: $cfg.folder)
                    .environment(\.layoutDirection, .rightToLeft)
            }
            .navigationTitle("الـ NAS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("حفظ") { save(); dismiss() } }
            }
            .onAppear { LocalNetworkPrompt.shared.trigger() }
        }
        .navigationViewStyle(.stack)
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .environment(\.layoutDirection, .leftToRight)
    }

    private func save() {
        cfg.save()
        cfg.password = password
    }

    private func test() async {
        save()
        if password.isEmpty { testResult = "اكتب كلمة المرور أولاً."; return }
        busy = true
        defer { busy = false }
        do {
            let store = try await Remote.open(cfg)
            _ = try? await store.listDirs(cfg.cleanFolder)
            await store.close()
            testResult = "✓ الاتصال ناجح"
        } catch {
            testResult = "✗ " + NASError.describe(error)
        }
    }
}

/// رفع ملف PDF إلى الـ NAS
enum NASUploader {
    static func info() -> [String: Any] {
        let cfg = NASConfig.load()
        return ["configured": cfg.isComplete, "folder": cfg.cleanFolder, "host": cfg.host]
    }

    @MainActor
    static func upload(name: String, data: Data, oldName: String?) async -> [String: Any] {
        let cfg = NASConfig.load()
        guard cfg.isComplete else { return ["error": "الـ NAS غير مُعد"] }

        // وقت إضافي إن خرج المستخدم من التطبيق أثناء الرفع
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "nas-upload") {
            UIApplication.shared.endBackgroundTask(bg)
            bg = .invalid
        }
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        do { try data.write(to: tmp) } catch { return ["error": "تعذّر تجهيز الملف"] }
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let store = try await Remote.open(cfg)
            let dir = cfg.cleanFolder
            var cur = ""
            for part in dir.split(separator: "/") {
                cur = cur.isEmpty ? String(part) : cur + "/" + part
                await store.makeDir(cur)
            }
            let remote = dir.isEmpty ? name : dir + "/" + name
            let part = remote + ".part"
            do {
                await store.remove(part)
                try await store.upload(tmp, to: part, progress: { _ in })
                await store.remove(remote)
                try await store.move(part, to: remote)
                if let o = oldName, !o.isEmpty, o != name {
                    await store.remove(dir.isEmpty ? o : dir + "/" + o)
                }
            } catch {
                await store.close()
                throw error
            }
            await store.close()
            return ["ok": true]
        } catch {
            return ["error": NASError.describe(error)]
        }
    }
}
