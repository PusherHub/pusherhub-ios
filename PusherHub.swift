import CoreLocation
import FirebaseCore
import FirebaseMessaging
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import WebKit

/**
 * PusherHub push notification + in-app messaging client for iOS.
 *
 * Required setup (this is the whole "core" tier — everything else on this
 * type is optional), from your app delegate (see [initialize]'s doc for why):
 *
 *   func application(_ application: UIApplication, didFinishLaunchingWithOptions ...) -> Bool {
 *       PusherHub.initialize(appKey: "...", publicKey: "...", baseUrl: "...")
 *       PusherHub.registerDevice()
 *       return true
 *   }
 *
 *   func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
 *       PusherHub.didRegisterForRemoteNotifications(deviceToken: deviceToken)
 *   }
 *
 * A SwiftUI app gets an app delegate with @UIApplicationDelegateAdaptor —
 * see the SDK Integration tab in the PusherHub dashboard for the full
 * snippet, plus the Push Notifications capability and the
 * GoogleService-Info.plist this needs.
 *
 * Pushes travel through Firebase Cloud Messaging, exactly like on Android:
 * PusherHub sends to FCM, and FCM hands the push to Apple (APNs) — which
 * only works once your APNs key (.p8) is uploaded in the Firebase console.
 *
 * This whole SDK is one file (this one) — add it straight to your app
 * target. Its only dependency is Firebase (FirebaseCore + FirebaseMessaging,
 * via Swift Package Manager). iOS 15+.
 *
 * Notification images need one more file, in a target of its own: iOS only
 * shows a push's picture when the app ships a Notification Service
 * Extension to download it. NotificationService.swift, next to this file,
 * is that extension, with its setup steps at the top.
 */
@MainActor
public final class PusherHub {

    fileprivate static let shared = PusherHub()

    private static let anonymousIdKey = "pushhub_anonymous_id_v2"

    // The signed-in user's ID from login() (or registerDevice(externalId:)),
    // kept across restarts until logout(): without it, the next launch's
    // plain registerDevice() quietly turned the device anonymous again.
    private static let externalIdKey = "pushhub_external_id"

    // The last value the backend successfully accepted, so a foreground that
    // found nothing changed costs nothing.
    private static let lastReportedPermissionKey = "pushhub_last_reported_notification_permission"

    // The last FCM token the backend accepted. FCM rotates tokens without a
    // reinstall; reporting the one being replaced lets the backend keep this
    // install as the same device rather than counting a new install plus,
    // later, an uninstall. UserDefaults is wiped on uninstall, which is
    // exactly when a new device row is the right answer.
    private static let lastRegisteredTokenKey = "pushhub_last_registered_token"

    // Matches the window the backend's Realtime tab buckets by. Anything
    // faster just upserts the same minute row for no extra information.
    private static let heartbeatIntervalSeconds: UInt64 = 60

    private var appKey = ""
    private var publicKey = ""
    private var baseUrl = ""
    private var onNotificationClick: ((String) -> Void)?
    private var initialized = false

    // UNUserNotificationCenter and Messaging each take exactly one delegate,
    // and hold it weakly — this object is that delegate, kept alive here.
    private let systemDelegate = PusherHubSystemDelegate()

    private var currentToken: String?
    private var currentExternalId: String?

    // registerDevice() was called, so a token arriving later (or rotating)
    // should be registered. Before that, a token Firebase hands over at
    // startup is only remembered — the app hasn't asked to register yet.
    private var registrationRequested = false

    // The identity a registerDevice() call is waiting to register, until
    // both the FCM token exists and the permission prompt has been answered.
    private var waitingExternalId: String?
    private var waitingCompletions: [() -> Void] = []
    private var permissionPromptPending = false

    // What the user just answered. iOS calls the prompt's completion before
    // its settings store catches up, so for a moment afterwards
    // getNotificationSettings still says notDetermined — a value that can
    // never come back once the user has answered.
    private var promptAnswer: String?

    // Collected once (collectDeviceMetadata) and re-sent on every later
    // registration — the backend's register-device endpoint replaces these
    // fields wholesale, so omitting them on a later call would wipe out
    // whatever was already stored server-side.
    private var deviceModel: String?
    private var deviceBrand: String?
    private var appVersion: String?
    private var language: String?
    private var country: String?
    private var timezone: String?
    private var state: String?
    private var city: String?

    private var locationResolver: PusherHubLocationResolver?

    // Taps on a fresh install the backend doesn't know yet — track-open
    // looks the device up by token. Sent once registration succeeds.
    private var pendingOpens: [(notificationId: String, deepLink: String?)] = []

    private var heartbeatTask: Task<Void, Never>?
    private var lifecycleObserved = false

    private var inAppCheckWaitingForRegistration = false
    private var inAppFetchInFlight = false
    private var inAppQueue: [InAppMessage] = []
    private var inAppShownThisRun: Set<Int> = []
    private var inAppPresenter: PusherHubInAppPresenter?

    private init() {}

    /// The identity currently registered with the backend — nil until [registerDevice] completes.
    public static var externalId: String? { shared.currentExternalId }

    /**
     * Call once, from your app delegate's
     * application(_:didFinishLaunchingWithOptions:) — not later from a
     * SwiftUI view. This makes PusherHub the UNUserNotificationCenter
     * delegate, and iOS only delivers the tap that cold-launched the app to
     * a delegate that was set before launch finished.
     *
     * Also calls FirebaseApp.configure() if your app hasn't already.
     *
     * - Parameter baseUrl: your PusherHub server's API base URL:
     *   "https://pusherhub.com/api" for apps on pusherhub.com — the
     *   dashboard's SDK Integration tab shows it filled in. There's
     *   deliberately no default — a guessed one would silently point at
     *   the wrong server and registerDevice() would fail with nothing
     *   obviously wrong in your own code.
     * - Parameter onNotificationClick: optional — called instead of the
     *   SDK's default behavior (opening the link with UIApplication.open)
     *   when a tapped notification or in-app message carries a deep link.
     */
    public static func initialize(
        appKey: String,
        publicKey: String,
        baseUrl: String,
        onNotificationClick: ((String) -> Void)? = nil
    ) {
        let hub = shared
        hub.appKey = appKey
        hub.publicKey = publicKey
        hub.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        hub.onNotificationClick = onNotificationClick

        guard configureFirebaseIfNeeded() else { return }
        hub.initialized = true

        Messaging.messaging().delegate = hub.systemDelegate
        UNUserNotificationCenter.current().delegate = hub.systemDelegate
        hub.observeAppLifecycle()
    }

