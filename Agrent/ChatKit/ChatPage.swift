/// One page of a conversation as the server sends it (agrent-ios#196): the
/// END of a run of messages, oldest first, and the cursor to the page before
/// it.
///
/// A page may carry more — Борса's carries the thread's header, recomputed on
/// every page — which the surface reads from `ChatEngine.latestPage`; the
/// engine reads only these two.
protocol ChatPage: Sendable {
    associatedtype Message: ChatMessage

    var messages: [Message] { get }

    /// The `before` for the previous page; null once the start of the
    /// conversation is on this page.
    var olderCursor: String? { get }
}
