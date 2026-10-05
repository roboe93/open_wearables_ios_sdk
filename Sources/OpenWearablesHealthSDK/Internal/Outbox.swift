import Foundation
import HealthKit

/// Ausgang eines Uploads mit dem, was die Bool-Fassung verschweigt (Fork, Plan 05-03).
internal enum UploadResult: Equatable {
    /// 2xx, mit dem Status des Servers (202 beim Sync).
    case accepted(Int)
    /// 4xx außer 401: der Server lehnt die Daten ab, der Cursor bewegt sich nicht.
    case rejected(Int)
    /// Netz, Auth (401 nach Refresh), 5xx. Der Text enthält nie Gesundheitswerte.
    case failed(String)
    /// Der Lauf wurde abgebrochen oder verdrängt, oder die Hintergrundzeit hat den Upload beendet.
    case cancelled
}

extension OpenWearablesHealthSDK {

    // MARK: - Outbox model

    /// Decoded, never encoded: the sync path stopped writing outbox items in 0.14, so
    /// the only items on disk are leftovers from an earlier SDK version.
    internal struct OutboxItem: Codable {
        let typeIdentifier: String
        let userKey: String
        let payloadPath: String
        let anchorPath: String?
        let wasFullExport: Bool?
    }

    /// Read-only. Nothing creates this directory anymore; when it is missing the
    /// enumerations in `clearOutbox` and `retryOutboxIfPossible` simply find nothing.
    internal func outboxDir() -> URL {
        return stateBaseDirectory().appendingPathComponent("health_outbox", isDirectory: true)
    }