    /**
     * Asks for notification permission, gets this device's FCM token, and
     * registers it with the PusherHub backend, as the user last signed in
     * with [login] — remembered across restarts until [logout] — or, with
     * nobody signed in, a persistent anonymous ID generated on first launch
     * (matching OneSignal's default anonymous-subscription behavior).
     * Passing [externalId] here is the same as calling [login] with it.
     *
     * Registration finishes asynchronously (it waits on the permission
     * prompt and on Apple + Firebase for the token), so pass [onComplete] if
     * you need to sequence something after it — e.g.
     * `PusherHub.registerDevice { PusherHub.collectDeviceMetadata() }` —
     * rather than calling that right after this returns.
     */
    public static func registerDevice(externalId: String? = nil, onComplete: (() -> Void)? = nil) {
        let hub = shared
        guard hub.requireInitialized() else { return }

        hub.registrationRequested = true
        if let externalId { hub.rememberExternalId(externalId) }
        hub.waitingExternalId = hub.resolvedExternalId()
        if let onComplete { hub.waitingCompletions.append(onComplete) }
        hub.permissionPromptPending = true

        // Registration deliberately continues on a denial. The device still
        // gets a perfectly valid token, and registering it is the only way
        // the dashboard can report who opted out — nothing is displayed to
        // them until they turn notifications back on.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { @Sendable granted, error in
            if let error {
                log("Notification permission request failed: \(error.localizedDescription)")
            }
            Task { @MainActor in
                if error == nil { shared.promptAnswer = granted ? "granted" : "denied" }
                shared.permissionPromptPending = false
                // Asked for even after a denial — see above. Answered by
                // didRegisterForRemoteNotifications(deviceToken:).
                UIApplication.shared.registerForRemoteNotifications()
                shared.registerWaitingDeviceIfReady()
            }
        }
    }

    /**
     * Forward your app delegate's
     * application(_:didRegisterForRemoteNotificationsWithDeviceToken:) here.
     * Firebase can't issue an FCM token on iOS until it has this APNs token;
     * once it does, the token reaches PusherHub through the Messaging
     * delegate [initialize] installed.
     */
    public static func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard shared.initialized else { return }
        Messaging.messaging().apnsToken = deviceToken
    }

    /**
     * Optional: forward your app delegate's
     * application(_:didFailToRegisterForRemoteNotificationsWithError:) here
     * to get an explanation in the Xcode console instead of a device that
     * silently never registers.
     */
    public static func didFailToRegisterForRemoteNotifications(error: Error) {
        log(
            "Apple refused a push token (\(error.localizedDescription)). Check that the app target has the " +
                "Push Notifications capability and is signed with a team that's in the Apple Developer " +
                "Program — free personal teams can't receive pushes."
        )
    }

    /**
     * Only needed if your app sets its own Messaging delegate after
     * [initialize]: call this from your
     * messaging(_:didReceiveRegistrationToken:) so token refreshes still
     * reach the backend.
     */
    public nonisolated static func handleNewToken(_ token: String) {
        Task { @MainActor in shared.receivedToken(token) }
    }

    /**
     * Only needed if your app sets its own UNUserNotificationCenter delegate
     * after [initialize]: call this from your
     * userNotificationCenter(_:didReceive:withCompletionHandler:). Reports
     * the open (and click-through, if the notification carried a deep link)
     * and opens the deep link. Your own delegate's willPresent then also
     * decides whether pushes show while the app is open — PusherHub's
     * returns [.banner, .list, .sound, .badge].
     */
    public nonisolated static func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }

        // notification_id and deep_link travel in the FCM data payload (set
        // server-side in FcmService), which iOS hands over as top-level
        // userInfo keys. A push without notification_id isn't PusherHub's.
        let userInfo = response.notification.request.content.userInfo
        guard let notificationId = PusherHubJSON.string(userInfo["notification_id"]) else { return }
        let deepLink = PusherHubJSON.nonEmptyString(userInfo["deep_link"])

        Task { @MainActor in shared.notificationOpened(notificationId: notificationId, deepLink: deepLink) }
    }

    /**
     * Aliases this device to a real signed-in user — equivalent to
     * `OneSignal.login(externalId)` — and remembers it on the device, so
     * every later launch registers as this user too, until [logout].
     * Re-registers the same FCM token under the new external_id, so the
     * backend re-links the existing device row instead of creating a
     * duplicate. Called before [registerDevice] has finished, the ID is
     * still remembered and used as soon as it does.
     */
    public static func login(externalId: String) {
        shared.rememberExternalId(externalId)
        // A registration still on its way reads the remembered ID itself.
        guard let token = shared.currentToken, shared.waitingExternalId == nil else { return }
        shared.registerToken(externalId: externalId, token: token)
    }

    /// Reverts this device back to its anonymous identity, and forgets the signed-in user — call this on sign-out.
    public static func logout() {
        UserDefaults.standard.removeObject(forKey: externalIdKey)
        guard let token = shared.currentToken, shared.waitingExternalId == nil else { return }
        shared.registerToken(externalId: shared.anonymousId(), token: token)
    }

    /**
     * Optional: enriches this device's record with model, app version,
     * language, country, and timezone — none of which need a permission.
     * Safe to call any time after [registerDevice] has completed; skips
     * quietly if called before that.
     *
     * Location is off by default, and then no location permission is ever
     * requested — the backend estimates state from the device's IP address
     * instead. Pass [resolveLocation] true for GPS-accurate state and city;
     * that prompts for When In Use location access (add
     * NSLocationWhenInUseUsageDescription to your Info.plist first) and uses
     * Apple's own geocoder, so no extra dependency or API key is needed. A
     * denial only costs the location fields.
     */
    public static func collectDeviceMetadata(resolveLocation: Bool = false) {
        let hub = shared
        guard hub.currentToken != nil else {
            log("collectDeviceMetadata() called before registerDevice() completed.")
            return
        }

        hub.deviceBrand = "Apple"
        hub.deviceModel = deviceModelIdentifier()
        hub.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        // Sent as raw codes ("en", "US") — the backend translates these to
        // full names (LocaleNameResolver), so the SDK doesn't need to ship
        // its own copy of those lookup tables.
        if #available(iOS 16, *) {
            hub.language = Locale.current.language.languageCode?.identifier
            hub.country = Locale.current.region?.identifier
        } else {
            hub.language = Locale.current.languageCode
            hub.country = Locale.current.regionCode
        }
        hub.timezone = TimeZone.current.identifier

        guard resolveLocation else {
            hub.reregister()
            return
        }

        let resolver = PusherHubLocationResolver()
        hub.locationResolver = resolver
        resolver.resolve { state, city, country in
            hub.locationResolver = nil
            if let state { hub.state = state }
            if let city { hub.city = city }
            // Overrides the locale-based guess above with the real,
            // GPS-derived country — a locale's region is just an OS
            // preference and can be flatly wrong.
            if let country { hub.country = country }
            hub.reregister()
        }
    }

    // MARK: - In-app messages

    /**
     * Fetches in-app messages and shows the eligible ones, one after another,
     * styled to match their configured display type (banner/modal/
     * fullscreen/center_popup/bottom_sheet) and content mode (simple/blocks/
     * html) — the same content an admin authors on the PusherHub dashboard.
     * Shown/click/dismiss are tracked automatically.
     *
     * SwiftUI apps can use the `.pusherHubMessageHost()` modifier instead,
     * which calls this on launch and on every return to the foreground. A
     * UIKit app calls this from sceneDidBecomeActive(_:). Calling it before
     * registration has finished is fine — the check runs as soon as it does.
     */
    public static func checkForInAppMessages() {
        shared.checkForInAppMessages()
    }

    /**
     * Fetches the in-app messages currently eligible for this device —
     * active, within their display window, matching this device's audience,
     * and not already shown once (for messages set to display only once).
     * Prefer [checkForInAppMessages] if you just want the SDK's own
     * rendering — call this instead only to build entirely custom UI from
     * the raw data, then call [trackInAppShown]/[trackInAppClick]/
     * [trackInAppDismiss] yourself as appropriate.
     */
    public static func fetchInAppMessages() async -> [InAppMessage] {
        guard let token = shared.currentToken else {
            log("Skipping fetchInAppMessages — no FCM token registered yet.")
            return []
        }
        guard let response = await shared.postJSON("fetch-in-app-messages", ["app_key": shared.appKey, "token": token]) else {
            return []
        }
        let messages = (response["messages"] as? [[String: Any]] ?? []).compactMap(InAppMessage.init(json:))
        log("Fetched \(messages.count) eligible in-app message(s).")
        return messages
    }

    /// Reports that [message] was actually displayed to the user.
    public static func trackInAppShown(_ message: InAppMessage) {
        shared.trackInAppEvent("track-in-app-shown", inAppMessageId: message.id)
    }

    /// Reports that the user tapped [message]'s button or link.
    public static func trackInAppClick(_ message: InAppMessage) {
        shared.trackInAppEvent("track-in-app-click", inAppMessageId: message.id)
    }

    /// Reports that [message] was closed without the user acting on it.
    public static func trackInAppDismiss(_ message: InAppMessage) {
        shared.trackInAppEvent("track-in-app-dismiss", inAppMessageId: message.id)
    }

    private func checkForInAppMessages() {
        guard initialized else { return }
        // The app becomes active long before the first launch's token
        // arrives — remember the request instead of losing this launch.
        guard currentToken != nil, currentExternalId != nil else {
            inAppCheckWaitingForRegistration = true
            return
        }
        guard !inAppFetchInFlight else { return }

        inAppFetchInFlight = true
        Task {
            let messages = await Self.fetchInAppMessages()
            inAppFetchInFlight = false
            let queuedIds = Set(inAppQueue.map(\.id))
            inAppQueue += messages.filter { !inAppShownThisRun.contains($0.id) && !queuedIds.contains($0.id) }
            showNextInAppMessageIfIdle()
        }
    }

    private func showNextInAppMessageIfIdle() {
        guard inAppPresenter == nil, !inAppQueue.isEmpty else { return }
        // Not on screen right now — the queue resumes on the next foreground.
        guard let scene = Self.foregroundWindowScene() else { return }

        let message = inAppQueue.removeFirst()
        inAppShownThisRun.insert(message.id)
        Self.trackInAppShown(message)

        inAppPresenter = PusherHubInAppPresenter(message: message, scene: scene) { [self] outcome in
            inAppPresenter = nil
            switch outcome {
            case .closed:
                // An explicit close (✕, or a close action) is the user
                // answering the message, not ignoring it — matching the
                // Android and React Native SDKs, it isn't a dismiss.
                break
            case .dismissed:
                Self.trackInAppDismiss(message)
            case .opened(let link):
                Self.trackInAppClick(message)
                openDeepLink(link)
            }
            // A beat between messages, which also lets a link that just
            // opened another app take this one out of the foreground first —
            // the next message then waits for the user to come back instead
            // of being counted as shown to nobody.
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                showNextInAppMessageIfIdle()
            }
        }
    }

    private func trackInAppEvent(_ endpoint: String, inAppMessageId: Int) {
        guard let token = currentToken else {
            Self.log("Skipping \(endpoint) — no FCM token registered yet.")
            return
        }
        Task { _ = await postJSON(endpoint, ["app_key": appKey, "in_app_message_id": inAppMessageId, "token": token]) }
    }

    private static func foregroundWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    // MARK: - Registration

    fileprivate func receivedToken(_ token: String) {
        let previous = currentToken
        currentToken = token

        if waitingExternalId != nil {
            registerWaitingDeviceIfReady()
        } else if registrationRequested, previous != token {
            // FCM rotated the token while the app was running.
            registerToken(externalId: resolvedExternalId(), token: token)
        }
    }

    private func registerWaitingDeviceIfReady() {
        guard !permissionPromptPending, waitingExternalId != nil, let token = currentToken else { return }
        // Read now, not when registerDevice() was called: a login() or
        // logout() while the token was on its way counts.
        let externalId = resolvedExternalId()
        let completions = waitingCompletions
        waitingExternalId = nil
        waitingCompletions = []
        registerToken(externalId: externalId, token: token) {
            completions.forEach { $0() }
        }
    }

    /// Re-sends the current identity — after metadata changed, or the permission did.
    private func reregister() {
        guard let token = currentToken else { return }
        registerToken(externalId: resolvedExternalId(), token: token)
    }

    private func registerToken(externalId: String, token: String, completion: (() -> Void)? = nil) {
        Task {
            let permission = await notificationPermissionStatus()
            let defaults = UserDefaults.standard
            let previousToken = defaults.string(forKey: Self.lastRegisteredTokenKey)

            var body: [String: Any] = [
                "app_key": appKey,
                "external_id": externalId,
                "token": token,
                "platform": "ios",
                "notification_permission": permission,
            ]
            // Covers both ways a rotation arrives: the Messaging delegate
            // while running, and a different token on a later launch.
            if let previousToken, previousToken != token {
                body["previous_token"] = previousToken
            }
            let metadata: [String: String?] = [
                "device": deviceModel,
                "brand": deviceBrand,
                "version": appVersion,
                "language": language,
                "country": country,
                "state": state,
                "city": city,
                "timezone": timezone,
            ]
            for case let (key, value?) in metadata {
                body[key] = value
            }

            if await postJSON("register-device", body) != nil {
                currentExternalId = externalId
                // Only cached once the backend has actually taken it —
                // caching a value a failed request never delivered would
                // suppress the retry on the next foreground. The token
                // likewise: if this request failed, the next attempt must
                // still report the old token as the one being replaced.
                defaults.set(permission, forKey: Self.lastReportedPermissionKey)
                defaults.set(token, forKey: Self.lastRegisteredTokenKey)
                Self.log("Device registered successfully (token \(Self.mask(token))).")
                flushPendingOpens()
                if inAppCheckWaitingForRegistration {
                    inAppCheckWaitingForRegistration = false
                    checkForInAppMessages()
                }
            } else {
                Self.log("Failed to register device.")
            }
            completion?()
        }
    }

    /**
     * This device's notification permission as the backend records it:
     * "granted", "denied", or "not_determined". Read fresh from iOS every
     * time, so a user who flips the switch in Settings weeks later is
     * reported accurately.
     */
    private func notificationPermissionStatus() async -> String {
        let status = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
                continuation.resume(returning: PusherHubJSON.permissionValue(settings.authorizationStatus))
            }
        }
        if status == "not_determined", let promptAnswer { return promptAnswer }
        return status
    }

    /**
     * Re-reports the notification permission when it no longer matches what
     * the backend was last told — the user answering the prompt, or turning
     * notifications off (or back on) in Settings, which produces no callback
     * of any kind. A no-op with no network call in the overwhelmingly common
     * case where nothing changed, so it's safe on every foreground.
     */
    private func syncNotificationPermissionIfChanged() {
        guard registrationRequested, !permissionPromptPending, currentToken != nil else { return }
        Task {
            let permission = await notificationPermissionStatus()
            guard permission != UserDefaults.standard.string(forKey: Self.lastReportedPermissionKey) else { return }
            reregister()
        }
    }

    // MARK: - Notification taps

    private func notificationOpened(notificationId: String, deepLink: String?) {
        Self.log("Notification opened: \(notificationId)")
        trackOpen(notificationId: notificationId, deepLink: deepLink)
        if let deepLink {
            openDeepLink(deepLink)
        }
    }

    private func trackOpen(notificationId: String, deepLink: String?) {
        // The token the backend last accepted, saved from an earlier launch —
        // so a tap that cold-launches the app is reported straight away
        // rather than after this launch's registration, which the deep link
        // opening Safari can leave suspended in the background indefinitely.
        guard let token = UserDefaults.standard.string(forKey: Self.lastRegisteredTokenKey) else {
            pendingOpens.append((notificationId, deepLink))
            return
        }
        trackEvent("track-open", notificationId: notificationId, token: token)
        if deepLink != nil {
            trackEvent("track-click", notificationId: notificationId, token: token)
        }
    }

    private func flushPendingOpens() {
        let pending = pendingOpens
        pendingOpens = []
        for open in pending {
            trackOpen(notificationId: open.notificationId, deepLink: open.deepLink)
        }
    }

    private func openDeepLink(_ deepLink: String) {
        if let onNotificationClick {
            onNotificationClick(deepLink)
            return
        }
        guard let url = URL(string: deepLink) else {
            Self.log("Ignoring malformed deep link: \(deepLink)")
            return
        }
        UIApplication.shared.open(url) { opened in
            if !opened { Self.log("No app available to open deep link: \(deepLink)") }
        }
    }

    private func trackEvent(_ endpoint: String, notificationId: String, token: String) {
        let id: Any = Int(notificationId) ?? notificationId
        Task { _ = await postJSON(endpoint, ["app_key": appKey, "notification_id": id, "token": token]) }
    }

    // MARK: - App lifecycle + heartbeat

    /**
     * Catches permission changes made while the app was away — the system
     * prompt, or iOS Settings — and runs the Realtime heartbeat only while
     * the app is on screen, without the host app wiring anything up.
     */
    private func observeAppLifecycle() {
        guard !lifecycleObserved else { return }
        lifecycleObserved = true

        let center = NotificationCenter.default
        center.addObserver(systemDelegate, selector: #selector(PusherHubSystemDelegate.appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(systemDelegate, selector: #selector(PusherHubSystemDelegate.appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)

        // initialize() ran after launch (e.g. from a view) — the first
        // didBecomeActive has already been and gone.
        if UIApplication.shared.applicationState == .active {
            startHeartbeat()
        }
    }

    fileprivate func appDidBecomeActive() {
        syncNotificationPermissionIfChanged()
        startHeartbeat()
        showNextInAppMessageIfIdle()
    }

    fileprivate func appDidEnterBackground() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func startHeartbeat() {
        guard initialized else { return }
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                sendHeartbeat()
                try? await Task.sleep(nanoseconds: Self.heartbeatIntervalSeconds * 1_000_000_000)
            }
        }
    }

    /**
     * Tells the backend this device has the app open right now — the signal
     * behind the dashboard's Realtime tab, and the only thing separating
     * "using the app" from register-device's "launched it at some point".
     * Silently skipped before registration completes; the next tick picks it
     * up once a token exists.
     */
    private func sendHeartbeat() {
        guard let token = currentToken else { return }
        Task { _ = await postJSON("heartbeat", ["app_key": appKey, "token": token]) }
    }

    // MARK: - Helpers

    /// Returns the parsed JSON response body, or nil on any failure (network, non-2xx, bad URL).
    private func postJSON(_ endpoint: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: "\(baseUrl)/\(endpoint)"),
              let payload = try? JSONSerialization.data(withJSONObject: body)
        else {
            Self.log("Couldn't build a request for \(baseUrl)/\(endpoint) — check baseUrl.")
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Without it, a validation failure comes back as a redirect instead
        // of the JSON error that says which field was wrong.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")
        // Harmless against a real server; needed only when baseUrl points at
        // a free-tier ngrok tunnel — without it, ngrok returns an HTML
        // "visit site" warning page instead of forwarding to PusherHub.
        request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")

        // Lets a request that's already in flight finish when the app leaves
        // the foreground — e.g. a deep link that just opened Safari.
        let backgroundTask = PusherHubBackgroundTask(name: "PusherHub \(endpoint)")
        defer { backgroundTask.end() }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                Self.log("\(endpoint) failed: HTTP \(status) \(String(decoding: data, as: UTF8.self))")
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        } catch {
            Self.log("Request to \(endpoint) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func rememberExternalId(_ externalId: String) {
        UserDefaults.standard.set(externalId, forKey: Self.externalIdKey)
    }

    /// Who this device registers as: the signed-in user (see `login`), or the anonymous ID.
    private func resolvedExternalId() -> String {
        UserDefaults.standard.string(forKey: Self.externalIdKey) ?? anonymousId()
    }

    private func anonymousId() -> String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.anonymousIdKey) { return id }

        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.anonymousIdKey)
        return id
    }

    private func requireInitialized() -> Bool {
        if !initialized {
            Self.log("PusherHub.initialize() must be called (and succeed) before this.")
        }
        return initialized
    }

    private static func configureFirebaseIfNeeded() -> Bool {
        if FirebaseApp.app() != nil { return true }
        // FirebaseApp.configure() crashes the app when the plist is missing —
        // checked first so that logs a clear, actionable message instead.
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            log(
                "GoogleService-Info.plist isn't in the app bundle — download it from the Firebase console " +
                    "(Project settings > Your apps > your iOS app), add it to your app target, then rebuild. " +
                    "PusherHub stays disabled until then."
            )
            return false
        }
        FirebaseApp.configure()
        return true
    }

    /// e.g. "iPhone16,1" — the same identifier the Flutter SDK reports on iOS.
    private static func deviceModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Every SDK log line goes through here, and only debug builds print — a
    /// release build logs nothing, so push tokens, payloads, and server
    /// responses never reach the device log of a shipped app.
    fileprivate nonisolated static func log(_ message: String) {
        #if DEBUG
        print("PusherHub: \(message)")
        #endif
    }

    /// Enough of a push token to tell devices apart while debugging, without
    /// writing a usable token to the log.
    private static func mask(_ token: String) -> String {
        token.count <= 8 ? "***" : "\(token.prefix(8))…"
    }
}

