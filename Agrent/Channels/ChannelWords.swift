import Foundation

/// What «Канали» says, pure so tests pin it.
enum ChannelWords {
    /// The groups, by the KEY PREFIX, never `kind`: an input channel is a
    /// `TOPIC` with an `input:` key, and a future non-input topic must not
    /// land under it (#2986 §2). An unknown prefix goes to «Други».
    static func group(_ key: String) -> String {
        switch key.split(separator: ":").first.map(String.init) {
        case "crop": "Култури"
        case "oblast": "Области"
        case "input": "Торове, препарати и горива"
        default: "Други"
        }
    }

    static let groupOrder = ["Култури", "Области", "Торове, препарати и горива", "Други"]

    /// Joined channels first, then the directory by group, each by name.
    static func sections(_ channels: [Channel]) -> [(title: String, channels: [Channel])] {
        var result: [(String, [Channel])] = []
        let mine = channels.filter(\.joined).sorted { $0.nameBg < $1.nameBg }
        if !mine.isEmpty { result.append(("Моите канали", mine)) }
        let rest = channels.filter { !$0.joined }
        for title in groupOrder {
            let these = rest.filter { group($0.key) == title }.sorted { $0.nameBg < $1.nameBg }
            if !these.isEmpty { result.append((title, these)) }
        }
        return result
    }

    /// «34 членове», «1 член».
    static func members(_ count: Int?) -> String? {
        count.map { Plural.bg($0, "член", "членове") }
    }

    /// «Иван Петров, ЗК Победа», or as much of it as the server sent (agri-saas
    /// #2989: the person's published profile name, often absent at first, and
    /// the farm recorded when the post was written, absent on older posts);
    /// with neither, «Член на канала»; the reader's own post, «Вие». Never
    /// the internal id.
    /// Whichever halves the server sent, joined as the web joins them; nil
    /// when neither (agri-saas #2989: four states, three normal), so the row
    /// shows its time alone. Never an id.
    static func author(_ post: ChannelPost, me: String? = nil) -> String? {
        if let me, post.authorUserId == me { return "Вие" }
        func kept(_ part: String?) -> String? {
            part.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let name = kept(post.author?.displayName)
        let farm = kept(post.author?.farmName)
        switch (name, farm) {
        case let (name?, farm?): return nameAndFarm(name, farm)
        case let (name?, nil): return name
        case let (nil, farm?): return farm
        case (nil, nil): return nil
        }
    }

    /// The web's `channels.authorNameAndFarm`, «{name}, {farm}».
    static func nameAndFarm(_ name: String, _ farm: String) -> String { "\(name), \(farm)" }

    // ── The display-name prompt: the web's `channels.displayName*`, word for
    // word (agri-saas #2989). The hint is the consent: it says where the name
    // will be seen, so it is never shortened.
    static let nameTitle = "Как да Ви наричаме?"
    static let nameHint = "Името Ви ще се вижда от други стопанства в каналите, заедно с името на стопанството Ви."
    static let nameLabel = "Име за показване"
    static let namePlaceholder = "напр. Иван Петров"
    static let nameSave = "Запази"
    static let nameSkip = "Не сега"
    static let nameSaved = "Името е запазено."
    static let nameFailed = "Името не можа да бъде запазено."
    static let nameSkipped = "Публикациите Ви ще се подписват само с името на стопанството."
    /// The server's cap, counted after markup is stripped; the phone counts
    /// plain characters, which is never more.
    static let nameMax = 60

    /// The one sentence a removed, retracted or hidden post shows: the three
    /// are one state by design, so nothing here tells them apart.
    static let deleted = "Публикацията не е налична."

    /// «Въпрос», «Решен въпрос», or nothing for a plain post.
    static func badge(_ post: ChannelPost) -> String? {
        guard post.isQuestion else { return nil }
        return post.resolvedAt == nil ? "Въпрос" : "Решен въпрос"
    }

    /// «3 отговора», nothing for none.
    static func replies(_ count: Int) -> String? {
        count > 0 ? Plural.bg(count, "отговор", "отговора") : nil
    }

    /// «1240 / 4000» once a draft passes 3600, so the limit is seen before it bites.
    static func counter(_ text: String) -> String? {
        text.count > ChannelsAPI.maxBody - 400 ? "\(text.count) / \(ChannelsAPI.maxBody)" : nil
    }
}
