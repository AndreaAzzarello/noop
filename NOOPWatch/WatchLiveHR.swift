import Foundation
import Combine
#if canImport(HealthKit)
import HealthKit
#endif

// MARK: - WatchLiveHR — the watch's own live heart rate
//
// This is the one number the watch measures itself rather than receiving from the phone: the wrist's
// current heart rate, read from HealthKit via a streaming HKAnchoredObjectQuery. It is GUARDED at every
// step. If HealthKit is unavailable or the user denied heart-rate read access, `bpm` stays nil and
// `denied` flips true so the glance can honestly show "HR unavailable" instead of a fake number.
//
// We deliberately keep this lightweight: an anchored query that delivers the newest samples while the app
// is foregrounded, no HKWorkoutSession. A full session (and the higher-fidelity in-workout stream) is M4.
final class WatchLiveHR: ObservableObject {

    /// The most recent heart rate in whole BPM, or nil if we have no reading yet.
    @Published private(set) var bpm: Int?
    /// True once we know HealthKit is unavailable or read access was denied. Drives "HR unavailable".
    @Published private(set) var denied: Bool = false

    #if canImport(HealthKit)
    private let store = HKHealthStore()
    private let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)
    private var query: HKAnchoredObjectQuery?
    // Battery: tracks whether the glance currently wants HR, so a late authorization callback cannot
    // start streaming after stop() and repeated start() calls stay idempotent.
    private var wantsStreaming = false
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())
    #endif

    /// Ask for permission (idempotent) and start streaming. Call when the glance appears.
    func start() {
        #if canImport(HealthKit)
        wantsStreaming = true
        guard query == nil else { return }
        guard HKHealthStore.isHealthDataAvailable(), let hrType else {
            denied = true
            return
        }
        // Read-only — we never write HR from the watch. If the user declines, the streaming query simply
        // returns no samples and we surface "HR unavailable".
        store.requestAuthorization(toShare: [], read: [hrType]) { [weak self] granted, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if granted {
                    self.beginStreaming()
                } else {
                    self.denied = true
                }
            }
        }
        #else
        denied = true
        #endif
    }

    /// Tear the query down when the glance disappears so we are not streaming HR in the background.
    func stop() {
        #if canImport(HealthKit)
        wantsStreaming = false
        if let query { store.stop(query) }
        query = nil
        #endif
    }

    #if canImport(HealthKit)
    private func beginStreaming() {
        guard let hrType, query == nil, wantsStreaming else { return }
        // Battery: the old anchored query (no predicate, no limit) delivered the ENTIRE heart-rate history
        // on every start just to display the newest value. Seed the readout with a single newest-sample
        // read instead, then stream only samples from the last few minutes onwards.
        let latest = HKSampleQuery(sampleType: hrType, predicate: nil, limit: 1,
                                   sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate,
                                                                      ascending: false)]) { [weak self] _, samples, _ in
            self?.handle(samples)
        }
        store.execute(latest)

        // Small look-back window (not "now") so a sample the watch writes slightly late is still delivered.
        let since = Date().addingTimeInterval(-5 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        let q = HKAnchoredObjectQuery(type: hrType,
                                      predicate: predicate,
                                      anchor: nil,
                                      limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, _ in
            self?.handle(samples)
        }
        q.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.handle(samples)
        }
        query = q
        store.execute(q)
    }

    /// Pull the newest sample out of a batch and publish its BPM. Reads can arrive on a background queue,
    /// so publish on the main actor.
    private func handle(_ samples: [HKSample]?) {
        guard let latest = (samples as? [HKQuantitySample])?
            .max(by: { $0.endDate < $1.endDate }) else { return }
        let value = latest.quantity.doubleValue(for: bpmUnit)
        let rounded = Int(value.rounded())
        DispatchQueue.main.async {
            self.bpm = rounded
            self.denied = false
        }
    }
    #endif
}