/**
 * The object iOS and Firebase actually call back — UNUserNotificationCenter,
 * Messaging, and NotificationCenter all want an NSObject. Every callback
 * hands its values to PusherHub on the main actor.
 */
private final class PusherHubSystemDelegate: NSObject, UNUserNotificationCenterDelegate, MessagingDelegate {

    // Without this, iOS shows nothing for a push that arrives while the app
    // is open — the iOS counterpart of the Android SDK building the
    // notification itself in onMessageReceived().
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    // A tap on a notification — whether the app was open, in the
    // background, or not running at all.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        PusherHub.handleNotificationResponse(response)
        completionHandler()
    }

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        PusherHub.handleNewToken(fcmToken)
    }

    @objc func appDidBecomeActive() {
        MainActor.assumeIsolated { PusherHub.shared.appDidBecomeActive() }
    }

    @objc func appDidEnterBackground() {
        MainActor.assumeIsolated { PusherHub.shared.appDidEnterBackground() }
    }
}

/// A UIApplication background task that's always ended — when the work
/// finishes, or by iOS's expiration handler if it runs out of time first.
@MainActor
private final class PusherHubBackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// MARK: - Location (opt-in)

/**
 * One When In Use location fix, reverse-geocoded to state/city/country with
 * Apple's own geocoder. Only ever created by
 * collectDeviceMetadata(resolveLocation: true). Always calls its completion
 * exactly once — with nils if permission is denied, location is off, the
 * Info.plist key is missing, or nothing arrives within 15 seconds.
 */
