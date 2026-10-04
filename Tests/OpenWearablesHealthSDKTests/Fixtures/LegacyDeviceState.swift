import Foundation
import HealthKit

/// Anonymisierte Fixture des Sync-Zustands, den das iPhone 18 Pro vor dem Update auf
/// 0.15 hatte (Messung vom 04.10.2026).
///
/// Herkunft: **aus der Recherche vom 04.10.2026, nicht aus frischem Schnappschuss.** Beim
/// Anlegen der Fixture war das iPhone für `devicectl` nicht erreichbar (Status
/// `unavailable`), ein Container-Abzug war deshalb nicht möglich. Übernommen sind die
/// gemessenen Strukturmerkmale:
///
/// - 40 Anchors unter `anchor.user.<id>.<HK-Identifier>`, ein Anchor je abfragbarem Typ
/// - `fullDone.user.none = false`: `signIn()` ruft `resetAllAnchors()` auf, bevor die
///   Zugangsdaten gespeichert sind, und schreibt `fullDone` deshalb unter `user.none`
/// - **kein** `fullDone.user.<id>`
/// - keine `state.json`, also keine offene Sitzung
///
/// Nicht aus der Messung, sondern abgeleitet beziehungsweise synthetisch:
///
/// - Die 40 Typ-Identifier folgen der Typliste von 0.13.2: 43 Fälle in `HealthDataType`,
///   abzüglich zweier Doppelbelegungen (`restingEnergy`, `bloodOxygen`) und der nicht
///   abfragbaren Blutdruck-Korrelation. Das ergibt dieselbe Zahl wie die 40 gemessenen
///   Anchors, ist aber keine Auflistung der echten Schlüssel.
/// - Die `rowid`-Werte sind erfunden (aufsteigend 1000, 2000 ...). Gemessen ist nur, dass
///   Typen ohne je einen Eintrag auf 0 stehen; welche Typen das am Gerät waren, ist nicht
///   erfasst. Die sechs Nullen hier (Zyklus, Blutzucker, Insulin) sind eine Annahme und
///   für die Adoption ohne Bedeutung, denn sie schaut nur auf das Vorhandensein.
///
/// Absichtlich nicht enthalten: echte User-ID, `clientToken`, Ledger-Inhalt (Gewichts-
/// messungen). Rohdaten eines Schnappschusses gehören nie ins Repo.
///
/// Wird die Fixture später aus einem frischen Schnappschuss ersetzt, nur die Listen und
/// diesen Kopf anpassen; `install(into:)` und die Tests bleiben.
enum LegacyDeviceState {

    /// Synthetische Nutzer-ID, nicht die des Geräts.
    static let userId = "00000000-0000-4000-8000-0000000000a1"

    /// Schlüsselteil, wie ihn das SDK aus `userId` bildet.
    static let userKey = "user.\(userId)"

    /// Wert von `fullDone.user.none` am Gerät.
    static let fullDoneNoneValue = false

    /// Am Gerät fehlte `fullDone.user.<id>` vollständig.
    static let hasFullDoneForUser = false

    /// Typ-Identifier mit synthetischer `rowid`; 0 bedeutet "Typ ohne je einen Eintrag".
    static let anchors: [(typeIdentifier: String, rowid: Int)] = [
        ("HKQuantityTypeIdentifierStepCount", 1000),
        ("HKQuantityTypeIdentifierDistanceWalkingRunning", 2000),
        ("HKQuantityTypeIdentifierDistanceCycling", 3000),
        ("HKQuantityTypeIdentifierFlightsClimbed", 4000),
        ("HKQuantityTypeIdentifierWalkingSpeed", 5000),
        ("HKQuantityTypeIdentifierWalkingStepLength", 6000),
        ("HKQuantityTypeIdentifierWalkingAsymmetryPercentage", 7000),
        ("HKQuantityTypeIdentifierWalkingDoubleSupportPercentage", 8000),
        ("HKQuantityTypeIdentifierSixMinuteWalkTestDistance", 9000),
        ("HKQuantityTypeIdentifierActiveEnergyBurned", 10000),
        ("HKQuantityTypeIdentifierBasalEnergyBurned", 11000),
        ("HKQuantityTypeIdentifierHeartRate", 12000),
        ("HKQuantityTypeIdentifierRestingHeartRate", 13000),
        ("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", 14000),
        ("HKQuantityTypeIdentifierVO2Max", 15000),
        ("HKQuantityTypeIdentifierOxygenSaturation", 16000),
        ("HKQuantityTypeIdentifierRespiratoryRate", 17000),
        ("HKQuantityTypeIdentifierBodyMass", 18000),
        ("HKQuantityTypeIdentifierHeight", 19000),
        ("HKQuantityTypeIdentifierBodyMassIndex", 20000),
        ("HKQuantityTypeIdentifierBodyFatPercentage", 21000),
        ("HKQuantityTypeIdentifierLeanBodyMass", 22000),
        ("HKQuantityTypeIdentifierWaistCircumference", 23000),
        ("HKQuantityTypeIdentifierBodyTemperature", 24000),
        ("HKQuantityTypeIdentifierBloodGlucose", 0),
        ("HKQuantityTypeIdentifierInsulinDelivery", 0),
        ("HKQuantityTypeIdentifierBloodPressureSystolic", 25000),
        ("HKQuantityTypeIdentifierBloodPressureDiastolic", 26000),
        ("HKCategoryTypeIdentifierSleepAnalysis", 27000),
        ("HKCategoryTypeIdentifierMindfulSession", 28000),
        ("HKCategoryTypeIdentifierMenstrualFlow", 0),
        ("HKCategoryTypeIdentifierCervicalMucusQuality", 0),
        ("HKCategoryTypeIdentifierOvulationTestResult", 0),
        ("HKCategoryTypeIdentifierSexualActivity", 0),
        ("HKQuantityTypeIdentifierDietaryEnergyConsumed", 29000),
        ("HKQuantityTypeIdentifierDietaryCarbohydrates", 30000),
        ("HKQuantityTypeIdentifierDietaryProtein", 31000),
        ("HKQuantityTypeIdentifierDietaryFatTotal", 32000),
        ("HKQuantityTypeIdentifierDietaryWater", 33000),
        ("HKWorkoutTypeIdentifier", 34000),
    ]

    /// Schlüssel eines Anchors, wie ihn `OpenWearablesHealthSDK.anchorKey(typeIdentifier:userKey:)` bildet.
    static func anchorKey(_ typeIdentifier: String) -> String {
        "anchor.\(userKey).\(typeIdentifier)"
    }

    /// Schreibt den Altzustand in `defaults`: je Typ ein Anchor-Archiv im Format des SDK
    /// (`NSKeyedArchiver`, secure coding) und `fullDone.user.none = false`. Schreibt
    /// ausdrücklich **kein** `fullDone.<userKey>`.
    static func install(into defaults: UserDefaults) {
        for entry in anchors {
            let anchor = HKQueryAnchor(fromValue: entry.rowid)
            guard let data = try? NSKeyedArchiver.archivedData(
                withRootObject: anchor, requiringSecureCoding: true
            ) else {
                preconditionFailure("Anchor für \(entry.typeIdentifier) ließ sich nicht archivieren")
            }
            defaults.set(data, forKey: anchorKey(entry.typeIdentifier))
        }
        defaults.set(fullDoneNoneValue, forKey: "fullDone.user.none")
    }
}
