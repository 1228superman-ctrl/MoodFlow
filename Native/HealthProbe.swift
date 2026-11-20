// Read-only query patterns adapted from Pulsr Shared/HealthKitSource.swift.
// Copyright (c) 2026 Pulsr contributors. See LICENSE-Pulsr.txt.
#if !MOODFLOW_SIM
import Foundation
import HealthKit

@MainActor
final class HealthProbe {
    static let shared = HealthProbe()
    private let store = HKHealthStore()
    private let heart = HKQuantityType(.heartRate)
    private let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    private let sleep = HKCategoryType(.sleepAnalysis)
    private let bpm = HKUnit.count().unitDivided(by: .minute())
    private let milliseconds = HKUnit.secondUnit(with: .milli)
    private var queries: [HKObserverQuery] = []

    private var types: [HKSampleType] { [heart, hrv, sleep] }

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthKit unavailable", code: 1)
        }
        try await store.requestAuthorization(toShare: [], read: Set(types.map { $0 as HKObjectType }))
    }

    func installObservers() {
        guard HKHealthStore.isHealthDataAvailable(), queries.isEmpty else { return }
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, done, error in
                let received = Date()
                Task { @MainActor in
                    defer { done() }
                    let phase = Probe.shared.isActive ? "前台" : "非前台"
                    do {
                        if let error { throw error }
                        let detail = try await self.read(type, observed: true)
                        Probe.shared.add(Entry(time: received, kind: "观察回调",
                            detail: "\(phase) · \(detail)"))
                    } catch {
                        Probe.shared.add(Entry(time: received, kind: "观察错误",
                            detail: "\(phase) · \(type.identifier) · \((error as NSError).domain)/\((error as NSError).code)"))
                    }
                }
            }
            queries.append(query)
            store.execute(query)
        }
    }

    func register() async {
        for type in types {
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
                Probe.shared.add(Entry(kind: "后台注册", detail: type.identifier))
            } catch {
                Probe.shared.add(Entry(kind: "后台注册失败",
                    detail: "\(type.identifier) · \((error as NSError).domain)/\((error as NSError).code)"))
            }
        }
    }

    func readAll() async {
        for type in types {
            do {
                let detail = try await read(type, observed: false)
                Probe.shared.add(Entry(kind: "手动查询", detail: detail))
            } catch {
                Probe.shared.add(Entry(kind: "查询失败",
                    detail: "\(type.identifier) · \((error as NSError).domain)/\((error as NSError).code)"))
            }
        }
    }

    private func read(_ type: HKSampleType, observed: Bool) async throws -> String {
        let now = Date()
        let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-7 * 86400),
            end: now, options: .strictEndDate)
        if type == sleep {
            let query = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: sleep, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
            guard let sample = try await query.result(for: store).first else {
                return "睡眠 · 近 7 天无可读样本"
            }
            return "睡眠阶段 \(sample.value) · \(Int(sample.endDate.timeIntervalSince(sample.startDate))) 秒 · 样本 \(sample.endDate.ISO8601Format())"
        }
        let isHeart = type == heart
        let quantity = isHeart ? heart : hrv
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: quantity, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: isHeart ? 2 : 1)
        let samples = try await query.result(for: store)
        let label = isHeart ? "心率" : "HRV SDNN"
        guard let newest = samples.first else { return "\(label) · 近 7 天无可读样本" }
        let value = newest.quantity.doubleValue(for: isHeart ? bpm : milliseconds)
        if observed, isHeart, samples.count == 2 {
            let previous = samples[1]
            let delta = value - previous.quantity.doubleValue(for: bpm)
            let interval = newest.endDate.timeIntervalSince(previous.endDate)
            let age = now.timeIntervalSince(newest.endDate)
            if abs(delta) >= 20, (1...300).contains(interval), (0...300).contains(age) {
                Probe.shared.variation(id: newest.uuid.uuidString,
                    detail: "HealthKit 心率变化 \(Int(delta)) bpm · 样本 \(newest.endDate.ISO8601Format())")
            }
        }
        return "\(label) \(value.formatted(.number.precision(.fractionLength(1)))) \(isHeart ? "bpm" : "ms") · 样本 \(newest.endDate.ISO8601Format())"
    }
}
#endif