@MainActor
private final class PusherHubLocationResolver: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var completion: ((_ state: String?, _ city: String?, _ country: String?) -> Void)?
    private var awaitingAuthorization = false
    private var timeoutTask: Task<Void, Never>?

    func resolve(completion: @escaping (_ state: String?, _ city: String?, _ country: String?) -> Void) {
        self.completion = completion

        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil else {
            PusherHub.log("NSLocationWhenInUseUsageDescription is missing from Info.plist — skipping state/city resolution.")
            finish(nil, nil, nil)
            return
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            PusherHub.log("Timed out waiting for a location fix — skipping state/city resolution.")
            self?.finish(nil, nil, nil)
        }

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        handleAuthorization(manager.authorizationStatus)
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            awaitingAuthorization = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            awaitingAuthorization = false
            manager.requestLocation()
        default:
            PusherHub.log("Location permission denied — skipping state/city resolution.")
            finish(nil, nil, nil)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // Also fires once as soon as the delegate is set — only the
            // answer to a prompt this resolver showed matters here.
            guard awaitingAuthorization, status != .notDetermined else { return }
            handleAuthorization(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        Task { @MainActor in geocode(latitude: latitude, longitude: longitude) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            PusherHub.log("Location lookup failed (\(description)) — skipping state/city resolution.")
            finish(nil, nil, nil)
        }
    }

    private func geocode(latitude: Double, longitude: Double) {
        guard completion != nil else { return }
        geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)) { @Sendable placemarks, _ in
            let placemark = placemarks?.first
            let state = placemark?.administrativeArea
            let city = placemark?.locality
            let country = placemark?.country
            Task { @MainActor [weak self] in self?.finish(state, city, country) }
        }
    }

    private func finish(_ state: String?, _ city: String?, _ country: String?) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        manager.delegate = nil
        completion(state, city, country)
    }
}

