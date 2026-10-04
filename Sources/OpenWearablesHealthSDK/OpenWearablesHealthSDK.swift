import Foundation
import UIKit
import HealthKit
import BackgroundTasks
import Network

/// Controls which log messages the SDK emits.
///
/// - `none`:   No logs at all (neither console nor `onLog` callback).
/// - `always`: Logs are always emitted (console + callback).
/// - `debug`:  Logs are emitted only in debug builds (the default).
@objc public enum OWLogLevel: Int {
    case none = 0
    case always = 1
    case debug = 2
}

/// Distinguishes a genuine authentication failure from a transient network error
/// during token refresh so callers can decide whether to sign the user out.
internal enum TokenRefreshResult {
    /// Token was refreshed successfully.
    case success
    /// Refresh token is invalid — the server explicitly rejected it (HTTP 401/403).
    case authFailure
    /// Could not reach the server (timeout, DNS, connectivity, 5xx, etc.).
    case networkError
}

/// Main entry point for the Open Wearables Health SDK.
/// Use `OpenWearablesHealthSDK.shared` to access the singleton instance.
///
/// This SDK handles:
/// - HealthKit authorization and data collection
/// - Background sync with streaming uploads
/// - Resumable sync sessions
/// - Dual authentication (token-based with auto-refresh, or API key)
/// - Persistent outbox for failed uploads
/// - Network and device lock monitoring
public final class OpenWearablesHealthSDK: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    /// Shared singleton instance.
    public static let shared = OpenWearablesHealthSDK()
    
    // Fork-Stand statt Upstream-Stand: Backend und Logs sollen sehen, dass hier der
    // Fork (Upstream 0.15.0 + Mirror-Dedupe + GPS-Strecken + Adoption) läuft, und
    // keinen reinen Upstream-Stand vorgetäuscht bekommen.
    internal static let sdkVersion = "0.15.0-ow.1"

    // MARK: - Public Callbacks
    
    /// Called whenever the SDK logs a message. Set this to receive log output.
    public var onLog: ((String) -> Void)?
    
    /// Current log level. Default is `.debug` (logs only in debug builds).
    public var logLevel: OWLogLevel = .debug
    
    /// Called when an authentication error occurs (e.g., 401 Unauthorized).
    /// Parameters: (statusCode: Int, message: String)
    public var onAuthError: ((Int, String) -> Void)?
    
    /// Fork: called once for every sync run, with its typed outcome. Fires for runs the
    /// SDK starts itself (observers, SDK background tasks, unlock, network) as well as for
    /// runs the host app starts, and always on the main queue, before the `completion` of
    /// the call that started the run. A run that could not start because another one holds
    /// the slot reports `.skippedBusy`.
    public var onRunCompleted: ((SyncOutcome) -> Void)?

    // MARK: - Configuration State
    internal var host: String?
    
    // MARK: - User State (loaded from Keychain)
    internal var userId: String? { OpenWearablesHealthSdkKeychain.getUserId() }
    internal var accessToken: String? { OpenWearablesHealthSdkKeychain.getAccessToken() }
    internal var refreshToken: String? { OpenWearablesHealthSdkKeychain.getRefreshToken() }
    internal var apiKey: String? { OpenWearablesHealthSdkKeychain.getApiKey() }
    
    // Token refresh state
    private var isRefreshingToken = false
    private let tokenRefreshLock = NSLock()
    private var tokenRefreshCallbacks: [(TokenRefreshResult) -> Void] = []
    
    // MARK: - Auth Helpers
    
    internal var isApiKeyAuth: Bool {
        return apiKey != nil && accessToken == nil
    }
    
    internal var authCredential: String? {
        return accessToken ?? apiKey
    }
    
    internal var hasAuth: Bool {
        return authCredential != nil
    }
    
    private func bearerValue(_ token: String) -> String {
        return token.hasPrefix("Bearer ") ? token : "Bearer \(token)"
    }
    
    internal func applyAuth(to request: inout URLRequest) {
        if let token = accessToken {
            request.setValue(bearerValue(token), forHTTPHeaderField: "Authorization")
        } else if let key = apiKey {
            request.setValue(key, forHTTPHeaderField: "X-Open-Wearables-API-Key")
        }
    }
    
    internal func applyAuth(to request: inout URLRequest, credential: String) {
        if isApiKeyAuth {
            request.setValue(credential, forHTTPHeaderField: "X-Open-Wearables-API-Key")
        } else {
            request.setValue(bearerValue(credential), forHTTPHeaderField: "Authorization")
        }
    }
    
    // MARK: - Request Building
    
    /// Identifies the SDK build, OS and device class to server-side access logs.
    /// `UIDevice` is main-thread bound, so the OS version comes from `ProcessInfo`
    /// and the model from `uname`, both of which are safe to read from any thread.
    internal static let userAgent: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return "OpenWearablesHealthSDK/\(sdkVersion) (iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion); \(model))"
    }()
    
    /// Builds a JSON POST carrying the headers every SDK request must have.
    ///
    /// The SDK version lives in the body as well, but a server cannot read it from a
    /// truncated request - which is exactly the case that needs attribution.
    /// `requestId` is reused across a 401 retry so both attempts can be correlated.
    internal func buildRequest(
        url: URL,
        method: String = "POST",
        credential: String?,
        requestId: String,
        outboxItemId: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(OpenWearablesHealthSDK.sdkVersion, forHTTPHeaderField: "X-Open-Wearables-SDK-Version")
        request.setValue("ios", forHTTPHeaderField: "X-Open-Wearables-SDK-Platform")
        request.setValue(OpenWearablesHealthSDK.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        if let outboxItemId = outboxItemId {
            request.setValue(outboxItemId, forHTTPHeaderField: "X-Open-Wearables-Outbox-Item")
        }
        if let credential = credential {
            applyAuth(to: &request, credential: credential)
        }
        return request
    }
    
    // MARK: - HealthKit State
    internal let healthStore = HKHealthStore()
    internal var session: URLSession!
    internal var foregroundSession: URLSession!
    internal var trackedTypes: [HKSampleType] = []
    internal var backgroundChunkSize: Int = 100
    internal var recordsPerChunk: Int = 2000
    
    // Debouncing
    private var pendingSyncWorkItem: DispatchWorkItem?
    private let syncDebounceQueue = DispatchQueue(label: "health_sync_debounce")
    private var observerBgTask: UIBackgroundTaskIdentifier = .invalid
    
    // Sync flags
    internal var isInitialSyncInProgress = false
    private var isSyncing: Bool = false
    private let syncLock = NSLock()
    internal var fullSyncStartTime: Date?
    
    /// Identifies a single sync run. A cancelled run is never "un-cancelled": the next
    /// run gets a new generation, so a late callback from the previous one is discarded
    /// by its own checkpoint instead of racing a shared boolean.
    private var syncGeneration: Int = 0
    /// Every generation up to and including this one has been cancelled.
    private var cancelledGeneration: Int = 0
    private var cancelRequestedAt: Date?

    /// Fork (review HI-01): held while a run checks its generation and writes (`commitIfCurrent`),
    /// and while the generation changes (`beginSyncRun`, `cancelSync`). A takeover therefore
    /// waits for a write that is already running, and a write after the takeover is refused:
    /// check and write are one step, not a check followed by a write (TOCTOU). Recursive, so a
    /// write that calls back into the SDK on the same thread cannot deadlock. Lock order: this
    /// one before `syncLock`, never the other way round.
    private let commitLock = NSRecursiveLock()

    // Fork: the sync slot has a lease. A run that gives no sign of life for
    // `SyncLease.leaseDuration` loses the slot to the next caller, also when nobody ever
    // cancelled it. The 60 s takeover after `cancelSync()` from 0.15 lives on in the
    // lease rules of `SyncLease`. Guarded by `syncLock` like `isSyncing`.
    private var leaseDeadlineStorage: Date?

    /// Fork: clock of the lease, replaceable in tests.
    internal var now: () -> Date = Date.init

    /// Fork: when the current run loses the slot unless it gives a sign of life. `nil` when
    /// no run holds the slot. Internal because the lanes runner reads it from another file.
    internal var leaseDeadline: Date? {
        syncLock.lock()
        defer { syncLock.unlock() }
        return leaseDeadlineStorage
    }

    /// Whether a sync run currently owns the slot. Stays true after `cancelSync()`
    /// until that run unwinds, so a second loop cannot start on the same SyncState.
    internal var isSyncInProgress: Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        return isSyncing
    }
    
    /// What apps should show as "syncing". False as soon as cancel is requested,
    /// even if the outgoing run has not reached a checkpoint yet.
    internal var isSyncingVisible: Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        return isSyncing && cancelRequestedAt == nil
    }
    
    // Uploads owned by the sync path, keyed by request id. Tracked so cancellation can
    // target them instead of every task on the shared foreground session (which also
    // carries token refreshes and telemetry).
    private var syncUploadTasks: [String: URLSessionTask] = [:]
    /// Fork (review ME-02): one heartbeat per tracked upload of a run, keyed like `syncUploadTasks`.
    private var syncUploadHeartbeats: [String: UploadProgressHeartbeat] = [:]
    private let syncUploadTasksLock = NSLock()
    
    /// Why the last upload cancellation was issued, so an `NSURLErrorCancelled` in the
    /// logs can be attributed instead of guessed.
    private var lastCancellation: (reason: String, at: Date)?
    
    /// Bumped on sign-in / sign-out so a late outbox callback cannot apply anchors
    /// or `fullDone` for a user who has already left.
    private var sessionEpoch: Int = 0
    
    internal func bumpSessionEpoch() {
        syncLock.lock()
        sessionEpoch += 1
        syncLock.unlock()
    }
    
    internal func currentSessionEpoch() -> Int {
        syncLock.lock()
        defer { syncLock.unlock() }
        return sessionEpoch
    }
    
    // Fork (Plan 05-08): the running two-lane cycle, as far as other triggers need it, and the
    // triggers that arrived while it was ending. Both guarded by `lanesCycleLock`. The types
    // and the functions that use them live in `Lanes/LanesRunner.swift`.
    internal var activeLanesCycle: ActiveLanesCycle?
    internal var deferredLanesTriggers: [DeferredLanesTrigger] = []
    internal let lanesCycleLock = NSLock()
    
    // Fork (Plan 05-08): the completion handlers of observer queries that wait for a live round
    // (observer contract, `Lanes/LaneControls.swift`), and the one-shot flag of the debug hook
    // that makes the next live fetch hang (scenario "hanging lease"; the flag exists in debug
    // builds only).
    internal let observerCompletions = ObserverCompletions()
    #if DEBUG
    internal var hangNextLiveFetchArmed = false
    internal let hangFlagLock = NSLock()
    #endif
    
    // Fork: statistics per run, filled by the places that know why a run ended and
    // read once when the outcome is built. See `Lanes/RunStats.swift`.
    internal var runStatsByGeneration: [Int: RunStats] = [:]
    internal let runStatsLock = NSLock()
    
    // Fork: run and wake journal plus the device-state caches that feed it. The accessors
    // live in `Lanes/RunJournal.swift`. `UIApplication` may only be read on the main
    // queue, so runs on other threads read these caches instead.
    internal var runJournalCache: RunJournal?
    internal let runJournalLock = NSLock()
    internal let stateCacheLock = NSLock()
    internal var protectedDataAvailableValue: Bool?
    internal var backgroundRefreshStatusValue: String?
    internal var backgroundRefreshObserver: NSObjectProtocol?
    
    // Outbox retry state
    internal var isRetryingOutbox = false
    internal let outboxRetryLock = NSLock()
    
    // Network monitoring
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "health_sync_network_monitor")
    private var wasDisconnected = false
    
    // Protected data monitoring
    private var protectedDataObserver: NSObjectProtocol?
    private var protectedDataUnavailableObserver: NSObjectProtocol?
    internal var pendingSyncAfterUnlock = false
    
    // Foreground monitoring (resume sync when app returns to foreground)
    private var foregroundObserver: NSObjectProtocol?

    // Per-user state (anchors)
    // `var` als Testnaht, wie `stateDirectoryOverride`: Tests setzen eine eigene Suite,
    // damit sie nie in die echte Suite `com.openwearables.healthsdk.state` schreiben.
    // Produktion ändert den Wert nie. Achtung: `lazy var mirrorDedupe` hält die Suite,
    // die beim ersten Zugriff galt; ein späteres Umsetzen erreicht sie nicht mehr.
    internal var defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.state") ?? .standard

    /// Overrides the root the SDK keeps its on-disk state under. Production leaves this
    /// nil and resolves to Application Support; tests point it at a temporary directory
    /// so a test run cannot read or delete the state of the app hosting it.
    internal var stateDirectoryOverride: URL?

    /// Root for `outboxDir()` and `syncStateDir()`.
    internal func stateBaseDirectory() -> URL {
        if let stateDirectoryOverride = stateDirectoryOverride {
            return stateDirectoryOverride
        }
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return base ?? FileManager.default.temporaryDirectory
    }

    /// Remembers which body measurements were already delivered, so a copy
    /// written by a second app does not count as a second measurement.
    internal lazy var mirrorDedupe = MirrorDedupeLedger(storage: defaults)

    // Observer queries
    internal var activeObserverQueries: [HKObserverQuery] = []

    // Background session
    internal let bgSessionId = "com.openwearables.healthsdk.upload.session"

    // BGTask identifiers
    internal let refreshTaskId  = "com.openwearables.healthsdk.task.refresh"
    internal let processTaskId  = "com.openwearables.healthsdk.task.process"

    internal static var bgCompletionHandler: (() -> Void)?

    // Background response data buffer. The background session is created with
    // `delegateQueue: nil`, so URLSession serializes the delegate callbacks that
    // mutate this and no external locking is needed.
    internal var backgroundDataBuffer: [Int: Data] = [:]

    // MARK: - API Endpoints
    
    internal var apiBaseUrl: String? {
        guard let host = host ?? OpenWearablesHealthSdkKeychain.getHost() else { return nil }
        let h = host.hasSuffix("/") ? String(host.dropLast()) : host
        return "\(h)/api/v1"
    }
    
    internal var syncEndpoint: URL? {
        guard let userId = userId else { return nil }
        guard let base = apiBaseUrl else { return nil }
        return URL(string: "\(base)/sdk/users/\(userId)/sync")
    }

    /// Connection resource deleted on sign out. Unlike `syncEndpoint` and
    /// `logsEndpoint` this one is not under `/sdk`.
    internal var disconnectEndpoint: URL? {
        guard let userId = userId else { return nil }
        guard let base = apiBaseUrl else { return nil }
        return URL(string: "\(base)/users/\(userId)/connections/apple")
    }

    /// Token-refresh URL. An absolute `tokenRefreshURL` from `configure` wins;
    /// otherwise `{host}/api/v1/token/refresh`. A stored override that is not a
    /// valid `http(s)` URL is treated as missing rather than falling back to the
    /// sync host (that would silently refresh against the wrong server).
    internal var tokenRefreshEndpoint: URL? {
        if let custom = OpenWearablesHealthSdkKeychain.getCustomRefreshUrl(), !custom.isEmpty {
            return Self.absoluteHTTPURL(from: custom)
        }
        guard let base = apiBaseUrl else { return nil }
        return URL(string: "\(base)/token/refresh")
    }

    internal static func absoluteHTTPURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
    
    // MARK: - Init
    
    private override init() {
        super.init()
        // Fresh BGTask processes never see `configure` before the first refresh.
        self.host = OpenWearablesHealthSdkKeychain.getHost()
        
        let bgCfg = URLSessionConfiguration.background(withIdentifier: bgSessionId)
        bgCfg.isDiscretionary = false
        bgCfg.waitsForConnectivity = true
        // Carries the drain of pre-0.14 outbox leftovers and nothing else. Serialize
        // them (one connection at a time instead of a parallel burst) and cap how long
        // a stale batch may linger in the system (default resource timeout is 7 days).
        bgCfg.httpMaximumConnectionsPerHost = 1
        bgCfg.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: bgCfg, delegate: self, delegateQueue: nil)
        
        let fgCfg = URLSessionConfiguration.default
        fgCfg.timeoutIntervalForRequest = 120
        fgCfg.timeoutIntervalForResource = 600
        fgCfg.waitsForConnectivity = false
        self.foregroundSession = URLSession(configuration: fgCfg, delegate: nil, delegateQueue: OperationQueue.main)

        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { [weak self] task in
                self?.handleAppRefresh(task: task as! BGAppRefreshTask)
            }
            BGTaskScheduler.shared.register(forTaskWithIdentifier: processTaskId, using: nil) { [weak self] task in
                self?.handleProcessing(task: task as! BGProcessingTask)
            }
        }
    }
    
    // MARK: - Public API: Background Completion Handler
    
    /// Set the background URL session completion handler (call from AppDelegate).
    ///
    /// Only reached while draining outbox items written by an SDK version before 0.14.
    /// Sync uploads run on the foreground session and an interrupted round is rebuilt
    /// from HealthKit, so on an install that never wrote an outbox item the background
    /// session stays idle and this handler is never invoked.
    public static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        bgCompletionHandler = handler
    }
    
    // MARK: - Public API: Configure
    
    /// Initialize the SDK with the backend host URL.
    /// This also restores previously tracked types and auto-resumes sync if it was active.
    ///
    /// - Parameters:
    ///   - host: Base host for the data-sync API (`{host}/api/v1/...`).
    ///   - tokenRefreshURL: Optional absolute URL used to refresh the access
    ///     token (`POST {"refresh_token"}` → `{"access_token","refresh_token"}`).
    ///     When omitted or empty, the SDK uses `{host}/api/v1/token/refresh`
    ///     and clears any previously stored override. Pass this on every
    ///     `configure` call when the auth/mint server is not the sync host —
    ///     the value is persisted so a background `BGTask` in a fresh process
    ///     can refresh before `configure` runs again.
    public func configure(host: String, tokenRefreshURL: String? = nil) {
        OpenWearablesHealthSdkKeychain.clearKeychainIfReinstalled()
        
        self.host = host
        OpenWearablesHealthSdkKeychain.saveHost(host)
        OpenWearablesHealthSdkKeychain.saveCustomRefreshUrl(tokenRefreshURL)
        
        if let storedTypes = OpenWearablesHealthSdkKeychain.getTrackedTypes() {
            self.trackedTypes = mapTypesFromStrings(storedTypes)
            logMessage("Restored \(trackedTypes.count) tracked types")
        }

        if let tokenRefreshURL = OpenWearablesHealthSdkKeychain.getCustomRefreshUrl() {
            logMessage("Configured: host=\(host), tokenRefreshURL=\(tokenRefreshURL)")
        } else {
            logMessage("Configured: host=\(host)")
        }

        // Fork: Altzustand übernehmen, bevor `autoRestoreSync` und die ersten Auslöser
        // `fullDone` lesen. Sonst eskaliert der erste Lauf nach dem Update zum Neu-Export.
        adoptLegacyStateIfNeeded()
        
        // Fork: Sperrzustand und Hintergrundaktualisierung lesen, einen Start im
        // Hintergrund im Journal festhalten (Befund 10).
        observeDeviceStateAndLaunch()

        if OpenWearablesHealthSdkKeychain.isSyncActive() && OpenWearablesHealthSdkKeychain.hasSession() && !trackedTypes.isEmpty {
            logMessage("Auto-restoring background sync...")
            DispatchQueue.main.async { [weak self] in
                self?.autoRestoreSync()
            }
        }
    }
    
    // MARK: - Public API: Authentication
    
    /// Sign in with user credentials. Provide either (accessToken + refreshToken) or apiKey.
    public func signIn(userId: String, accessToken: String?, refreshToken: String?, apiKey: String?) {
        let hasTokens = accessToken != nil && refreshToken != nil
        let hasApiKey = apiKey != nil
        
        guard hasTokens || hasApiKey else {
            logMessage("signIn error: Provide (accessToken + refreshToken) or (apiKey)")
            return
        }
        
        bumpSessionEpoch()
        clearSyncSession()
        resetAllAnchors()
        clearOutbox()
        
        OpenWearablesHealthSdkKeychain.saveCredentials(userId: userId, accessToken: accessToken, refreshToken: refreshToken)
        
        if let apiKey = apiKey {
            OpenWearablesHealthSdkKeychain.saveApiKey(apiKey)
            logMessage("API key saved")
        }
        
        let authMode = hasTokens ? "token" : "apiKey"
        logMessage("Signed in: userId=\(userId), mode=\(authMode)")
    }
    
    /// How long the sign-out disconnect may stay in flight. Shorter than the session
    /// default, because the user has just signed out and the app may be dismissed
    /// moments later - a request that has not landed by then never will.
    private static let disconnectTimeout: TimeInterval = 10
    
    /// Tells the backend the user deliberately disconnected, so the connection is not
    /// left looking healthy with a `last_synced_at` that never moves again.
    ///
    /// Best effort by design. The request is built while the credential is still in the
    /// Keychain and handed to the session before `signOut` clears it, so the in-flight
    /// request keeps working from the header it already carries. Nothing about signing
    /// out locally depends on the outcome, and the task is deliberately not registered
    /// as a sync upload so the `cancelSync()` in `signOut` does not cancel it.
    ///
    /// Revoked HealthKit permission and app deletion cannot be reported this way; only
    /// a deliberate sign out reaches here.
    internal func notifyBackendOfDisconnect() {
        guard let endpoint = disconnectEndpoint, let credential = authCredential else {
            logMessage("Disconnect not sent - no session")
            return
        }
        
        var request = buildRequest(
            url: endpoint,
            method: "DELETE",
            credential: credential,
            requestId: UUID().uuidString
        )
        request.timeoutInterval = Self.disconnectTimeout
        
        foregroundSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            if let error = error {
                self.logDiagnostic("Disconnect failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                self.logMessage("Disconnect reported to backend")
            } else {
                self.logDiagnostic("Disconnect rejected: HTTP \(status)")
            }
        }.resume()
    }
    
    /// Sign out - reports the disconnect, cancels sync, clears all state.
    public func signOut() {
        logMessage("Signing out")
        
        // Before anything clears the credential that authenticates it.
        notifyBackendOfDisconnect()
        
        bumpSessionEpoch()
        cancelSync()
        stopBackgroundDelivery()
        stopNetworkMonitoring()
        stopProtectedDataMonitoring()
        stopForegroundMonitoring()
        cancelAllBGTasks()
        resetAllAnchors()
        clearSyncSession()
        clearOutbox()
        mirrorDedupe.reset()
        OpenWearablesHealthSdkKeychain.clearAll()
        
        logMessage("Sign out complete - all sync state reset")
    }
    
    /// Update tokens (e.g., after external token refresh).
    public func updateTokens(accessToken: String, refreshToken: String?) {
        OpenWearablesHealthSdkKeychain.updateTokens(accessToken: accessToken, refreshToken: refreshToken)
        logMessage("Tokens updated")
        retryOutboxIfPossible()
    }
    
    /// Restore a previously saved session. Returns userId if restored, nil otherwise.
    public func restoreSession() -> String? {
        if OpenWearablesHealthSdkKeychain.hasSession(),
           let userId = OpenWearablesHealthSdkKeychain.getUserId() {
            logMessage("Session restored: userId=\(userId)")
            return userId
        }
        return nil
    }
    
    /// Whether a valid session exists in the Keychain.
    public var isSessionValid: Bool {
        return OpenWearablesHealthSdkKeychain.hasSession()
    }
    
    // MARK: - Public API: HealthKit Authorization
    
    /// Request HealthKit read authorization for the given health data types.
    ///
    /// ```swift
    /// sdk.requestAuthorization(types: [.steps, .heartRate, .sleep]) { granted in
    ///     print("Authorization granted: \(granted)")
    /// }
    /// ```
    public func requestAuthorization(types: [HealthDataType], completion: @escaping (Bool) -> Void) {
        self.trackedTypes = mapTypes(types)
        OpenWearablesHealthSdkKeychain.saveTrackedTypes(types.map { $0.rawValue })
        
        logMessage("Requesting auth for \(trackedTypes.count) types")
        
        requestAuthorizationInternal { ok in
            completion(ok)
        }
    }
    
    /// Request HealthKit read authorization using raw string identifiers.
    @available(*, deprecated, message: "Use requestAuthorization(types: [HealthDataType], completion:) instead")
    public func requestAuthorization(types: [String], completion: @escaping (Bool) -> Void) {
        let healthTypes = types.compactMap { HealthDataType(rawValue: $0) }
        requestAuthorization(types: healthTypes, completion: completion)
    }
    
    // MARK: - Public API: Sync
    
    /// Computes the earliest date to sync from, based on persisted `syncDaysBack`.
    /// Returns the start of the day (midnight local time) that many days ago,
    /// or `nil` if full sync (no limit) is configured.
    internal func syncStartDate() -> Date? {
        let daysBack = OpenWearablesHealthSdkKeychain.getSyncDaysBack()
        guard daysBack > 0 else { return nil }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) ?? startOfToday
    }
    
    /// Start background sync (registers HealthKit observers, schedules BG tasks, triggers initial sync).
    ///
    /// - Parameters:
    ///   - syncDaysBack: How many days back to sync. Syncs from the start of the day
    ///     that many days ago (inclusive). When `nil` (the default), syncs all available history.
    ///   - completion: Called with `true` if sync started successfully.
    public func startBackgroundSync(syncDaysBack: Int? = nil, completion: @escaping (Bool) -> Void) {
        if let days = syncDaysBack {
            OpenWearablesHealthSdkKeychain.saveSyncDaysBack(days)
            logMessage("Sync days back set to \(days)")
        }
        guard userId != nil, hasAuth else {
            logMessage("Cannot start sync: not signed in")
            completion(false)
            return
        }
        
        startBackgroundDelivery()
        startNetworkMonitoring()
        startProtectedDataMonitoring()
        startForegroundMonitoring()
        
        initialSyncKickoff { started in
            if started {
                self.logMessage("Sync started")
            } else {
                self.logMessage("Sync failed to start")
                self.isInitialSyncInProgress = false
            }
        }
        
        scheduleAppRefresh()
        scheduleProcessing()
        
        let canStart = HKHealthStore.isHealthDataAvailable() &&
                      self.syncEndpoint != nil &&
                      self.hasAuth &&
                      !self.trackedTypes.isEmpty
        
        if canStart {
            OpenWearablesHealthSdkKeychain.setSyncActive(true)
        }
        
        completion(canStart)
    }
    
    /// Stop background sync.
    public func stopBackgroundSync() {
        cancelSync()
        stopBackgroundDelivery()
        stopNetworkMonitoring()
        stopProtectedDataMonitoring()
        stopForegroundMonitoring()
        cancelAllBGTasks()
        OpenWearablesHealthSdkKeychain.setSyncActive(false)
    }
    
    /// Whether sync is currently active.
    public var isSyncActive: Bool {
        return OpenWearablesHealthSdkKeychain.isSyncActive()
    }
    
    /// Get the current sync status.
    public func getSyncStatus() -> [String: Any] {
        return getSyncStatusDict()
    }
    
    /// Resume an interrupted sync session.
    public func resumeSync(completion: @escaping (Bool) -> Void) {
        guard hasResumableSyncSession() else {
            completion(false)
            return
        }
        
        syncAll(fullExport: false, trigger: .app("resume")) { _ in
            completion(true)
        }
    }
    
    /// Fork: runs one sync and reports what happened as a typed `SyncOutcome`.
    ///
    /// Replaces `syncNow(completion:)`, which 0.14 removed. The same prechecks as the
    /// internal triggers apply: no tracked type reports `.upToDate` with zero records, no
    /// credentials report `.failed("no auth")`. A run that finds the slot taken reports
    /// `.skippedBusy` and does not disturb the run that holds it.
    ///
    /// - Parameters:
    ///   - trigger: what started the run; recorded in the journal as `trigger`.
    ///   - deadline: when set, the run declares itself a background run (small chunks) and
    ///     stops before the next fetch or upload once the time has passed, reporting
    ///     `.partial(.budget)`. Without a deadline the run behaves exactly as before.
    ///   - completion: called once, on the main queue, after `onRunCompleted`.
    public func sync(trigger: SyncTrigger = .app("manual"), deadline: Date? = nil, completion: @escaping (SyncOutcome) -> Void) {
        syncAll(fullExport: false, trigger: trigger, deadline: deadline, completion: completion)
    }
    
    /// Trigger an immediate sync.
    @available(*, deprecated, message: "sync(trigger:deadline:completion:) liefert das Ergebnis")
    public func syncNow(completion: @escaping () -> Void) {
        sync(trigger: .app("syncNow")) { _ in completion() }
    }
    
    /// Reset all sync anchors - forces full re-export on next sync.
    public func resetAnchors() {
        resetAllAnchors()
        clearSyncSession()
        clearOutbox()
        // The full re-export is expected to carry the whole history again.
        // Filtering it against the old ledger would silently thin it out.
        mirrorDedupe.reset()
        logMessage("Anchors reset - will perform full sync on next sync")
        
        if OpenWearablesHealthSdkKeychain.isSyncActive() && self.hasAuth {
            logMessage("Triggering full export after reset...")
            self.syncAll(fullExport: true, trigger: .app("reset")) { _ in
                self.logMessage("Full export after reset completed")
            }
        }
    }
    
    /// Forget which measurements were already delivered.
    ///
    /// Call this whenever anchors are reset from outside the SDK, for a single
    /// type or for all of them. Without it the repeated fetch is compared
    /// against the previous run: every sample looks like a copy of one already
    /// sent, and nothing arrives.
    ///
    /// - Parameter identifiers: HealthKit type identifiers, or `nil` for all.
    public func resetMirrorDedupe(forTypes identifiers: [String]? = nil) {
        if let identifiers {
            mirrorDedupe.forget(types: Set(identifiers))
        } else {
            mirrorDedupe.reset()
        }
    }

    /// Get stored credentials.
    public func getStoredCredentials() -> [String: Any?] {
        return [
            "userId": OpenWearablesHealthSdkKeychain.getUserId(),
            "accessToken": OpenWearablesHealthSdkKeychain.getAccessToken(),
            "refreshToken": OpenWearablesHealthSdkKeychain.getRefreshToken(),
            "apiKey": OpenWearablesHealthSdkKeychain.getApiKey(),
            "host": OpenWearablesHealthSdkKeychain.getHost(),
            "tokenRefreshURL": OpenWearablesHealthSdkKeychain.getCustomRefreshUrl(),
            "isSyncActive": OpenWearablesHealthSdkKeychain.isSyncActive()
        ]
    }
    
    // MARK: - Internal: Auto Restore
    
    private func autoRestoreSync() {
        guard userId != nil, hasAuth else {
            logMessage("Cannot auto-restore: no session")
            return
        }
        
        startBackgroundDelivery()
        startNetworkMonitoring()
        startProtectedDataMonitoring()
        startForegroundMonitoring()
        scheduleAppRefresh()
        scheduleProcessing()
        
        // Fork (Plan 05-08): lanes mode resumes when a catch-up is owed, a backfill is open or an
        // open session of the original flow is waiting to be taken over.
        if orchestration == .lanes {
            if lanesHasWorkToResume() {
                logMessage("Found open lanes work, will resume...")
                syncAll(fullExport: false, trigger: .restore) { _ in
                    self.logMessage("Resumed sync completed")
                }
            }
            logMessage("Background sync auto-restored")
            return
        }
        
        // Resume when there is a session with progress, but also when the initial
        // full export never completed (e.g. it was interrupted before its first
        // successful upload - such a session has no progress to detect).
        let fullDone = isInitialExportDone()
        if hasResumableSyncSession() || !fullDone {
            logMessage("Found interrupted sync, will resume...")
            syncAll(fullExport: false, trigger: .restore) { _ in
                self.logMessage("Resumed sync completed")
            }
        }
        
        logMessage("Background sync auto-restored")
    }

    // MARK: - Internal: Authorization
    
    internal func requestAuthorizationInternal(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        
        let readTypes = readAuthorizationTypes()
        logMessage("Requesting read-only auth for \(readTypes.count) types")
        
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }
    
    internal func getAuthCredential() -> String? {
        return authCredential
    }
    
    /// What to ask the user for.
    ///
    /// Wider than `getQueryableTypes()` by exactly one entry: the workout route
    /// is a series type of its own and is not covered by permission for
    /// workouts. It deliberately stays out of the queryable types — those drive
    /// the round-robin and the observers, and a route sample fetched that way
    /// would be serialized as a nameless record instead of as a track.
    internal func readAuthorizationTypes() -> Set<HKObjectType> {
        var types = Set(getQueryableTypes().map { $0 as HKObjectType })
        if trackedTypes.contains(where: { $0 is HKWorkoutType }) {
            types.insert(Self.workoutRouteType)
        }
        return types
    }

    internal func getQueryableTypes() -> [HKSampleType] {
        let disallowedIdentifiers: Set<String> = [
            HKCorrelationTypeIdentifier.bloodPressure.rawValue
        ]
        
        return trackedTypes.filter { type in
            !disallowedIdentifiers.contains(type.identifier)
        }
    }

    // MARK: - Internal: Sync
    
    internal func syncAll(
        fullExport: Bool,
        trigger: SyncTrigger,
        deadline: Date? = nil,
        completion: @escaping (SyncOutcome) -> Void
    ) {
        guard !trackedTypes.isEmpty else {
            deliverUnstartedRun(.upToDate, trigger: trigger, completion: completion)
            return
        }
        
        guard self.hasAuth else {
            self.logMessage("No auth credential for sync")
            deliverUnstartedRun(.failed("no auth"), trigger: trigger, completion: completion)
            return
        }
        self.collectAllData(
            fullExport: fullExport, isBackground: deadline != nil,
            trigger: trigger, deadline: deadline, completion: completion
        )
    }
    
    internal func triggerCombinedSync(typeIdentifier: String? = nil) {
        // Fork (Plan 05-08): in lanes mode there is no initial export that holds new data back;
        // a wake is never dropped for that reason. The upstream branch is unchanged.
        if isInitialSyncInProgress && orchestration != .lanes {
            logMessage("Skipping - initial sync in progress")
            // Fork: the wake itself is the measurement, even if the run is dropped.
            journalWake(
                trigger: SyncTrigger.observer(typeIdentifier).journalValue,
                note: "skipped: initial sync in progress"
            )
            return
        }
        
        if observerBgTask == .invalid {
            observerBgTask = UIApplication.shared.beginBackgroundTask(withName: "health_combined_sync") {
                self.logMessage("Background task expired - cancelling in-flight uploads")
                self.cancelInFlightSyncUploads(reason: "backgroundExpiration")
                // Fork (review ME-01): the lanes cycle stops at its next checkpoint as well.
                self.expireActiveLanesCycle()
                UIApplication.shared.endBackgroundTask(self.observerBgTask)
                self.observerBgTask = .invalid
            }
        }
        
        pendingSyncWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Fork (review ME-01): in lanes mode an observer run in the background gets a deadline
            // just before its background time ends, instead of running without one and being
            // suspended mid-upload. Foreground and upstream mode: no deadline, as before.
            let deadline = self.orchestration == .lanes ? self.observerRunDeadline() : nil
            self.syncAll(fullExport: false, trigger: .observer(typeIdentifier), deadline: deadline) { _ in
                if self.observerBgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.observerBgTask)
                    self.observerBgTask = .invalid
                }
            }
        }
        
        pendingSyncWorkItem = workItem
        syncDebounceQueue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }
    
    /// Fork (review ME-01): the deadline of an observer run, `nil` in the foreground.
    private func observerRunDeadline() -> Date? {
        backgroundTimeRemainingIfInBackground().map {
            Self.observerDeadline(now: Date(), backgroundTimeRemaining: $0)
        }
    }
    
    internal func collectAllData(fullExport: Bool, completion: @escaping () -> Void) {
        collectAllData(fullExport: fullExport, isBackground: false, completion: completion)
    }
    
    /// 0.15 signature. Runs with an internal trigger and drops the outcome.
    ///
    /// Fork (Plan 05-09), decided: no deadline here. This wrapper is the 0.15 entry for an
    /// "internal" run and has no caller left in the SDK (the BGTask handlers and every trigger
    /// use the full signature, which takes the deadline). A run started through it with
    /// `isBackground: false` is a foreground run, and the foreground has no time limit; a caller
    /// that declares `isBackground: true` has to use the full signature and pass its own deadline.
    internal func collectAllData(fullExport: Bool, isBackground: Bool, completion: @escaping () -> Void) {
        collectAllData(
            fullExport: fullExport, isBackground: isBackground,
            trigger: .app("internal"), deadline: nil
        ) { _ in completion() }
    }
    
    /// The flow of 0.15, the way back (D-13). Since Plan 05-08 `collectAllData(...)` in
    /// `Lanes/LanesRunner.swift` is the one switch that decides per call between this and the
    /// two-lane cycle; this body is unchanged from before the switch existed.
    ///
    /// Delivers exactly one `SyncOutcome`: first through `onRunCompleted`, then through
    /// `completion`, on the main queue. The outcome is built from `RunStats`, which the places
    /// that know why a run ended fill in (locked, rejected, background time).
    internal func collectAllDataUpstream(
        fullExport: Bool,
        isBackground: Bool,
        trigger: SyncTrigger,
        deadline: Date?,
        completion: @escaping (SyncOutcome) -> Void
    ) {
        let started = Date()
        let protectedStart = protectedDataAvailableCache
        
        guard let generation = beginSyncRun() else {
            logMessage("Sync in progress, skipping")
            deliverRun(
                SyncOutcome(
                    status: .skippedBusy, orchestration: .upstream,
                    trigger: trigger, started: started, finished: Date()
                ),
                protectedStart: protectedStart,
                completion: completion
            )
            return
        }
        let stats = runStats(for: generation) ?? RunStats()
        
        /// Builds the outcome while the run still owns its statistics, releases the slot,
        /// then delivers. `status == nil` derives the status from the statistics.
        func conclude(
            _ status: SyncOutcome.Status? = nil,
            completed: Bool,
            effectiveFullExport: Bool = false
        ) {
            if !completed && isSyncCancelled(generation: generation) {
                stats.markCancelled()
            }
            let snapshot = stats.snapshot()
            let resolved = status ?? RunStats.status(completed: completed, snapshot: snapshot)
            // In upstream mode a full export is the "catching up" part; a run that did not
            // finish it still has it pending.
            let outcome = SyncOutcome(
                status: resolved,
                records: snapshot.records,
                perType: snapshot.perType,
                liveRecords: effectiveFullExport ? 0 : snapshot.records,
                backfillRecords: effectiveFullExport ? snapshot.records : 0,
                backfillPending: effectiveFullExport && !completed,
                leaseTakenOver: snapshot.leaseTakenOver,
                orchestration: .upstream,
                trigger: trigger,
                started: started,
                finished: Date()
            )
            finishSync(generation: generation)
            deliverRun(outcome, protectedStart: protectedStart, completion: completion)
        }
        
        guard HKHealthStore.isHealthDataAvailable() else {
            logMessage("HealthKit not available")
            conclude(.failed("healthkit unavailable"), completed: false)
            return
        }
        
        guard self.authCredential != nil, let endpoint = self.syncEndpoint else {
            logMessage("No auth credential or endpoint")
            conclude(.failed("no auth"), completed: false)
            return
        }
        
        let queryableTypes = getQueryableTypes()
        guard !queryableTypes.isEmpty else {
            logMessage("No queryable types")
            conclude(.upToDate, completed: true)
            return
        }
        
        let typeNames = queryableTypes.map { shortTypeName($0.identifier) }.joined(separator: ", ")
        logMessage("Types to sync (\(queryableTypes.count)): \(typeNames)")
        
        let existingState = loadSyncState()

        // Entscheidung als reine Funktion (Fork): `LegacyAdoption.swift`, dort auch begründet.
        let effectiveFullExport = Self.effectiveFullExport(
            existingFullExport: existingState?.fullExport,
            fullDone: isInitialExportDone(),
            requested: fullExport
        )
        if effectiveFullExport && !fullExport {
            logMessage("Escalating to full export (initial export not completed yet)")
        }
        
        if let state = existingState, state.fullExport == effectiveFullExport {
            if state.hasProgress {
                logMessage("Resuming sync (fullExport: \(effectiveFullExport), \(state.totalSentCount) already sent, \(state.completedTypes.count) types done)")
            } else {
                logMessage("Continuing sync session (fullExport: \(effectiveFullExport), no progress yet)")
            }
        } else {
            if let state = existingState {
                logMessage("Replacing session (fullExport: \(state.fullExport)) - starting streaming sync (fullExport: \(effectiveFullExport))")
            } else {
                logMessage("Starting streaming sync (fullExport: \(effectiveFullExport), \(queryableTypes.count) types)")
            }
            _ = startNewSyncState(fullExport: effectiveFullExport, types: queryableTypes)
        }
        
        let syncStartTime = Date()
        
        let startRoundRobin: () -> Void = { [weak self] in
            guard let self = self else { return }
            if effectiveFullExport {
                self.fullSyncStartTime = syncStartTime
            }
            self.processTypesRoundRobin(
                types: queryableTypes,
                fullExport: effectiveFullExport,
                endpoint: endpoint,
                isBackground: isBackground,
                generation: generation,
                deadline: deadline
            ) { [weak self] allTypesCompleted in
                guard let self = self else { return }
                
                if effectiveFullExport && !allTypesCompleted {
                    let durationMs = Int(Date().timeIntervalSince(syncStartTime) * 1000)
                    let state = self.loadSyncState()
                    for type in queryableTypes {
                        let typeId = type.identifier
                        if !(state?.completedTypes.contains(typeId) ?? false) {
                            let recordCount = state?.typeProgress[typeId]?.sentCount ?? 0
                            if recordCount > 0 {
                                self.sendTypeEndLog(type: typeId, success: false, recordCount: recordCount, durationMs: durationMs)
                            }
                        }
                    }
                }
                
                if allTypesCompleted {
                    self.finalizeSyncState()
                } else {
                    self.logMessage("Sync incomplete - will resume remaining types later")
                }
                self.fullSyncStartTime = nil
                conclude(completed: allTypesCompleted, effectiveFullExport: effectiveFullExport)
            }
        }
        
        if effectiveFullExport {
            let startDate = syncStartDate()
            let endDate = Date()
            // Counts come from SyncState (already sent), not a HealthKit scan — that
            // scan was the CPU/thermal spike on sync start. Fresh sessions report 0.
            var typeCounts: [String: Int] = [:]
            if let state = existingState {
                for type in queryableTypes {
                    typeCounts[type.identifier] = state.typeProgress[type.identifier]?.sentCount ?? 0
                }
            }
            sendSyncStartLog(types: queryableTypes, typeCounts: typeCounts, startDate: startDate, endDate: endDate) {
                startRoundRobin()
            }
        } else {
            startRoundRobin()
        }
    }
    
    /// Delivers the outcome of a run: the journal entry first (so it is on disk before the
    /// process can be suspended), then `onRunCompleted` and `completion`, each exactly once,
    /// on the main queue.
    internal func deliverRun(
        _ outcome: SyncOutcome,
        protectedStart: Bool?,
        note: String? = nil,
        completion: @escaping (SyncOutcome) -> Void
    ) {
        journalRun(outcome, protectedStart: protectedStart, note: note)
        DispatchQueue.main.async {
            self.onRunCompleted?(outcome)
            completion(outcome)
        }
    }
    
    /// A request that ended before a run could begin (nothing tracked, no credentials).
    /// It is still a run for the host: it gets an outcome like any other.
    internal func deliverUnstartedRun(
        _ status: SyncOutcome.Status,
        trigger: SyncTrigger,
        completion: @escaping (SyncOutcome) -> Void
    ) {
        let now = Date()
        // Fork (Plan 05-08): a run that never began leaves nothing an observer could wait for.
        fireObserverCompletions()
        deliverRun(
            // Fork: the mode that would have run, not always `.upstream`.
            SyncOutcome(status: status, orchestration: orchestration, trigger: trigger, started: now, finished: now),
            protectedStart: protectedDataAvailableCache,
            completion: completion
        )
    }
    
    // MARK: - Round-Robin Sync Orchestration
    
    private class RoundRobinState {
        var olderThanCursors: [String: Date] = [:]
        var anchorCursors: [String: HKQueryAnchor] = [:]
        var completedTypes: Set<String> = []
        /// Sync run this state belongs to, so late callbacks can tell whether they are stale.
        let generation: Int
        /// Whether the caller already knows it runs in the background (BG tasks do).
        let declaredBackground: Bool
        /// Fork: when set, the run stops before the next fetch or upload once it has passed.
        /// Nil leaves the 0.15 flow untouched.
        let deadline: Date?
        
        init(generation: Int, declaredBackground: Bool, deadline: Date? = nil) {
            self.generation = generation
            self.declaredBackground = declaredBackground
            self.deadline = deadline
        }
    }
    
    /// Chunk size for the next round.
    ///
    /// Call sites are an unreliable source: observer-driven syncs, unlock resumes and
    /// network resumes all run with `isBackground: false` while the app is suspended
    /// or about to be, and a 2000-record round is ~1.3 MB - too much for a ~30s task
    /// assertion. Re-checked every round because the app can change state mid-sync.
    ///
    /// Fork (Plan 05-08): `internal` instead of `private`, the lanes runner needs it for
    /// `CycleContext.chunkLimit`.
    internal func currentChunkLimit(declaredBackground: Bool) -> Int {
        let inBackground = declaredBackground || backgroundTimeRemainingIfInBackground() != nil
        return inBackground ? backgroundChunkSize : recordsPerChunk
    }
    
    private func processTypesRoundRobin(
        types: [HKSampleType],
        fullExport: Bool,
        endpoint: URL,
        isBackground: Bool,
        generation: Int,
        deadline: Date? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        let rrState = RoundRobinState(generation: generation, declaredBackground: isBackground, deadline: deadline)
        
        let resumeInfo = getResumeCursors()
        rrState.completedTypes = resumeInfo.completedTypes
        rrState.olderThanCursors = resumeInfo.olderThanCursors
        for (id, data) in resumeInfo.anchorDataCursors {
            if let anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) {
                rrState.anchorCursors[id] = anchor
            }
        }
        
        if !fullExport {
            let fullDone = isInitialExportDone()
            for type in types where !rrState.completedTypes.contains(type.identifier) && rrState.anchorCursors[type.identifier] == nil {
                if let anchor = loadAnchor(for: type) {
                    rrState.anchorCursors[type.identifier] = anchor
                } else if !fullDone {
                    logMessage("\(shortTypeName(type.identifier)): no anchor and full export not completed - skipping incremental for this type")
                    rrState.completedTypes.insert(type.identifier)
                }
            }
        }
        
        processNextRound(
            types: types, fullExport: fullExport, endpoint: endpoint,
            rrState: rrState, completion: completion
        )
    }
    
    // MARK: - Round result for accumulating fetched data
    
    private struct TypeRoundResult {
        let type: HKSampleType
        let samples: [HKSample]
        let count: Int
        let nextOlderThan: Date?
        let newAnchor: HKQueryAnchor?
        let anchorData: Data?
        let isDone: Bool
    }
    
    // MARK: - Round-Robin with combined payloads
    
    private func processNextRound(
        types: [HKSampleType], fullExport: Bool, endpoint: URL,
        rrState: RoundRobinState,
        completion: @escaping (Bool) -> Void
    ) {
        if isSyncCancelled(generation: rrState.generation) {
            logMessage("Sync cancelled - stopping round-robin")
            completion(false)
            return
        }
        // Fork: sign of life before the fetch. A round that stalls here loses its lease.
        heartbeat(generation: rrState.generation)
        
        let incompleteTypes = types.filter { !rrState.completedTypes.contains($0.identifier) }
        if incompleteTypes.isEmpty {
            completion(true)
            return
        }
        
        // Fork: a deadline given by the caller ends the run before the next fetch.
        // Checked after the "all done" test so a run that finished is never partial.
        if let deadline = rrState.deadline, Date() >= deadline {
            logMessage("Deadline reached - pausing sync before next fetch")
            runStats(for: rrState.generation)?.markBudgetHit(.budget)
            completion(false)
            return
        }
        
        let chunkLimit = currentChunkLimit(declaredBackground: rrState.declaredBackground)
        let perTypeLimit = max(1, chunkLimit / incompleteTypes.count)
        
        // Phase 1: Fetch one chunk from each type (no network yet)
        fetchTypesInRound(
            types: incompleteTypes, index: 0, fullExport: fullExport,
            chunkLimit: perTypeLimit, rrState: rrState, accumulated: []
        ) { [weak self] success, results in
            guard let self = self else { completion(false); return }
            if !success { completion(false); return }
            if self.isSyncCancelled(generation: rrState.generation) {
                completion(false)
                return
            }
            
            // Update cursors for types that aren't done
            for result in results where !result.isDone {
                if fullExport {
                    rrState.olderThanCursors[result.type.identifier] = result.nextOlderThan
                } else if let anchor = result.newAnchor {
                    rrState.anchorCursors[result.type.identifier] = anchor
                }
            }
            
            // Mark empty/done types (no data to send) as complete immediately
            let emptyDone = results.filter { $0.samples.isEmpty && $0.isDone }
            for result in emptyDone {
                if !fullExport {
                    self.updateTypeProgress(typeIdentifier: result.type.identifier, sentInChunk: 0, isComplete: true, anchorData: result.anchorData)
                }
                rrState.completedTypes.insert(result.type.identifier)
                if fullExport { self.fireTypeCompletedLog(result.type.identifier) }
            }
            
            // Phase 2: Build combined payload from all types that returned data
            let withData = results.filter { !$0.samples.isEmpty }
            let allSamples = withData.flatMap { $0.samples }
            
            let doneTypesForAnchorCapture = results.filter { $0.isDone }.map { $0.type }
            
            if allSamples.isEmpty {
                if fullExport && !doneTypesForAnchorCapture.isEmpty {
                    self.captureAnchorsForDoneTypes(types: doneTypesForAnchorCapture, index: 0, rrState: rrState) { captureOk in
                        guard captureOk else { completion(false); return }
                        self.processNextRound(
                            types: types, fullExport: fullExport, endpoint: endpoint,
                            rrState: rrState, completion: completion
                        )
                    }
                } else {
                    self.processNextRound(
                        types: types, fullExport: fullExport, endpoint: endpoint,
                        rrState: rrState, completion: completion
                    )
                }
                return
            }
            
            guard let freshCredential = self.authCredential else {
                self.logMessage("No auth credential available for upload")
                completion(false)
                return
            }
            
            // When the app runs in the background it lives on a ~30s task assertion.
            // Don't start an upload that almost certainly cannot finish before
            // expiration. The margin is deliberately small (a chunk upload takes
            // ~1-3s) to use as much of the background window as possible: cursors
            // and anchors only advance on a server 2xx, so even if the very last
            // upload gets cut by expiration the batch is simply re-sent (and
            // deduplicated server-side) when the sync resumes.
            if let remaining = self.backgroundTimeRemainingIfInBackground(), remaining < 5 {
                self.logMessage("Background time low (\(Int(remaining))s left) - pausing sync before next upload")
                self.runStats(for: rrState.generation)?.markBudgetHit(.backgroundTime)
                completion(false)
                return
            }
            
            if let deadline = rrState.deadline, Date() >= deadline {
                self.logMessage("Deadline reached - pausing sync before next upload")
                self.runStats(for: rrState.generation)?.markBudgetHit(.budget)
                completion(false)
                return
            }
            
            // Fork: Spiegelungen anderer Apps aussortieren (MirrorDedupe).
            let deduped = self.mirrorDedupe.filterMirrored(allSamples) { self.measurementKey(for: $0) }
            let sendableSamples = deduped.kept
            
            let afterUpload: () -> Void = { [weak self] in
                guard let self = self else { completion(false); return }
                // Fork: sign of life after the upload, also when the run has lost the slot
                // meanwhile (then it extends nothing).
                self.heartbeat(generation: rrState.generation)
                self.mirrorDedupe.commit(deduped.newKeys)
                if self.isSyncCancelled(generation: rrState.generation) {
                    completion(false)
                    return
                }
                
                // Phase 3: Update progress for all types that had data
                for result in withData {
                    if fullExport {
                        self.updateTypeProgress(
                            typeIdentifier: result.type.identifier, sentInChunk: result.count,
                            isComplete: false, anchorData: nil, olderThan: result.nextOlderThan
                        )
                    } else {
                        self.updateTypeProgress(
                            typeIdentifier: result.type.identifier, sentInChunk: result.count,
                            isComplete: result.isDone, anchorData: result.anchorData
                        )
                        if result.isDone {
                            rrState.completedTypes.insert(result.type.identifier)
                        }
                    }
                }
                
                // Phase 4: For full export, capture anchors for done types
                let fullExportDone = withData.filter { $0.isDone }.map { $0.type } + doneTypesForAnchorCapture.filter { t in !withData.contains(where: { $0.type == t }) }
                if fullExport && !fullExportDone.isEmpty {
                    self.captureAnchorsForDoneTypes(types: fullExportDone, index: 0, rrState: rrState) { captureOk in
                        guard captureOk else { completion(false); return }
                        self.processNextRound(
                            types: types, fullExport: fullExport, endpoint: endpoint,
                            rrState: rrState, completion: completion
                        )
                    }
                } else {
                    self.processNextRound(
                        types: types, fullExport: fullExport, endpoint: endpoint,
                        rrState: rrState, completion: completion
                    )
                }
            }
            
            guard !sendableSamples.isEmpty else {
                afterUpload()
                return
            }
            
            // Routen liegen nicht im Workout selbst, sondern in eigenen
            // Samples, die nur asynchron zu haben sind. Deshalb vor dem
            // Serialisieren einsammeln statt im Mapper.
            let workoutsInRound = sendableSamples.compactMap { $0 as? HKWorkout }
            self.collectRoutes(for: workoutsInRound) { routes in
                if !routes.isEmpty {
                    let points = routes.values.reduce(0) { $0 + $1.count }
                    self.logMessage("  Routes: \(routes.count) workout(s), \(points) fixes")
                }
                
                let payload = self.buildCombinedPayload(samples: sendableSamples, routes: routes)
                
                self.uploadCombinedPayloadReportingStatus(
                    payload: payload, endpoint: endpoint, credential: freshCredential,
                    generation: rrState.generation
                ) { result in
                    guard case .accepted = result else { completion(false); return }
                    // Fork: bestätigt ist, was der Server mit 2xx angenommen hat.
                    self.recordConfirmed(sendableSamples, generation: rrState.generation)
                    afterUpload()
                }
            }
        }
    }
    
    // MARK: - Fetch all types in a round (no network, accumulates results)
    
    private func fetchTypesInRound(
        types: [HKSampleType], index: Int, fullExport: Bool,
        chunkLimit: Int, rrState: RoundRobinState,
        accumulated: [TypeRoundResult],
        completion: @escaping (Bool, [TypeRoundResult]) -> Void
    ) {
        guard index < types.count else {
            completion(true, accumulated)
            return
        }
        
        // Fork: a round fetches every type in turn. One sign of life per type keeps a live
        // but slow round from losing its lease between two heartbeats of the round itself.
        heartbeat(generation: rrState.generation)
        
        let type = types[index]
        
        if fullExport {
            let cursor = rrState.olderThanCursors[type.identifier]
            fetchOneChunkNewestFirst(type: type, olderThan: cursor, chunkLimit: chunkLimit, generation: rrState.generation) {
                [weak self] success, samples, nextOlderThan, isDone in
                guard let self = self else { completion(false, accumulated); return }
                if !success { completion(false, accumulated); return }
                
                let result = TypeRoundResult(
                    type: type, samples: samples, count: samples.count,
                    nextOlderThan: nextOlderThan, newAnchor: nil, anchorData: nil, isDone: isDone
                )
                self.fetchTypesInRound(
                    types: types, index: index + 1, fullExport: fullExport,
                    chunkLimit: chunkLimit, rrState: rrState,
                    accumulated: accumulated + [result], completion: completion
                )
            }
        } else {
            let anchor = rrState.anchorCursors[type.identifier]
            fetchOneChunkIncremental(type: type, anchor: anchor, chunkLimit: chunkLimit, generation: rrState.generation) {
                [weak self] success, samples, newAnchor, anchorData, isDone in
                guard let self = self else { completion(false, accumulated); return }
                if !success { completion(false, accumulated); return }
                
                let result = TypeRoundResult(
                    type: type, samples: samples, count: samples.count,
                    nextOlderThan: nil, newAnchor: newAnchor, anchorData: anchorData, isDone: isDone
                )
                self.fetchTypesInRound(
                    types: types, index: index + 1, fullExport: fullExport,
                    chunkLimit: chunkLimit, rrState: rrState,
                    accumulated: accumulated + [result], completion: completion
                )
            }
        }
    }
    
    // MARK: - Capture anchors for completed full-export types
    
    private func captureAnchorsForDoneTypes(
        types: [HKSampleType], index: Int, rrState: RoundRobinState,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < types.count else {
            completion(true)
            return
        }
        
        let type = types[index]
        captureCurrentAnchor(for: type, generation: rrState.generation) { [weak self] anchor in
            guard let self = self else { completion(false); return }
            if self.isSyncCancelled(generation: rrState.generation) {
                completion(false)
                return
            }
            
            // Without a valid anchor the type must NOT be marked complete: the next
            // incremental sync would run an anchored query from nil and re-crawl the
            // whole history oldest-first. Pause the sync instead - on resume the type
            // re-sends its last chunk (deduplicated server-side) and retries capture.
            guard let anchor = anchor,
                  let anchorData = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
                self.logMessage("  \(self.shortTypeName(type.identifier)): anchor capture failed - leaving type incomplete, pausing sync")
                completion(false)
                return
            }
            
            self.updateTypeProgress(typeIdentifier: type.identifier, sentInChunk: 0, isComplete: true, anchorData: anchorData)
            rrState.completedTypes.insert(type.identifier)
            self.fireTypeCompletedLog(type.identifier)
            self.logMessage("  \(self.shortTypeName(type.identifier)): complete (anchor captured)")
            self.captureAnchorsForDoneTypes(types: types, index: index + 1, rrState: rrState, completion: completion)
        }
    }
    
    // MARK: - Fetch-Only Chunk Processors (no network)
    
    private func fetchOneChunkNewestFirst(
        type: HKSampleType, olderThan: Date?, chunkLimit: Int, generation: Int,
        completion: @escaping (_ success: Bool, _ samples: [HKSample], _ nextOlderThan: Date?, _ isDone: Bool) -> Void
    ) {
        if isSyncCancelled(generation: generation) { completion(false, [], nil, false); return }
        
        let startDate = syncStartDate()
        var predicate: NSPredicate? = nil
        if let olderThan = olderThan {
            predicate = HKQuery.predicateForSamples(withStart: startDate, end: olderThan, options: .strictEndDate)
        } else if startDate != nil {
            predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: [])
        }
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: chunkLimit, sortDescriptors: [sortDescriptor]) {
            [weak self] _, samplesOrNil, error in
            autoreleasepool {
                guard let self = self else { completion(false, [], nil, false); return }
                
                if self.isSyncCancelled(generation: generation) { completion(false, [], nil, false); return }
                
                if let error = error {
                    if self.isProtectedDataError(error) {
                        self.logMessage("\(self.shortTypeName(type.identifier)): protected data inaccessible - pausing sync")
                        self.pendingSyncAfterUnlock = true
                        self.runStats(for: generation)?.markLocked()
                        completion(false, [], nil, false)
                        return
                    }
                    self.logMessage("\(self.shortTypeName(type.identifier)): \(error.localizedDescription) - skipping")
                    completion(true, [], nil, true)
                    return
                }
                
                let samples = samplesOrNil ?? []
                if samples.isEmpty {
                    self.logMessage("  \(self.shortTypeName(type.identifier)): all data sent (newest first)")
                    completion(true, [], nil, true)
                    return
                }
                
                let isLastChunk = samples.count < chunkLimit
                let nextOlderThan = isLastChunk ? nil : samples.last!.endDate
                self.logMessage("  \(self.shortTypeName(type.identifier)): \(samples.count) samples (newest first)")
                completion(true, samples, nextOlderThan, isLastChunk)
            }
        }
        
        healthStore.execute(query)
    }
    
    private func fetchOneChunkIncremental(
        type: HKSampleType, anchor: HKQueryAnchor?, chunkLimit: Int, generation: Int,
        completion: @escaping (_ success: Bool, _ samples: [HKSample], _ newAnchor: HKQueryAnchor?, _ anchorData: Data?, _ isDone: Bool) -> Void
    ) {
        if isSyncCancelled(generation: generation) { completion(false, [], nil, nil, false); return }
        
        let syncPredicate: NSPredicate? = {
            guard let start = syncStartDate() else { return nil }
            return HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        }()
        
        let query = HKAnchoredObjectQuery(type: type, predicate: syncPredicate, anchor: anchor, limit: chunkLimit) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            autoreleasepool {
                guard let self = self else { completion(false, [], nil, nil, false); return }
                
                if self.isSyncCancelled(generation: generation) { completion(false, [], nil, nil, false); return }
                
                if let error = error {
                    if self.isProtectedDataError(error) {
                        self.logMessage("\(self.shortTypeName(type.identifier)): protected data inaccessible - pausing sync")
                        self.pendingSyncAfterUnlock = true
                        self.runStats(for: generation)?.markLocked()
                        completion(false, [], nil, nil, false)
                        return
                    }
                    self.logMessage("\(self.shortTypeName(type.identifier)): \(error.localizedDescription) - skipping")
                    completion(true, [], nil, nil, true)
                    return
                }
                
                let samples = samplesOrNil ?? []
                let deletedCount = deletedObjects?.count ?? 0
                
                var anchorData: Data? = nil
                if let newAnchor = newAnchor {
                    anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                }
                
                if samples.isEmpty && deletedCount == 0 {
                    self.logMessage("  \(self.shortTypeName(type.identifier)): complete")
                    completion(true, [], newAnchor, anchorData, true)
                    return
                }
                
                // Deleted objects count against the query limit. Ignoring them made a
                // chunk with samples + deletions look like the last one, so the anchor
                // for the remaining (unfetched) data was never advanced.
                let isLastChunk = (samples.count + deletedCount) < chunkLimit
                self.logMessage("  \(self.shortTypeName(type.identifier)): \(samples.count) samples" + (deletedCount > 0 ? ", \(deletedCount) deleted" : ""))
                completion(true, samples, newAnchor, anchorData, isLastChunk)
            }
        }
        
        healthStore.execute(query)
    }
    
    // MARK: - Anchor Capture (for incremental sync after full export)
    
    private func captureCurrentAnchor(for type: HKSampleType, generation: Int, completion: @escaping (HKQueryAnchor?) -> Void) {
        logMessage("  \(shortTypeName(type.identifier)): saving anchor...")
        captureAnchorStep(type: type, anchor: nil, limit: 10000, generation: generation, completion: completion)
    }
    
    /// Fork (Plan 05-07): `internal` statt `private`, damit der HealthKit-Leser der Spuren den
    /// Durchlauf für den Anchor "jetzt" nutzt. `onError` (Vorgabe `nil`) meldet den Fehler, der
    /// `completion(nil)` auslöst, damit der Aufrufer "gesperrt" von "sonstiger Fehler" trennen
    /// kann. Verhalten ohne `onError` unverändert.
    internal func captureAnchorStep(type: HKSampleType, anchor: HKQueryAnchor?, limit: Int, generation: Int, onError: ((Error) -> Void)? = nil, completion: @escaping (HKQueryAnchor?) -> Void) {
        // Fork: sign of life in every step of the recursion. A dense type needs many steps,
        // and the lease must not take over a run that is still reading.
        heartbeat(generation: generation)
        let syncPredicate: NSPredicate? = {
            guard let start = syncStartDate() else { return nil }
            return HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        }()
        let query = HKAnchoredObjectQuery(type: type, predicate: syncPredicate, anchor: anchor, limit: limit) {
            [weak self] _, samples, deletedObjects, newAnchor, error in
            guard let self = self else { completion(nil); return }
            
            if let error = error {
                // A failed step must not return a stale/nil anchor - the caller would
                // persist it and the next incremental sync would re-crawl history.
                if self.isProtectedDataError(error) {
                    self.logMessage("\(self.shortTypeName(type.identifier)): protected data inaccessible during anchor capture - will retry after unlock")
                    self.pendingSyncAfterUnlock = true
                    self.runStats(for: generation)?.markLocked()
                } else {
                    self.logMessage("\(self.shortTypeName(type.identifier)): anchor capture failed - \(error.localizedDescription)")
                }
                onError?(error)
                completion(nil)
                return
            }
            
            // Deleted objects count against the query limit too. Ignoring them made
            // the recursion stop early with an anchor that wasn't fully advanced.
            let count = (samples?.count ?? 0) + (deletedObjects?.count ?? 0)
            if count >= limit {
                self.captureAnchorStep(type: type, anchor: newAnchor, limit: limit, generation: generation, onError: onError, completion: completion)
            } else {
                completion(newAnchor)
            }
        }
        healthStore.execute(query)
    }
    
    
    // MARK: - Sync run lifecycle
    
    /// Claims the sync slot for a new run and returns its generation, or nil when
    /// another run still owns it.
    internal func beginSyncRun() -> Int? {
        commitLock.lock()
        syncLock.lock()

        // Fork: the decision lives in `SyncLease` (a pure function). It keeps the rule of 0.15 (take
        // over 60 s after cancelSync()) and adds the lease: a run without a sign of life
        // for `leaseDuration` loses the slot, also when nobody cancelled it. Otherwise a
        // HealthKit callback that never arrives holds the slot until process death.
        let current = now()
        let previousGeneration = syncGeneration
        var takeOverReason: String?
        switch SyncLease.decide(
            isSyncing: isSyncing, cancelRequestedAt: cancelRequestedAt,
            leaseDeadline: leaseDeadlineStorage, now: current
        ) {
        case .busy:
            syncLock.unlock()
            commitLock.unlock()
            return nil
        case .grant:
            break
        case .takeOver(let reason):
            takeOverReason = reason
            NSLog("[OpenWearablesHealthSDK] Sync run lost the slot (%@) - taking over", reason)
        }

        syncGeneration += 1
        isSyncing = true
        cancelRequestedAt = nil
        leaseDeadlineStorage = current.addingTimeInterval(SyncLease.leaseDuration)
        let generation = syncGeneration
        syncLock.unlock()
        commitLock.unlock()

        // Fork: statistics for this run; a takeover is part of what the outcome reports.
        registerRunStats(generation: generation).leaseTakenOver = takeOverReason != nil

        if let reason = takeOverReason {
            // The old run is fenced by the generation compare in `isSyncCancelled`. Its
            // in-flight uploads are cancelled so they do not hold the foreground session.
            cancelInFlightSyncUploads(reason: reason == "leaseExpired" ? "leaseExpired" : "syncTakeover")
            journalLeaseTakeover(reason: reason, previousGeneration: previousGeneration, newGeneration: generation, at: current)
            // Fork (review ME-03): triggers waiting on a live round of the superseded lanes cycle
            // get their answer now instead of never.
            abandonSupersededLanesCycle(newGeneration: generation)
        }
        return generation
    }

    /// Fork (Plan 05-08): what `beginSyncRun()` would decide right now, without taking the slot.
    /// The lanes runner asks it to find out whether a running cycle is still alive (then a
    /// trigger requests a live round instead of being skipped).
    internal func currentLeaseDecision() -> SyncLease.Decision {
        syncLock.lock()
        defer { syncLock.unlock() }
        return SyncLease.decide(
            isSyncing: isSyncing, cancelRequestedAt: cancelRequestedAt,
            leaseDeadline: leaseDeadlineStorage, now: now()
        )
    }

    /// Fork: a sign of life from the run that owns the slot. Pushes the lease out by
    /// `SyncLease.leaseDuration`. A run that has already lost the slot extends nothing, so
    /// a late callback of a superseded run cannot keep a newer run's slot alive.
    internal func heartbeat(generation: Int) {
        syncLock.lock()
        defer { syncLock.unlock() }
        guard isSyncing, generation == syncGeneration else { return }
        leaseDeadlineStorage = now().addingTimeInterval(SyncLease.leaseDuration)
    }
    
    /// True once this run has been cancelled, or once a newer run has taken the slot.
    internal func isSyncCancelled(generation: Int) -> Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        return generation <= cancelledGeneration || generation != syncGeneration
    }

    /// Fork (review HI-01): runs `write` only while `generation` still owns the slot, and checks
    /// and writes in one step under `commitLock`. Returns `false` without writing when the run
    /// was cancelled or a newer run took the slot. `write` must stay short (a small file, a
    /// defaults key): a takeover waits for it.
    internal func commitIfCurrent(generation: Int, _ write: () throws -> Void) rethrows -> Bool {
        commitLock.lock()
        defer { commitLock.unlock() }
        guard !isSyncCancelled(generation: generation) else { return false }
        try write()
        return true
    }
    
    /// Releases the sync slot. A run that has already lost the slot to a newer one
    /// must not clear it, otherwise it would let a third run start on top of a live one.
    internal func finishSync(generation: Int) {
        // Fork: the statistics of a run end with it, also when it lost the slot meanwhile.
        removeRunStats(generation: generation)
        syncLock.lock()
        defer { syncLock.unlock() }
        guard generation == syncGeneration else { return }
        isSyncing = false
        isInitialSyncInProgress = false
        cancelRequestedAt = nil
        leaseDeadlineStorage = nil
    }
    
    /// Returns the remaining background execution time when the app is in the
    /// background, or `nil` when it is active (foreground has no time limit).
    /// UIApplication state must be read on the main thread; sync uploads complete
    /// on the main queue, so guard against deadlocking with `Thread.isMainThread`.
    private func backgroundTimeRemainingIfInBackground() -> TimeInterval? {
        let read: () -> TimeInterval? = {
            guard UIApplication.shared.applicationState == .background else { return nil }
            return UIApplication.shared.backgroundTimeRemaining
        }
        if Thread.isMainThread {
            return read()
        }
        return DispatchQueue.main.sync(execute: read)
    }
    
    // MARK: - Sync-owned upload tracking
    
    /// Fork (review ME-02): with a `generation`, the upload gives the run's lease a sign of life
    /// whenever bytes moved since the last look, so a slow but live upload is never taken over.
    internal func trackSyncUpload(_ task: URLSessionTask, requestId: String, generation: Int? = nil) {
        var heartbeat: UploadProgressHeartbeat?
        if let generation = generation {
            heartbeat = UploadProgressHeartbeat(
                interval: Self.uploadHeartbeatInterval,
                progress: { [weak task] in
                    guard let task = task else { return (false, 0) }
                    return (task.state == .running, task.countOfBytesSent + task.countOfBytesReceived)
                },
                beat: { [weak self] in self?.heartbeat(generation: generation) }
            )
        }
        syncUploadTasksLock.lock()
        syncUploadTasks[requestId] = task
        if let heartbeat = heartbeat { syncUploadHeartbeats[requestId] = heartbeat }
        syncUploadTasksLock.unlock()
        heartbeat?.start()
    }
    
    @discardableResult
    internal func untrackSyncUpload(requestId: String) -> URLSessionTask? {
        syncUploadTasksLock.lock()
        let heartbeat = syncUploadHeartbeats.removeValue(forKey: requestId)
        let task = syncUploadTasks.removeValue(forKey: requestId)
        syncUploadTasksLock.unlock()
        heartbeat?.stop()
        return task
    }
    
    /// Cancels the uploads the sync path owns. Called from BG task expiration handlers
    /// so requests are terminated cleanly instead of being frozen mid-transfer when the
    /// app gets suspended (which leaves the server with a dangling connection).
    ///
    /// Only sync uploads are cancelled: token refreshes and telemetry share the
    /// foreground session, and cancelling a refresh surfaces as a `.networkError`.
    internal func cancelInFlightSyncUploads(reason: String) {
        syncUploadTasksLock.lock()
        let tasks = Array(syncUploadTasks.values)
        syncUploadTasksLock.unlock()
        
        guard !tasks.isEmpty else { return }
        
        syncLock.lock()
        lastCancellation = (reason: reason, at: Date())
        syncLock.unlock()
        
        for task in tasks { task.cancel() }
    }
    
    /// Best-effort attribution for an `NSURLErrorCancelled`: a cancellation the SDK
    /// issued moments ago, or one URLSession delivered on its own (app suspension,
    /// connection reset).
    internal func cancellationAttribution() -> String {
        syncLock.lock()
        defer { syncLock.unlock() }
        guard let last = lastCancellation, Date().timeIntervalSince(last.at) < 10 else { return "system" }
        return last.reason
    }
    
    internal func cancelSync() {
        logMessage("Cancelling sync...")
        
        // Fork (review HI-01): a write of the run that is being cancelled finishes first.
        commitLock.lock()
        syncLock.lock()
        cancelledGeneration = syncGeneration
        // Fork: through the lease clock, so the lease decision compares like with like.
        cancelRequestedAt = now()
        isInitialSyncInProgress = false
        syncLock.unlock()
        commitLock.unlock()
        
        pendingSyncWorkItem?.cancel()
        pendingSyncWorkItem = nil
        
        // `isSyncing` stays set until the running loop reaches a checkpoint and unwinds
        // through `finishSync(generation:)`. Clearing it here would let a second sync
        // start on top of a live one, both writing the same SyncState file.
        cancelInFlightSyncUploads(reason: "cancelSync")
        
        // The background session carries outbox uploads only, so cancelling all of its
        // tasks is targeted. `signOut()` relies on this to stop uploads for a user who
        // is on their way out.
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
        
        if observerBgTask != .invalid {
            UIApplication.shared.endBackgroundTask(observerBgTask)
            observerBgTask = .invalid
        }
        
        logMessage("Sync cancelled")
    }
    
    // MARK: - Logging
    
    /// Sets the log level. Convenience wrapper for Objective-C / Flutter bridge.
    public func setLogLevel(_ level: OWLogLevel) {
        self.logLevel = level
    }
    
    /// Whether `logMessage` would emit anything. Callers that have to do real work to
    /// build a message (payload summaries) must check this first.
    internal var isLoggingEnabled: Bool {
        switch logLevel {
        case .none:
            return false
        case .always:
            return true
        case .debug:
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
    }
    
    internal func logMessage(_ message: String) {
        guard isLoggingEnabled else { return }
        NSLog("[OpenWearablesHealthSDK] %@", message)
        onLog?(message)
    }
    
    /// Emits a diagnostic that must survive release builds, where the default
    /// `.debug` level silences `logMessage`. Used for upload outcomes: they are the
    /// records needed to explain a failed sync after the fact.
    internal func logDiagnostic(_ message: String) {
        guard logLevel != .none else { return }
        NSLog("[OpenWearablesHealthSDK] %@", message)
        onLog?(message)
    }
    
    /// Records how one upload attempt ended.
    ///
    /// `countOfBytesSent` against `countOfBytesExpectedToSend` is the field that
    /// separates "never started" from "cut off partway", which is the distinction the
    /// server-side `ClientDisconnect` reports cannot make. `NSURLErrorCancelled` is
    /// logged like any other failure - it is the code the SDK sees when the app is
    /// suspended mid-upload, so suppressing it hides the failures worth investigating.
    internal func logUploadOutcome(
        stage: String,
        requestId: String,
        declaredBytes: Int,
        task: URLSessionTask?,
        statusCode: Int?,
        error: Error?
    ) {
        var fields = ["upload=\(stage)", "req=\(requestId)", "bytes=\(declaredBytes)"]
        
        if let task = task {
            fields.append("sent=\(task.countOfBytesSent)/\(task.countOfBytesExpectedToSend)")
        }
        if let statusCode = statusCode {
            fields.append("status=\(statusCode)")
        }
        
        var isFailure = statusCode.map { !(200...299).contains($0) } ?? true
        
        if let error = error as NSError? {
            isFailure = true
            fields.append("error=\(error.domain)(\(error.code))")
            if error.code == NSURLErrorCancelled {
                fields.append("cancelledBy=\(cancellationAttribution())")
            }
        }
        
        let message = fields.joined(separator: " ")
        if isFailure {
            logDiagnostic(message)
        } else {
            logMessage(message)
        }
    }
    
    // MARK: - Token Refresh
    
    internal func attemptTokenRefresh(completion: @escaping (TokenRefreshResult) -> Void) {
        tokenRefreshLock.lock()
        
        if isRefreshingToken {
            tokenRefreshCallbacks.append(completion)
            tokenRefreshLock.unlock()
            return
        }
        
        guard let refreshToken = self.refreshToken, let url = self.tokenRefreshEndpoint else {
            tokenRefreshLock.unlock()
            logMessage("Token refresh failed: no credentials or refresh URL")
            completion(.authFailure)
            return
        }
        
        isRefreshingToken = true
        tokenRefreshCallbacks.append(completion)
        tokenRefreshLock.unlock()
        
        var req = buildRequest(url: url, credential: nil, requestId: UUID().uuidString)
        
        let body: [String: String] = ["refresh_token": refreshToken]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            logMessage("Token refresh failed: serialization error")
            finishTokenRefresh(result: .networkError)
            return
        }
        req.httpBody = bodyData
        
        let task = foregroundSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.logMessage("Token refresh failed: \(error.localizedDescription)")
                self.finishTokenRefresh(result: .networkError)
                return
            }
            
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            
            if (401...403).contains(statusCode) {
                self.logMessage("Token refresh rejected: HTTP \(statusCode)")
                self.finishTokenRefresh(result: .authFailure)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let data = data else {
                self.logMessage("Token refresh failed: HTTP \(statusCode)")
                self.finishTokenRefresh(result: .networkError)
                return
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else {
                self.logMessage("Token refresh failed: invalid response body")
                self.finishTokenRefresh(result: .networkError)
                return
            }
            
            let newRefreshToken = json["refresh_token"] as? String
            OpenWearablesHealthSdkKeychain.updateTokens(accessToken: newAccessToken, refreshToken: newRefreshToken)
            self.logMessage("Token refresh: HTTP \(statusCode)")
            self.finishTokenRefresh(result: .success)
        }
        
        task.resume()
    }
    
    private func finishTokenRefresh(result: TokenRefreshResult) {
        tokenRefreshLock.lock()
        let callbacks = tokenRefreshCallbacks
        tokenRefreshCallbacks = []
        isRefreshingToken = false
        tokenRefreshLock.unlock()
        
        for callback in callbacks {
            callback(result)
        }
    }
    
    // MARK: - Auth Error Emission
    
    internal func emitAuthError(statusCode: Int) {
        logMessage("Auth error: HTTP \(statusCode) - token invalid")
        onAuthError?(statusCode, "Unauthorized - please re-authenticate")
    }
    
    // MARK: - Payload Logging
    
    internal func logPayloadSummary(_ data: Data, label: String) {
        // Building the summary re-parses the whole payload (~1.3 MB per round), so it
        // must not run when the log line would be dropped anyway.
        guard isLoggingEnabled else { return }
        
        let sizeKB = Double(data.count) / 1024
        
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let dataDict = jsonObject["data"] as? [String: Any] else {
            logMessage("\(label): \(String(format: "%.0f", sizeKB)) KB")
            return
        }
        
        var typeCounts: [String: Int] = [:]
        
        if let records = dataDict["records"] as? [[String: Any]] {
            for record in records {
                guard let type = record["type"] as? String else { continue }
                let shortType = type
                    .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                    .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
                typeCounts[shortType, default: 0] += 1
            }
        }
        if let sleep = dataDict["sleep"] as? [[String: Any]], !sleep.isEmpty {
            typeCounts["sleep"] = sleep.count
        }
        if let workouts = dataDict["workouts"] as? [[String: Any]], !workouts.isEmpty {
            typeCounts["workouts"] = workouts.count
        }
        
        let totalCount = typeCounts.values.reduce(0, +)
        let breakdown = typeCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        
        logMessage("\(label) \(String(format: "%.0f", sizeKB)) KB, \(totalCount) items (\(breakdown))")
    }
    
    // MARK: - Network Monitoring
    
    internal func startNetworkMonitoring() {
        guard networkMonitor == nil else { return }
        
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let isConnected = path.status == .satisfied
            
            if isConnected {
                if self.wasDisconnected {
                    self.wasDisconnected = false
                    self.logMessage("Network restored")
                    self.tryResumeAfterNetworkRestored()
                }
            } else {
                if !self.wasDisconnected {
                    self.wasDisconnected = true
                    self.logMessage("Network lost")
                }
            }
        }
        
        networkMonitor?.start(queue: networkMonitorQueue)
        logMessage("Network monitoring started")
    }
    
    internal func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        wasDisconnected = false
    }
    
    // MARK: - Protected Data Monitoring
    
    internal func startProtectedDataMonitoring() {
        guard protectedDataObserver == nil else { return }
        
        // Fork: initial value for the lock-state cache, then keep it current. A run on a
        // background thread cannot ask UIApplication itself.
        refreshDeviceStateCaches()
        protectedDataUnavailableObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.protectedDataAvailableCache = false
        }
        
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.protectedDataAvailableCache = true
            self.logMessage("Device unlocked - protected data available")
            self.journalWake(
                trigger: SyncTrigger.unlock.journalValue,
                note: "pendingSync=\(self.pendingSyncAfterUnlock) catchUp=\(self.lanesNeedsCatchUp)"
            )
            
            // Fork (Plan 05-08): lanes mode owes a catch-up from the persisted flag (it survives a
            // process restart, `pendingSyncAfterUnlock` does not). A cycle that is running takes the
            // request as a live round, so there is no "already syncing" check here.
            if self.orchestration == .lanes {
                self.pendingSyncAfterUnlock = false
                if self.lanesNeedsCatchUp {
                    self.logMessage("Triggering catch-up after unlock...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.syncAll(fullExport: false, trigger: .unlock) { _ in
                            self?.logMessage("Catch-up after unlock completed")
                        }
                    }
                }
                return
            }
            
            if self.pendingSyncAfterUnlock {
                self.pendingSyncAfterUnlock = false
                self.logMessage("Triggering deferred sync after unlock...")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self else { return }
                    
                    self.syncLock.lock()
                    let alreadySyncing = self.isSyncing
                    self.syncLock.unlock()
                    
                    guard !alreadySyncing else {
                        self.logMessage("Sync already in progress after unlock")
                        return
                    }
                    
                    self.syncAll(fullExport: false, trigger: .unlock) { _ in
                        self.logMessage("Deferred sync after unlock completed")
                    }
                }
            }
        }
        
        logMessage("Protected data monitoring started")
    }
    
    internal func stopProtectedDataMonitoring() {
        if let observer = protectedDataObserver {
            NotificationCenter.default.removeObserver(observer)
            protectedDataObserver = nil
        }
        if let observer = protectedDataUnavailableObserver {
            NotificationCenter.default.removeObserver(observer)
            protectedDataUnavailableObserver = nil
        }
        pendingSyncAfterUnlock = false
    }
    
    // MARK: - Foreground Monitoring
    
    /// Resumes an interrupted sync when the app returns to the foreground.
    /// A sync paused in the background (e.g. "Background time low") had no
    /// trigger to continue once the user reopened the app - observers only fire
    /// on new HealthKit data and BG tasks run opportunistically much later.
    internal func startForegroundMonitoring() {
        guard foregroundObserver == nil else { return }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tryResumeAfterForeground()
        }
        
        logMessage("Foreground monitoring started")
    }
    
    internal func stopForegroundMonitoring() {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }
    
    private func tryResumeAfterForeground() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            
            guard OpenWearablesHealthSdkKeychain.isSyncActive(), self.hasAuth else { return }
            
            // Fork (Plan 05-08): lanes mode, a running cycle takes the trigger as a live round.
            if self.orchestration == .lanes {
                guard self.lanesHasWorkToResume() else { return }
                self.logMessage("App returned to foreground - resuming lanes sync...")
                self.syncAll(fullExport: false, trigger: .foreground) { _ in
                    self.logMessage("Foreground resume sync completed")
                }
                return
            }
            
            let fullDone = self.isInitialExportDone()
            guard self.hasResumableSyncSession() || !fullDone else { return }
            
            guard !self.isSyncInProgress else {
                self.logMessage("Sync already in progress after foreground")
                return
            }
            
            self.logMessage("App returned to foreground - resuming sync...")
            self.syncAll(fullExport: false, trigger: .foreground) { _ in
                self.logMessage("Foreground resume sync completed")
            }
        }
    }
    
    internal func markNetworkError() {
        wasDisconnected = true
    }
    
    private func tryResumeAfterNetworkRestored() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            
            // Fork (Plan 05-08): lanes mode, a running cycle takes the trigger as a live round.
            if self.orchestration == .lanes {
                guard self.lanesHasWorkToResume() else {
                    self.logMessage("No sync to resume")
                    return
                }
                self.logMessage("Resuming lanes sync after network restored...")
                self.syncAll(fullExport: false, trigger: .network) { _ in
                    self.logMessage("Network resume sync completed")
                }
                return
            }
            
            let fullDone = self.isInitialExportDone()
            guard self.hasResumableSyncSession() || !fullDone else {
                self.logMessage("No sync to resume")
                return
            }
            
            self.syncLock.lock()
            let alreadySyncing = self.isSyncing
            self.syncLock.unlock()
            
            if alreadySyncing {
                self.logMessage("Sync already in progress")
                return
            }
            
            self.logMessage("Resuming sync after network restored...")
            self.syncAll(fullExport: false, trigger: .network) { _ in
                self.logMessage("Network resume sync completed")
            }
        }
    }
    
    // MARK: - Protected Data Error Detection
    
    internal func isProtectedDataError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "com.apple.healthkit" && nsError.code == 6 {
            return true
        }
        let msg = error.localizedDescription.lowercased()
        return msg.contains("protected health data") || msg.contains("inaccessible")
    }
    
    // MARK: - Helpers
    
    internal func shortTypeName(_ identifier: String) -> String {
        return identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutType", with: "Workout")
    }
}

// MARK: - Array extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
