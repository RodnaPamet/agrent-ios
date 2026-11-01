import Foundation
import Sentry

/// Crashes, freezes and slow screens to Sentry (#494, owner 2026-11-01:
/// "Sentry, like the web"), in the same organisation as agri-saas and in its
/// EU region.
///
/// ── Nothing personal, and not linked to the account ──
///
/// As App Store Connect declares it (Crash, Performance and Other Diagnostic
/// Data; not linked; not tracking) and as agri-saas `sentry-data-collection.ts`
/// holds the web to. So every channel that would carry a person's data is
/// switched off, not filtered after the fact:
/// - no user, no IP, no device name (`sendDefaultPii`);
/// - no screenshot and no view hierarchy, which would show farm records;
/// - no request breadcrumbs, request spans or failed-request events, whose
///   URLs name the farm and its records, and no file I/O spans, whose paths
///   do the same;
/// - no tap breadcrumbs, which name the control a person pressed (usage is
///   #493's, on our own server).
///
/// And `scrub` runs over every event and breadcrumb anyway, so a channel a
/// later Sentry release turns on by default still sends no user, request or
/// URL.
///
/// ── Off unless the build carries a DSN ──
///
/// Only TestFlight's archive does (the `SENTRY_DSN` secret, through
/// `AGRENT_SENTRY_DSN`). Development, CI, the unit tests and the screenshot
/// harness build with it empty, and an empty or unexpanded value starts
/// nothing (`dsn(from:)`).
enum CrashReporting {
    /// The Info.plist key project.yml fills from `AGRENT_SENTRY_DSN`.
    static let infoKey = "AgrentSentryDSN"

    /// Before anything else in `AgrentApp.init`, so a crash in the app's own
    /// start-up is reported too.
    static func start(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        guard let dsn = dsn(from: info) else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            // The person: none of it.
            options.sendDefaultPii = false
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            // Requests and files: their addresses name the farm.
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            // Taps: usage is #493's.
            options.enableUserInteractionTracing = false
            // What it is for. Freezes from two seconds, as a tractor cab is
            // where a stuck screen gets noticed; Apple's own diagnostics
            // (MetricKit: hangs, CPU and disk exceptions) folded in. Slow
            // screens sampled as the web samples its traces (2%).
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2
            options.enableWatchdogTerminationTracking = true
            options.enableMetricKit = true
            options.enableMetricKitRawPayload = false
            options.tracesSampleRate = 0.02
            options.beforeSend = { scrub($0) }
            options.beforeBreadcrumb = { keeps($0.category, data: $0.data) ? $0 : nil }
        }
    }

    /// The DSN when the build carries one: an https address, so an empty
    /// value or an unexpanded `$(AGRENT_SENTRY_DSN)` starts nothing.
    static func dsn(from info: [String: Any]) -> String? {
        guard let value = (info[infoKey] as? String)?.trimmingCharacters(in: .whitespaces),
              value.hasPrefix("https://"), URL(string: value)?.host?.isEmpty == false else { return nil }
        return value
    }

    /// Every event, whatever produced it: no user, no request, no device
    /// name, and only the breadcrumbs `keeps` lets through.
    static func scrub(_ event: Event) -> Event {
        event.user = nil
        event.request = nil
        event.serverName = nil
        event.breadcrumbs = event.breadcrumbs?.filter { keeps($0.category, data: $0.data) }
        return event
    }

    /// The breadcrumb categories that carry a person's data: requests, taps
    /// and the console.
    static let droppedCategories: Set = ["http", "xhr", "fetch", "touch", "ui.click", "console", "query"]

    /// And the fields that do, whatever the category: an address names the
    /// farm and its records, and a screen's title can be a parcel's name.
    static let droppedFields: Set = ["url", "path", "request", "to", "from", "title"]

    static func keeps(_ category: String, data: [String: Any]?) -> Bool {
        guard !droppedCategories.contains(category) else { return false }
        return !(data?.keys.contains { droppedFields.contains($0.lowercased()) } ?? false)
    }
}