// MARK: - In-app message model

/**
 * One in-app message returned by [PusherHub.fetchInAppMessages] — a banner,
 * modal, fullscreen, center-popup, or bottom-sheet message the backend
 * decided this device is currently eligible to see.
 *
 * [contentMode] picks how it's meant to be rendered: "simple" uses
 * [heading]/[body]/[image]/[buttonText] (the fixed fields below); "blocks"
 * uses [blocks], rendered in order; "html" uses [htmlContent], rendered in
 * a web view.
 */
public struct InAppMessage: Identifiable {
    public let id: Int
    public let type: String
    public let contentMode: String
    public let heading: String?
    public let body: String?
    public let blocks: [Block]
    public let htmlContent: String?
    public let image: String?
    public let buttonText: String?
    public let buttonDeepLink: String?
    public let backgroundColor: String?
    public let textColor: String?
    public let showCloseButton: Bool
    public let closeIconUrl: String?
    public let closeIconWidth: Double?
    public let closeIconHeight: Double?
    public let backgroundImage: String?
    public let padding: Double?
    public let dismissAfterSeconds: Int?
    public let customData: [String: Any]?

    /// One element of a "blocks" message: a text, image, or button.
    public struct Block {
        public let type: String
        public let text: String?
        public let color: String?
        public let fontSize: Double?
        public let fontFamily: String?
        public let bold: Bool
        public let italic: Bool
        public let underline: Bool
        public let align: String?
        public let image: String?
        public let backgroundColor: String?
        public let fontColor: String?
        public let cornerRadius: Double?
        /// "open_url", "deep_link", or "close" — nil when tapping does nothing.
        public let clickActionType: String?
        public let clickActionValue: String?
    }

