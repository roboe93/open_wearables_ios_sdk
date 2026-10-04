import Foundation

// Fork-Zusatz (roboe93), Plan 05-06. Welche Typen in der Live-Spur zuerst dran sind.
//
// Warum es das gibt: Das Original (0.15) verteilt ein Chunk gleichmäßig auf alle Typen
// (`chunkLimit / Anzahl`). Im Hintergrund sind das 100/42 = 2 Datensätze je Typ und Runde.
// Nach einer gesperrten Nacht brauchen dichte Typen (Herzfrequenz, Schritte, Energie)
// tausende Runden, und ein Gewicht oder der Schlaf wartet dahinter. Deshalb Stufen:
// Stufe A sind seltene, wertvolle Typen und gehen bis zum Ende ihrer Änderungen vorweg
// in gemeinsamen Paketen raus, Stufe B sind die dichten Typen danach in Chunks.
//
// Reine Zeichenketten, kein HealthKit-Import: der Kern bleibt ohne Gerät prüfbar.

struct LaneOrdering {

    /// Reihenfolge der Vorrangtypen. Alles hier steht vor allem anderen in Stufe A.
    static let priority: [String] = [
        "HKCategoryTypeIdentifierSleepAnalysis",
        "HKWorkoutTypeIdentifier",
        "HKQuantityTypeIdentifierBodyMass",
        "HKQuantityTypeIdentifierBodyFatPercentage",
        "HKQuantityTypeIdentifierLeanBodyMass",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "HKQuantityTypeIdentifierRestingHeartRate",
    ]

    /// Dichte Typen (Stufe B): viele Samples je Tag, einzeln wenig wert.
    ///
    /// Startliste, am Gerät nicht abgeglichen (04.10.2026): Ein Baseline-Schnappschuss mit
    /// `ow.typeTransfers` aus Plan 05-02 lag zum Zeitpunkt dieses Plans nicht vor, das iPhone
    /// war nicht erreichbar. Sobald er da ist, gehören Typen mit mehr als 5.000 übertragenen
    /// Datensätzen hierher. Eine falsche Zuordnung verzögert einen Typ, sie verliert nichts.
    static let dense: Set<String> = [
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierBasalEnergyBurned",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierDistanceCycling",
        "HKQuantityTypeIdentifierPhysicalEffort",
        "HKQuantityTypeIdentifierRunningPower",
        "HKQuantityTypeIdentifierRunningSpeed",
        "HKQuantityTypeIdentifierRunningStrideLength",
        "HKQuantityTypeIdentifierRunningVerticalOscillation",
        "HKQuantityTypeIdentifierRunningGroundContactTime",
        "HKQuantityTypeIdentifierCyclingPower",
        "HKQuantityTypeIdentifierCyclingCadence",
        "HKQuantityTypeIdentifierCyclingSpeed",
        "HKQuantityTypeIdentifierEnvironmentalAudioExposure",
        "HKQuantityTypeIdentifierHeadphoneAudioExposure",
        "HKQuantityTypeIdentifierWalkingSpeed",
        "HKQuantityTypeIdentifierWalkingStepLength",
        "HKQuantityTypeIdentifierWalkingAsymmetryPercentage",
        "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",
        "HKQuantityTypeIdentifierAppleExerciseTime",
        "HKQuantityTypeIdentifierAppleStandTime",
        "HKQuantityTypeIdentifierFlightsClimbed",
    ]

    /// Teilt Typen in Stufe A (zuerst) und Stufe B. Die Vorrangtypen stehen in ihrer festen
    /// Reihenfolge am Anfang von Stufe A, danach alle übrigen nicht dichten Typen in der
    /// Reihenfolge der Eingabe. Ein unbekannter Typ landet in Stufe A: unbekannt heißt eher
    /// selten als dicht, und ein zu früh gelieferter Typ kostet nichts. Doppelte fallen weg.
    func split(_ typeIds: [String]) -> (stageA: [String], stageB: [String]) {
        var seen = Set<String>()
        let unique = typeIds.filter { seen.insert($0).inserted }
        let present = Set(unique)
        let prioritySet = Set(LaneOrdering.priority)

        let stageA = LaneOrdering.priority.filter { present.contains($0) }
            + unique.filter { !prioritySet.contains($0) && !LaneOrdering.dense.contains($0) }
        let stageB = unique.filter { !prioritySet.contains($0) && LaneOrdering.dense.contains($0) }
        return (stageA, stageB)
    }
}