    /// Fork (Plan 09-03, Gerätebefund 05.10.2026): wo eine Datei aus einem Outbox-Item heute liegt.
    ///
    /// Items aus SDK 0.13 tragen absolute Pfade. Nach einer Neuinstallation hat der App-Container
    /// eine neue UUID, die Pfade zeigen ins Leere, die Dateien liegen aber unter gleichem Namen in
    /// `outboxDir()`. Bisher galt das Item dann als verwaist: es wurde gelöscht, die Ladung blieb für
    /// immer liegen.
    ///
    /// - Existiert `path`, gilt er unverändert (Verhalten wie bisher).
    /// - Sonst zählt nur der letzte Bestandteil: dieselbe Datei in `outboxDir()`, wenn sie dort als
    ///   reguläre Datei liegt. `.`, `..` und Ordner werden nie aufgelöst, das Ergebnis verlässt
    ///   `outboxDir()` nie (T-09-07). Ein `..` am Ende bezeichnete sonst den Zustandsordner, und das
    ///   Verwerfen einer alten Altlast löschte ihn.
    /// - Sonst `nil`.
    internal func resolveOutboxPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: path) { return path }

        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }

        let directory = outboxDir()
        let candidate = directory.appendingPathComponent(name, isDirectory: false)
        guard candidate.standardizedFileURL.deletingLastPathComponent().path
                == directory.standardizedFileURL.path else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate.path
    }

    // MARK: - Combined upload
    
    /// Uploads one combined sync round.
    ///
    /// Nothing is written to the outbox. Progress lives in `SyncState` and advances
    /// only on a 2xx, so an interrupted round is rebuilt from HealthKit by the next
    /// sync. A persisted copy could only ever be replayed as a duplicate of data that
    /// the next sync re-fetches anyway, while `SyncState` knew nothing about it.
    /// Whether a combined-upload HTTP status should advance SyncState.
    /// Only 2xx means the server accepted the body. 4xx (including the production
    /// `ClientDisconnect` 400) must not move cursors — the chunk is rebuilt later.
    internal static func syncShouldAdvance(afterHTTPStatus statusCode: Int) -> Bool {
        (200...299).contains(statusCode)
    }
    
    /// Bool-Fassung von `uploadCombinedPayloadReportingStatus`. Bleibt bestehen, damit der
    /// Aufrufvertrag von 0.15 gleich bleibt: `true` genau bei 2xx.
    internal func uploadCombinedPayload(
        payload: [String: Any],
        endpoint: URL,
        credential: String,
        generation: Int,
        completion: @escaping (Bool) -> Void
    ) {
        uploadCombinedPayloadReportingStatus(
            payload: payload, endpoint: endpoint, credential: credential, generation: generation
        ) { result in
            if case .accepted = result {
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    /// Trägt das Ergebnis in die Statistik der Generation ein und gibt es weiter.
    /// Die Statistik beeinflusst keine Entscheidung, sie speist nur das `SyncOutcome`.
    private func finishUpload(
        _ result: UploadResult,
        generation: Int,
        completion: (UploadResult) -> Void
    ) {
        if let stats = runStats(for: generation) {
            switch result {
            case .accepted:
                break
            case .rejected(let httpStatus):
                stats.recordRejected(httpStatus: httpStatus)
            case .failed(let text):
                stats.recordFailure(text)
            case .cancelled:
                stats.markCancelled()
            }
        }
        completion(result)
    }

    /// Fehler des Transports als kurzer Text. Nur der Code, nie die Beschreibung (die kann
    /// eine URL mit Pfad enthalten).
    private func transportFailure(_ error: Error?) -> String {
        guard let nsError = error as NSError? else { return "network" }
        return "network(\(nsError.code))"
    }

    /// Ob ein Transportfehler die Antwort auf ein vom System beendetes Hintergrund-Budget ist.
    private func isBackgroundExpirationCancel(_ error: Error?) -> Bool {
        guard let nsError = error as NSError?,
              nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled else { return false }
        return cancellationAttribution() == "backgroundExpiration"
    }

    /// Fork (review LO-12): what may be logged about an error response. Size plus, for a
    /// FastAPI/Pydantic body, `detail[].type` and `detail[].loc` (field paths, no values). Never
    /// `msg` or `input`.
    internal static func errorBodySummary(_ data: Data) -> String {
        var summary = "\(data.count) bytes"
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = object["detail"] as? [[String: Any]], !details.isEmpty else { return summary }
        let shown = details.prefix(5).map { detail -> String in
            let type = detail["type"] as? String ?? "?"
            let loc = (detail["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".") ?? "?"
            return "\(type)@\(loc)"
        }
        summary += ", detail: " + shown.joined(separator: ", ")
        if details.count > shown.count { summary += ", +\(details.count - shown.count)" }
        return summary
    }

    internal func uploadCombinedPayloadReportingStatus(
        payload: [String: Any],
        endpoint: URL,
        credential: String,
        generation: Int,
        completion: @escaping (UploadResult) -> Void
    ) {
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            self.logMessage("Failed to serialize payload")
            finishUpload(.failed("serialize"), generation: generation, completion: completion)
            return
        }
        
        let requestId = UUID().uuidString
        var req = buildRequest(url: endpoint, credential: credential, requestId: requestId)
        req.httpBody = payloadData
        
        self.logPayloadSummary(payloadData, label: "Sending")
        
        let task = foregroundSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            
            let completedTask = self.untrackSyncUpload(requestId: requestId)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            self.logUploadOutcome(
                stage: "sync", requestId: requestId, declaredBytes: payloadData.count,
                task: completedTask, statusCode: statusCode, error: error
            )
            
            if self.isSyncCancelled(generation: generation) {
                self.finishUpload(.cancelled, generation: generation, completion: completion)
                return
            }
            
            if error != nil {
                self.markNetworkError()
                if self.isBackgroundExpirationCancel(error) {
                    // Die Hintergrundzeit hat den Upload beendet, kein Netzfehler: der Lauf
                    // ist `partial(backgroundTime)`, nicht `failed`.
                    self.runStats(for: generation)?.markBudgetHit(.backgroundTime)
                    self.finishUpload(.cancelled, generation: generation, completion: completion)
                } else {
                    self.finishUpload(.failed(self.transportFailure(error)), generation: generation, completion: completion)
                }
                return
            }
            
            guard let statusCode = statusCode else {
                self.logMessage("No HTTP response")
                self.markNetworkError()
                self.finishUpload(.failed("no HTTP response"), generation: generation, completion: completion)
                return
            }
            
            if OpenWearablesHealthSDK.syncShouldAdvance(afterHTTPStatus: statusCode) {
                self.finishUpload(.accepted(statusCode), generation: generation, completion: completion)
                return
            }
            
            if statusCode == 401 {
                self.handle401ForUpload(
                    payloadData: payloadData,
                    endpoint: endpoint,
                    requestId: requestId,
                    generation: generation
                ) { result in
                    self.finishUpload(result, generation: generation, completion: completion)
                }
                return
            }
            
            if let data = data, !data.isEmpty {
                // Fork (review LO-12): never the body itself. A 422 from FastAPI/Pydantic echoes the
                // rejected value in `input`, i.e. health data, and this line reaches the app's log.
                self.logDiagnostic("HTTP \(statusCode) - \(OpenWearablesHealthSDK.errorBodySummary(data))")
            }
            
            if (400...499).contains(statusCode) {
                self.finishUpload(.rejected(statusCode), generation: generation, completion: completion)
            } else {
                self.finishUpload(.failed("HTTP \(statusCode)"), generation: generation, completion: completion)
            }
        }
        
        trackSyncUpload(task, requestId: requestId, generation: generation)
        task.resume()
    }
    
    /// Handles 401 response for combined uploads. The retry reuses `requestId` so both
    /// attempts are one story in the server-side logs.
    private func handle401ForUpload(
        payloadData: Data,
        endpoint: URL,
        requestId: String,
        generation: Int,
        completion: @escaping (UploadResult) -> Void
    ) {
        if isApiKeyAuth {
            self.logMessage("Got 401 with apiKey auth")
            self.emitAuthError(statusCode: 401)
            completion(.failed("auth 401"))
            return
        }
        
        self.logMessage("Got 401, refreshing token...")
        
        self.attemptTokenRefresh { [weak self] result in
            guard let self = self else { return }
            
            if self.isSyncCancelled(generation: generation) {
                completion(.cancelled)
                return
            }
            
            switch result {
            case .success:
                guard let newCredential = self.authCredential else {
                    self.logMessage("Token refreshed but no credential available")
                    completion(.failed("auth: no credential"))
                    return
                }
                self.logMessage("Token refreshed, retrying...")
                
                let retryKey = "\(requestId)#retry"
                var retryReq = self.buildRequest(url: endpoint, credential: newCredential, requestId: requestId)
                retryReq.httpBody = payloadData
                
                let retryTask = self.foregroundSession.dataTask(with: retryReq) { [weak self] _, retryResponse, retryError in
                    guard let self = self else { return }
                    
                    let completedTask = self.untrackSyncUpload(requestId: retryKey)
                    let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode
                    self.logUploadOutcome(
                        stage: "sync-401-retry", requestId: requestId, declaredBytes: payloadData.count,
                        task: completedTask, statusCode: retryStatus, error: retryError
                    )
                    
                    if self.isSyncCancelled(generation: generation) {
                        completion(.cancelled)
                        return
                    }
                    
                    if retryError != nil {
                        self.markNetworkError()
                        if self.isBackgroundExpirationCancel(retryError) {
                            self.runStats(for: generation)?.markBudgetHit(.backgroundTime)
                            completion(.cancelled)
                        } else {
                            completion(.failed(self.transportFailure(retryError)))
                        }
                        return
                    }
                    
                    if let retryStatus = retryStatus, OpenWearablesHealthSDK.syncShouldAdvance(afterHTTPStatus: retryStatus) {
                        completion(.accepted(retryStatus))
                        return
                    }
                    
                    if let retryStatus = retryStatus, (401...403).contains(retryStatus) {
                        self.emitAuthError(statusCode: retryStatus)
                    }
                    
                    switch retryStatus {
                    case 401?:
                        completion(.failed("auth 401"))
                    case let status? where (400...499).contains(status):
                        completion(.rejected(status))
                    case let status?:
                        completion(.failed("HTTP \(status)"))
                    case nil:
                        completion(.failed("no HTTP response"))
                    }
                }
                
                self.trackSyncUpload(retryTask, requestId: retryKey, generation: generation)
                retryTask.resume()
                
            case .authFailure:
                self.logMessage("Token refresh rejected - auth is invalid")
                self.emitAuthError(statusCode: 401)
                completion(.failed("auth 401"))
                
            case .networkError:
                self.logMessage("Token refresh failed (network) - will retry later")
                self.markNetworkError()
                completion(.failed("network"))
            }
        }
    }
    
    // MARK: - Handle successful upload
    internal func handleSuccessfulUpload(itemPath: String, anchorPath: String?, wasFullExport: Bool) {
        guard let itemData = try? Data(contentsOf: URL(fileURLWithPath: itemPath)),
              let item = try? JSONDecoder().decode(OutboxItem.self, from: itemData) else {
            logMessage("Failed to read item for anchor saving")
            return
        }
        
        // signOut() clears credentials and the outbox asynchronously relative to
        // background-session callbacks. Do not persist anchors or fullDone for a
        // user who is gone, or for an item that belongs to a previous session.
        guard OpenWearablesHealthSdkKeychain.hasSession(), item.userKey == userKey() else {
            if let anchorPath = anchorPath, !anchorPath.isEmpty {
                try? FileManager.default.removeItem(atPath: anchorPath)
            }
            try? FileManager.default.removeItem(atPath: itemPath)
            return
        }
        
        // Fork (Plan 09-03): Ein Anchor aus einer Outbox-Datei wird nur gespeichert, wenn es für
        // (Typ, Nutzer) noch keinen gibt. Seit 0.14 schreibt nichts mehr in die Outbox, jede Datei
        // dort ist also älter als der heutige Anchor. Ihn zu überschreiben, setzte den Anchor zurück
        // und löste beim nächsten Lauf eine Flut aus (ROADMAP: Anchors werden nie zurückgesetzt).
        // Die Ladung selbst geht trotzdem hinaus; eine erneute Zustellung ist harmlos, der Server
        // führt Upserts über Quelle, Typ und Zeitpunkt.
        if let anchorPath = anchorPath, !anchorPath.isEmpty {
            var saved = 0
            var kept = 0
            let saveIfAbsent = { (anchorData: Data, typeId: String) in
                let key = self.anchorKey(typeIdentifier: typeId, userKey: item.userKey)
                if self.defaults.data(forKey: key) != nil {
                    kept += 1
                } else {
                    self.saveAnchorData(anchorData, typeIdentifier: typeId, userKey: item.userKey)
                    saved += 1
                }
            }
            if item.typeIdentifier == "combined" {
                if let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)),
                   let anchorsDict = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, NSData.self], from: anchorData) as? [String: Data] {
                    for (typeId, anchorData) in anchorsDict {
                        saveIfAbsent(anchorData, typeId)
                    }
                }
            } else {
                if let anchorData = try? Data(contentsOf: URL(fileURLWithPath: anchorPath)) {
                    saveIfAbsent(anchorData, item.typeIdentifier)
                }
            }
            if saved > 0 || kept > 0 {
                // Nur Zahlen, keine Typen (LO-12).
                logDiagnostic("Outbox: saved anchors for \(saved) types, kept \(kept) existing")
            }

            try? FileManager.default.removeItem(atPath: anchorPath)
        }
        
        if wasFullExport {
            let fullDoneKey = "fullDone.\(item.userKey)"
            defaults.set(true, forKey: fullDoneKey)
            defaults.synchronize()
            logMessage("Marked full export complete")
        }
        
        try? FileManager.default.removeItem(atPath: itemPath)
    }

    // MARK: - Clear outbox
    internal func clearOutbox() {
        let dir = outboxDir()
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        logMessage("Cleared outbox")
    }

    // MARK: - Retry pending items
    
    /// Minimum file age before an outbox item is retried (the original upload may
    /// still be in flight).
    private static let outboxMinRetryAge: TimeInterval = 30
    /// Items older than this are dropped - the data is re-fetched from HealthKit by
    /// the regular sync anyway, so there is no point in re-sending week-old batches.
    private static let outboxMaxItemAge: TimeInterval = 7 * 24 * 3600
    
    /// Retries pending outbox items through the *background* URLSession.
    ///
    /// The sync path no longer enqueues items. This only drains leftovers from
    /// earlier SDK versions and then expires them.
    /// - uploads go through the background session (survive suspension/kill),
    /// - the session is limited to one connection per host, so items go out serially,
    /// - a retry pass is skipped while a regular sync is running,
    /// - only one retry pass can run at a time,
    /// - items already enqueued in the background session are not enqueued again.
    internal func retryOutboxIfPossible() {
        guard let endpoint = self.syncEndpoint, let credential = self.authCredential else { return }
        
        if isSyncInProgress {
            logMessage("Outbox retry skipped - sync in progress")
            return
        }
        
        outboxRetryLock.lock()
        if isRetryingOutbox {
            outboxRetryLock.unlock()
            return
        }
        isRetryingOutbox = true
        outboxRetryLock.unlock()
        
        session.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            defer {
                self.outboxRetryLock.lock()
                self.isRetryingOutbox = false
                self.outboxRetryLock.unlock()
            }
            
            // Payloads already queued in the background session (possibly from a
            // previous app run) must not be enqueued a second time.
            let inFlightPayloadPaths = Set(tasks.compactMap { task -> String? in
                let parts = task.taskDescription?.split(separator: "|", omittingEmptySubsequences: false)
                guard let parts = parts, parts.count > 1 else { return nil }
                return String(parts[1])
            })
            
            let dir = self.outboxDir()
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            
            let itemFiles = files.filter {
                $0.pathExtension == "json" &&
                ($0.lastPathComponent.hasPrefix("item_") || $0.lastPathComponent.hasPrefix("combined_item_"))
            }
            
            var enqueued = 0
            for itemURL in itemFiles {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: itemURL.path),
                      let mdate = attrs[.modificationDate] as? Date else { continue }
                let age = Date().timeIntervalSince(mdate)
                if age < Self.outboxMinRetryAge { continue }
                
                guard let data = try? Data(contentsOf: itemURL),
                      let item = try? JSONDecoder().decode(OutboxItem.self, from: data) else {
                    try? FileManager.default.removeItem(at: itemURL)
                    continue
                }
                
                // Fork (Plan 09-03): Pfade aus einem früheren App-Container werden in der heutigen
                // Outbox gesucht (`resolveOutboxPath`). Ab hier gelten nur die aufgelösten Pfade:
                // Ablauf, Prüfung auf laufende Uploads und `taskDescription`, aus der der Delegate
                // nach der Antwort aufräumt.
                guard let payloadPath = self.resolveOutboxPath(item.payloadPath) else {
                    // Orphaned metadata without a payload - clean up
                    try? FileManager.default.removeItem(at: itemURL)
                    continue
                }
                let payloadURL = URL(fileURLWithPath: payloadPath)
                let anchorPath = item.anchorPath.flatMap { self.resolveOutboxPath($0) }

                if age > Self.outboxMaxItemAge {
                    self.logMessage("Outbox: dropping stale item (\(Int(age / 3600))h old)")
                    try? FileManager.default.removeItem(at: payloadURL)
                    if let anchorPath = anchorPath {
                        try? FileManager.default.removeItem(atPath: anchorPath)
                    }
                    try? FileManager.default.removeItem(at: itemURL)
                    continue
                }
                
                if inFlightPayloadPaths.contains(payloadURL.path) { continue }
                
                let itemId = itemURL.deletingPathExtension().lastPathComponent
                let req = self.buildRequest(
                    url: endpoint,
                    credential: credential,
                    requestId: UUID().uuidString,
                    outboxItemId: itemId
                )
                
                let task = self.session.uploadTask(with: req, fromFile: payloadURL)
                task.taskDescription = [itemURL.path, payloadURL.path, anchorPath ?? "", "\(self.currentSessionEpoch())"].joined(separator: "|")
                task.resume()
                enqueued += 1
            }
            
            if enqueued > 0 {
                self.logMessage("Outbox: enqueued \(enqueued) pending upload(s) to background session")
            }
        }
    }
}