    init?(json: [String: Any]) {
        guard let id = PusherHubJSON.int(json["id"]), let type = json["type"] as? String else { return nil }
        self.id = id
        self.type = type
        contentMode = json["content_mode"] as? String ?? "simple"
        heading = PusherHubJSON.nonEmptyString(json["heading"])
        body = PusherHubJSON.nonEmptyString(json["body"])
        blocks = (json["blocks"] as? [[String: Any]] ?? []).map { Block(json: $0) }
        htmlContent = PusherHubJSON.nonEmptyString(json["html_content"])
        image = PusherHubJSON.nonEmptyString(json["image"])
        buttonText = PusherHubJSON.nonEmptyString(json["button_text"])
        buttonDeepLink = PusherHubJSON.nonEmptyString(json["button_deep_link"])
        backgroundColor = PusherHubJSON.nonEmptyString(json["background_color"])
        textColor = PusherHubJSON.nonEmptyString(json["text_color"])
        showCloseButton = PusherHubJSON.bool(json["show_close_button"]) ?? true
        closeIconUrl = PusherHubJSON.nonEmptyString(json["close_icon_url"])
        closeIconWidth = PusherHubJSON.double(json["close_icon_width"])
        closeIconHeight = PusherHubJSON.double(json["close_icon_height"])
        backgroundImage = PusherHubJSON.nonEmptyString(json["background_image"])
        padding = PusherHubJSON.double(json["padding"])
        dismissAfterSeconds = PusherHubJSON.int(json["dismiss_after_seconds"])
        customData = json["custom_data"] as? [String: Any]
    }
}

extension InAppMessage.Block {
    init(json: [String: Any]) {
        let clickAction = json["click_action"] as? [String: Any]
        type = json["type"] as? String ?? ""
        text = PusherHubJSON.string(json["text"])
        color = PusherHubJSON.nonEmptyString(json["color"])
        fontSize = PusherHubJSON.double(json["font_size"])
        fontFamily = PusherHubJSON.nonEmptyString(json["font_family"])
        bold = PusherHubJSON.bool(json["bold"]) ?? false
        italic = PusherHubJSON.bool(json["italic"]) ?? false
        underline = PusherHubJSON.bool(json["underline"]) ?? false
        align = PusherHubJSON.nonEmptyString(json["align"])
        image = PusherHubJSON.nonEmptyString(json["image"])
        backgroundColor = PusherHubJSON.nonEmptyString(json["background_color"])
        fontColor = PusherHubJSON.nonEmptyString(json["font_color"])
        cornerRadius = PusherHubJSON.double(json["corner_radius"])
        clickActionType = PusherHubJSON.nonEmptyString(clickAction?["type"])
        clickActionValue = PusherHubJSON.nonEmptyString(clickAction?["value"])
    }
}

/// Field values come from admin-authored JSON and FCM payloads — tolerate a
/// number arriving as a string (or the reverse) rather than dropping it.
private enum PusherHubJSON {
    nonisolated static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    nonisolated static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = string(value), !string.isEmpty else { return nil }
        return string
    }

    nonisolated static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    nonisolated static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0) }
    }

    nonisolated static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true"].contains(string.lowercased()) }
        return nil
    }

    // Provisional (quiet delivery) and ephemeral (App Clips) both mean
    // notifications do arrive, which is what the dashboard is asking.
    nonisolated static func permissionValue(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        default: return "granted"
        }
    }
}

