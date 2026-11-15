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

    /// A feed row's line for a photo or a voice note: «Гласово съобщение, 0:45».
    static func attachment(_ attachment: ChannelPost.Attachment) -> String {
        guard attachment.isVoice else { return VoiceNoteWords.photo }
        guard let ms = attachment.durationMs else { return VoiceNoteWords.voice }
        return "\(VoiceNoteWords.voice), \(VoiceNoteWords.clock(ms: ms))"
    }

    /// After «Без известия» (#601): what it stops, and that it starts with the
    /// next post — a push already on its way still arrives.
    static let mutedNote = "Няма да получавате известия, когато ви споменат или ви отговорят в този канал. Важи от следващата публикация."

    /// «Пиши на ЗК Победа»: the FARM, since a message reaches its owner, not
    /// necessarily the person who posted (#596).
    static func write(_ farm: String?) -> String {
        guard let farm = farm?.trimmingCharacters(in: .whitespacesAndNewlines), !farm.isEmpty else {
            return "Пиши на стопанството"
        }
        return "Пиши на \(farm)"
    }

    /// «За Вас» (owner ruling 2026-11-14, agri-saas `nav-vocabulary.md`):
    /// never «Активност», which names a task's and a machine's tab.
    static let forYou = "За Вас"
    static let forYouEmpty = "Тук ще виждате, когато някой Ви спомене или Ви отговори в канал."
    static let forYouHint = "Споменавания и отговори на Ваши публикации"

    /// What happened, in the channel's name. The server sends a descriptor;
    /// the sentence is ours.
    static func reason(_ item: ChannelsAPI.ActivityItem) -> String {
        switch item.reason {
        case .mention: "Спомена Ви в «\(item.channelNameBg)»"
        case .reply: "Отговор на Ваша публикация в «\(item.channelNameBg)»"
        case .unknown: "В «\(item.channelNameBg)»"
        }
    }

    /// Newest first, each post once: a page boundary can repeat one.
    static func merged(_ older: [ChannelsAPI.ActivityItem], into items: [ChannelsAPI.ActivityItem]) -> [ChannelsAPI.ActivityItem] {
        var seen = Set(items.map(\.id))
        return items + older.filter { seen.insert($0.id).inserted }
    }

    /// The feed's newest page over what is already on screen: the page
    /// replaces its own range, and older pages already read stay below it.
    /// Each post once, by id: the newest page is a moving window, so it
    /// overlaps what was read. `<=` on the boundary's instant, because
    /// posts written by one statement share it (a batch of cards), and an
    /// older page's post at that instant belongs below, not gone.
    static func newest(_ page: [ChannelPost], over shown: [ChannelPost]) -> [ChannelPost] {
        let fresh = Set(page.map(\.id))
        let oldest = page.last?.createdAt ?? .distantFuture
        return page + shown.filter { !fresh.contains($0.id) && $0.createdAt <= oldest }
    }

    // MARK: - Search (#614)

    static let searchPrompt = "Търсене в каналите"
    static let searchJoined = "Моите канали"
    static let searchAll = "Всички канали"
    static let searchTooShort = "Напишете поне 2 букви."
    static let searchNothing = "Няма публикации с тези думи."

    /// Above the results: where it looked, from the server's answer, and
    /// that the order is by date, never "best match" (there is no ranking).
    static func searchHeader(_ scope: ChannelsAPI.SearchScope) -> String {
        switch scope {
        case .joined: "В моите канали, най-новите първо"
        case .all: "Във всички канали, най-новите първо"
        }
    }

    // MARK: - Cards (#629), the web's `channels.card.*`

    static let newsHeading = "Новини"
    static let cardOpen = "Отвори"

    static func newsSource(_ source: String) -> String { "Източник: \(source)" }

    static let listingHeading = "Обяви"
    static let schemeHeading = "Подпомагане"
    static let eventHeading = "Събития"

    /// «Пшеница, 25 т» or «Пшеница, 25 т — 188,65 EUR/т»: two sentences, as
    /// the web's (`channels.card.listing.line` / `.withPrice`), so an absent
    /// price leaves no dangling dash. A price without its currency is no
    /// price anybody can act on, and is left out.
    static func listingLine(_ listing: ChannelPost.Card.Listing) -> String? {
        guard let quantity = decimal(listing.quantityTonnes, fraction: 0...3) else { return nil }
        let commodity = CommodityName.canonical(listing.commodity) ?? listing.commodity
        if let raw = listing.pricePerTonne, let currency = listing.priceCurrency, !currency.isEmpty,
           let price = decimal(raw, fraction: 2...2) {
            return "\(commodity), \(quantity) т — \(price) \(currency)/т"
        }
        return "\(commodity), \(quantity) т"
    }

    /// «Краен срок: 1 декември 2026 г.» from a day key; nil for none, so no
    /// empty «Краен срок:» is ever drawn.
    static func deadline(_ day: String?) -> String? {
        day.flatMap(BgDate.parseISODay).map { "Краен срок: \(BgDate.full($0))" }
    }

    /// «Начало: 15 март, 10:00».
    static func eventStart(_ date: Date?) -> String? {
        date.map { "Начало: \(BgDate.dayMonth($0)), \(BgDate.time($0))" }
    }

    /// A decimal STRING as the reader reads it («1 250,5»), through Decimal,
    /// never a double: tonnes and money keep the digits the server stored.
    static func decimal(_ raw: String, fraction: ClosedRange<Int>) -> String? {
        guard let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = BgDate.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fraction.lowerBound
        formatter.maximumFractionDigits = fraction.upperBound
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }
}
