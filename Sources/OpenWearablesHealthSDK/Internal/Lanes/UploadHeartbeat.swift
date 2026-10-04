import Foundation

// Fork-Zusatz (roboe93), Review 05 ME-02. Lebenszeichen, solange ein Upload Bytes bewegt.
//
// Warum es das gibt: Die Sperre verfällt nach 150 Sekunden ohne Lebenszeichen (`SyncLease`). Die
// Begründung "150 s liegen über dem Request-Timeout (120 s)" trug nicht: `timeoutIntervalForRequest`
// ist ein Leerlauf-Timeout, ein Upload, der Daten bewegt, darf bis zum Resource-Timeout von 600
// Sekunden laufen. Ein Vordergrundpaket mit 2.000 Datensätzen (rund 1,3 MB) braucht bei schwachem
// Mobilfunk länger als 150 Sekunden. Der nächste Auslöser übernahm dann den lebenden Lauf, brach
// genau diesen Upload ab und schickte dasselbe Paket wieder: ein Kreislauf ohne Fortschritt.
//
// Jetzt fragt ein Zeitgeber während des Uploads, ob seit dem letzten Blick Bytes geflossen sind
// (gesendet oder empfangen). Nur dann gibt er ein Lebenszeichen. Ein Upload, der hängt, hält die
// Sperre damit nicht: nach 150 Sekunden ohne Bewegung übernimmt der nächste Auslöser wie bisher.

/// Ruft `beat`, solange `progress` einen laufenden Upload mit neuen Bytes meldet.
final class UploadProgressHeartbeat {
    typealias Progress = () -> (running: Bool, bytes: Int64)

    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let progress: Progress
    private let beat: () -> Void

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastBytes: Int64 = 0
    private var finished = false

    init(
        interval: TimeInterval, queue: DispatchQueue = .global(qos: .utility),
        progress: @escaping Progress, beat: @escaping () -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.progress = progress
        self.beat = beat
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil, !finished else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    /// Ein Blick auf den Upload. Läuft er nicht mehr, endet der Zeitgeber.
    func tick() {
        let (running, bytes) = progress()
        guard running else {
            stop()
            return
        }
        lock.lock()
        let moved = !finished && bytes != lastBytes
        lastBytes = bytes
        lock.unlock()
        if moved { beat() }
    }

    func stop() {
        lock.lock()
        finished = true
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }
}

extension OpenWearablesHealthSDK {
    /// Wie oft ein laufender Upload auf Bewegung geprüft wird. Deutlich unter `SyncLease.leaseDuration`.
    /// `var` als Testnaht.
    internal static var uploadHeartbeatInterval: TimeInterval = 20
}