// MARK: - In-app message rendering

extension View {
    /**
     * Shows PusherHub in-app messages over your app — checked when this view
     * appears and every time the app returns to the foreground. Optional:
     * an app that never uses this sees no in-app-message behavior at all.
     * Put it on your root view:
     *
     *   WindowGroup { ContentView().pusherHubMessageHost() }
     */
    public func pusherHubMessageHost() -> some View {
        onAppear { PusherHub.checkForInAppMessages() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                PusherHub.checkForInAppMessages()
            }
    }
}

/**
 * Shows one message in its own window above the app's, so it never
 * interferes with the app's own navigation or sheets — the iOS equivalent
 * of the Android SDKs' Dialog. Built with SwiftUI + WebKit only, keeping
 * this SDK's only real dependency Firebase Messaging itself.
 */
@MainActor
private final class PusherHubInAppPresenter {

    enum Outcome {
        /// ✕, a "close" action, or a button with no link.
        case closed
        /// Tapped outside, or timed out — closed without being acted on.
        case dismissed
        case opened(String)
    }

    private var window: UIWindow?
    private var dismissTask: Task<Void, Never>?
    private var finished = false
    private let onFinish: (Outcome) -> Void

    init(message: InAppMessage, scene: UIWindowScene, onFinish: @escaping (Outcome) -> Void) {
        self.onFinish = onFinish

        let host = UIHostingController(
            rootView: PusherHubInAppView(message: message) { [weak self] outcome in self?.finish(outcome) }
        )
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert
        window.backgroundColor = .clear
        window.rootViewController = host
        window.alpha = 0
        window.isHidden = false
        UIView.animate(withDuration: 0.2) { window.alpha = 1 }
        self.window = window

        if let seconds = message.dismissAfterSeconds, seconds > 0 {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(.dismissed)
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        dismissTask?.cancel()

        let window = self.window
        self.window = nil
        UIView.animate(withDuration: 0.2, animations: { window?.alpha = 0 }, completion: { _ in
            window?.isHidden = true
        })
        onFinish(outcome)
    }
}

private struct PusherHubInAppView: View {
    let message: InAppMessage
    let finish: (PusherHubInAppPresenter.Outcome) -> Void

    @State private var htmlHeight: CGFloat = 280

    private var isFullscreen: Bool { message.type == "fullscreen" }
    private var isHTML: Bool { message.contentMode == "html" && message.htmlContent != nil }
    private var textColor: Color { Color(pusherHubHex: message.textColor) ?? Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255) }
    private var cardColor: Color { Color(pusherHubHex: message.backgroundColor) ?? .white }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: alignment) {
                backdrop
                card(maxHeight: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var alignment: Alignment {
        switch message.type {
        case "banner": return .top
        case "bottom_sheet": return .bottom
        default: return .center
        }
    }

    /// Tapping outside the message dismisses it, like the Android SDKs'
    /// dialogs — except fullscreen, which has no outside. A banner leaves
    /// the app undimmed.
    @ViewBuilder
    private var backdrop: some View {
        if isFullscreen {
            cardColor.ignoresSafeArea()
        } else {
            (message.type == "banner" ? Color.clear : Color.black.opacity(0.4))
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { finish(.dismissed) }
        }
    }

    @ViewBuilder
    private func card(maxHeight: CGFloat) -> some View {
        if isHTML {
            htmlCard(maxHeight: maxHeight)
        } else if isFullscreen {
            nativeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundImage.ignoresSafeArea())
                .overlay(alignment: .topTrailing) { closeButton }
        } else {
            nativeContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ZStack { cardColor; backgroundImage })
                .overlay(alignment: .topTrailing) { closeButton }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                .padding(.horizontal, message.type == "banner" || message.type == "bottom_sheet" ? 12 : 24)
                .padding(.vertical, 8)
        }
    }

    // MARK: Native (simple / blocks)

    private var nativeContent: some View {
        VStack(alignment: isFullscreen ? .center : .leading, spacing: 8) {
            if message.contentMode == "blocks" {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            } else {
                simpleContent
            }
        }
        .padding(CGFloat(message.padding ?? 16))
    }

    @ViewBuilder
    private var simpleContent: some View {
        let alignment: TextAlignment = isFullscreen ? .center : .leading

        if let image = message.image {
            remoteImage(image)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 4)
        }
        if let heading = message.heading {
            Text(heading)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(textColor)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
                // Keeps a long heading clear of the ✕ drawn over its corner.
                .padding(.trailing, message.showCloseButton && !isFullscreen ? 20 : 0)
        }
        if let body = message.body {
            Text(body)
                .font(.system(size: 14))
                .foregroundColor(textColor.opacity(0.85))
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let buttonText = message.buttonText {
            Button {
                if let link = message.buttonDeepLink {
                    finish(.opened(link))
                } else {
                    finish(.closed)
                }
            } label: {
                Text(buttonText)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func blockView(_ block: InAppMessage.Block) -> some View {
        switch block.type {
        case "text":
            let alignment = blockAlignment(block.align)
            styledText(block)
                .multilineTextAlignment(alignment.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: alignment.frame)
                .contentShape(Rectangle())
                .onTapGesture { handleBlockTap(block) }
        case "image":
            if let image = block.image {
                remoteImage(image)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { handleBlockTap(block) }
            }
        case "button":
            Button {
                handleBlockTap(block)
            } label: {
                Text(block.text ?? "Button")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(pusherHubHex: block.fontColor) ?? .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(pusherHubHex: block.backgroundColor) ?? Color(red: 5 / 255, green: 27 / 255, blue: 44 / 255))
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(block.cornerRadius ?? 8), style: .continuous))
            }
            .buttonStyle(.plain)
        default:
            EmptyView()
        }
    }

    private func styledText(_ block: InAppMessage.Block) -> Text {
        let size = CGFloat(block.fontSize ?? 16)
        let font: Font = block.fontFamily.map { Font.custom($0, size: size) } ?? .system(size: size)
        let color: Color = Color(pusherHubHex: block.color) ?? textColor
        var text = Text(block.text ?? "").font(font).foregroundColor(color)
        if block.bold { text = text.bold() }
        if block.italic { text = text.italic() }
        if block.underline { text = text.underline() }
        return text
    }

    /// Blocks default to centered, matching the dashboard preview and the
    /// Android/React Native SDKs.
    private func blockAlignment(_ align: String?) -> (text: TextAlignment, frame: Alignment) {
        switch align {
        case "left": return (.leading, .leading)
        case "right": return (.trailing, .trailing)
        default: return (.center, .center)
        }
    }

    private func handleBlockTap(_ block: InAppMessage.Block) {
        switch block.clickActionType {
        case "open_url", "deep_link":
            if let value = block.clickActionValue { finish(.opened(value)) }
        case "close":
            finish(.closed)
        default:
            break
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if message.showCloseButton {
            Button {
                finish(.closed)
            } label: {
                if let iconUrl = message.closeIconUrl, let url = URL(string: iconUrl) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: CGFloat(message.closeIconWidth ?? 18), height: CGFloat(message.closeIconHeight ?? 18))
                } else {
                    // Its own small disc, so it stays legible where it sits
                    // over an image rather than the card's color.
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(textColor)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(cardColor.opacity(0.85)))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Close")
        }
    }

    /// The whole image at its natural aspect ratio — no crop, no
    /// letterboxing — matching the dashboard preview's <img class="w-full">.
    private func remoteImage(_ urlString: String) -> some View {
        AsyncImage(url: URL(string: urlString)) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Color.clear.frame(height: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Painted behind the content rather than taking up space in the flow,
    /// so the card stays the size of its content — like the preview's CSS
    /// background-image.
    @ViewBuilder
    private var backgroundImage: some View {
        if let image = message.backgroundImage, let url = URL(string: image) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.clear
            }
        }
    }

    // MARK: HTML

    @ViewBuilder
    private func htmlCard(maxHeight: CGFloat) -> some View {
        let web = PusherHubHTMLView(html: message.htmlContent ?? "") { event in
            switch event {
            case .close: finish(.closed)
            case .openUrl(let url): finish(.opened(url))
            case .trackClick: PusherHub.trackInAppClick(message)
            case .contentHeight(let height): htmlHeight = height
            }
        }

        if isFullscreen {
            web
        } else {
            // Sized to the page's own height (reported from inside it), up
            // to most of the screen — taller pages scroll.
            web
                .frame(height: min(htmlHeight, maxHeight * 0.85))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, message.type == "banner" || message.type == "bottom_sheet" ? 12 : 24)
                .padding(.vertical, 8)
        }
    }
}

