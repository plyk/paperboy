import SwiftUI

struct FeedEditor: View {
    private enum Check {
        case idle, running, ok(String), failed(String)
    }

    @EnvironmentObject private var store: FeedStore
    @Environment(\.dismiss) private var dismiss
    @State private var feed: Feed
    @State private var tagsText: String
    @State private var check = Check.idle

    init(feed: Feed) {
        _feed = State(initialValue: feed)
        _tagsText = State(initialValue: feed.tags.joined(separator: ", "))
    }

    private var isNew: Bool { !store.feeds.contains { $0.id == feed.id } }

    private var suggestedTags: [String] {
        let current = Set(Tags.parse(tagsText).map { $0.lowercased() })
        return store.allTags.filter { $0 != Tags.untagged && !current.contains($0.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(isNew ? "Új hírforrás" : "Hírforrás szerkesztése") {
                    HStack {
                        TextField("Feed URL", text: $feed.url, prompt: Text("https://…/rss"))
                        Button("Ellenőrzés") { Task { await verify() } }
                            .disabled(feed.url.isEmpty)
                    }
                    checkStatus
                    TextField("Név", text: $feed.name, prompt: Text("Az ellenőrzés kitölti"))
                    TextField("Címkék", text: $tagsText, prompt: Text("vesszővel elválasztva, pl. Tech, Napi"))
                    if !suggestedTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(suggestedTags, id: \.self) { tag in
                                    Button("+ \(tag)") { addTag(tag) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    Toggle(isOn: $feed.fetchFullText) {
                        Text("Teljes cikk letöltése a weboldalról")
                        Text("Akkor kell, ha a hírcsatorna csak rövid kivonatot ad. Fizetős cikkeknél a kivonat marad.")
                    }
                    Toggle("Aktív", isOn: $feed.isEnabled)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Mégse", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Mentés") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(feed.url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 500)
    }

    @ViewBuilder
    private var checkStatus: some View {
        switch check {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func verify() async {
        check = .running
        do {
            let parsed = try await FeedFetcher.fetch(feed.url)
            if feed.name.trimmingCharacters(in: .whitespaces).isEmpty, let title = parsed.title {
                feed.name = title
            }
            // Rövid kivonatok esetén (új forrásnál) bekapcsoljuk a teljes szöveg letöltését.
            let lengths = parsed.items.map { $0.html.strippingTags.count }
            let average = lengths.isEmpty ? 0 : lengths.reduce(0, +) / lengths.count
            if isNew, !lengths.isEmpty, average < 600 {
                feed.fetchFullText = true
                check = .ok("Működik, \(parsed.items.count) cikk található. Csak kivonatokat tartalmaz, ezért bekapcsoltam a teljes cikk letöltését.")
            } else {
                check = .ok("Működik, \(parsed.items.count) cikk található")
            }
        } catch {
            check = .failed(error.localizedDescription)
        }
    }

    private func addTag(_ tag: String) {
        tagsText = (Tags.parse(tagsText) + [tag]).joined(separator: ", ")
    }

    private func save() {
        feed.url = feed.url.trimmingCharacters(in: .whitespaces)
        feed.name = feed.name.trimmingCharacters(in: .whitespaces)
        if feed.name.isEmpty {
            feed.name = URL(string: feed.url)?.host() ?? feed.url
        }
        feed.tags = Tags.parse(tagsText)
        store.upsert(feed)
        dismiss()
    }
}