/**
 * Renders "html" content mode, with the same `PushHubIamApi` JavaScript
 * bridge documented on the dashboard's HTML in-app message editor —
 * `PushHubIamApi.close()`, `.openUrl(url)`, and `.trackClick()` all work
 * exactly as an admin authoring HTML content there expects. A plain link
 * tapped inside the message counts as openUrl too, rather than navigating
 * the little web view itself.
 */
private struct PusherHubHTMLView: UIViewRepresentable {

    enum Event {
        case close
        case openUrl(String)
        case trackClick
        case contentHeight(CGFloat)
    }

    let html: String
    let onEvent: (Event) -> Void

    private static let handlerName = "pusherHub"

    // Injected before the page's own scripts run, so even inline script can
    // call PushHubIamApi straight away.
    private static let bridgeScript = """
        (function () {
          function post(action, value) {
            window.webkit.messageHandlers.\(handlerName).postMessage({ action: action, value: value === undefined ? null : value });
          }
          window.PushHubIamApi = {
            close: function () { post('close'); },
            openUrl: function (url) { post('open_url', String(url)); },
            trackClick: function () { post('track_click'); }
          };
          // Measures the content rather than <body>: HTML without a doctype
          // renders in quirks mode, where <body> is always at least as tall
          // as the web view, so it could only ever grow the message.
          function reportHeight() {
            var body = document.body;
            if (!body) return;
            var range = document.createRange();
            range.selectNodeContents(body);
            var style = getComputedStyle(body);
            var last = body.lastElementChild;
            var height = range.getBoundingClientRect().bottom + window.scrollY
              + parseFloat(style.paddingBottom) + parseFloat(style.marginBottom)
              + (last ? parseFloat(getComputedStyle(last).marginBottom) : 0);
            post('height', Math.ceil(height));
          }
          window.addEventListener('load', function () {
            reportHeight();
            if (window.ResizeObserver) new ResizeObserver(reportHeight).observe(document.body);
          });
        })();
        """

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        contentController.add(context.coordinator, name: Self.handlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(Self.withViewport(html), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
    }

    /// Without a viewport tag, WebKit lays the page out 980pt wide and
    /// shrinks it to fit, so an admin's 16px text comes out tiny.
    private static func withViewport(_ html: String) -> String {
        guard html.range(of: "name=\"viewport\"", options: .caseInsensitive) == nil,
              html.range(of: "name='viewport'", options: .caseInsensitive) == nil
        else { return html }
        return "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" + html
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onEvent: (Event) -> Void

        init(onEvent: @escaping (Event) -> Void) {
            self.onEvent = onEvent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "close":
                onEvent(.close)
            case "open_url":
                if let url = PusherHubJSON.nonEmptyString(body["value"]) { onEvent(.openUrl(url)) }
            case "track_click":
                onEvent(.trackClick)
            case "height":
                if let height = PusherHubJSON.double(body["value"]), height > 0 { onEvent(.contentHeight(CGFloat(height))) }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            onEvent(.openUrl(url.absoluteString))
        }
    }
}

extension Color {
    /// "#RRGGBB" or "#AARRGGBB" (Android's order, which the dashboard's
    /// colors follow); nil for anything else, so callers fall back to a default.
    fileprivate init?(pusherHubHex hex: String?) {
        guard let hex else { return nil }
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }

        let alpha = digits.count == 8 ? Double((value >> 24) & 0xFF) / 255 : 1
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: alpha
        )
    }
}
