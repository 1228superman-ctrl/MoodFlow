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
    private(set) var enabled = UserDefaults.standard.bool(forKey: "health-enabled")

    private var types: [HKSampleType] { [heart, hrv, sleep] }

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthKit unavailable", code: 1)
        }
        try await store.requestAuthorization(toShare: [], read: Set(types.map { $0 as HKObjectType }))
        enabled = true
        UserDefaults.standard.set(true, forKey: "health-enabled")
        installObservers()
    }

    func installObservers() {
        guard enabled, HKHealthStore.isHealthDataAvailable(), queries.isEmpty else { return }
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, done, error in
                let received = Date()
                Task { @MainActor in
                    defer { done() }
                    let phase = Probe.shared.isActive ? "前台" : "非前台"
                    do {
                        if let error { throw error }
                        await self.refreshMetrics()
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

    func readAll() async { await refreshMetrics() }

    private func refreshMetrics() async {
        guard enabled else { return }
        do {
            let now = Date()
            let today = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-24 * 3600), end: now)
            async let pulse = values(heart, unit: bpm, predicate: today, limit: 2)
            async let variability = values(hrv, unit: milliseconds, predicate: today, limit: 1)
            let sleepQuery = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: sleep, predicate: today)],
                sortDescriptors: [SortDescriptor(\.startDate)])
            let segments = try await sleepQuery.result(for: store).filter {
                HKCategoryValueSleepAnalysis.allAsleepValues.contains(
                    HKCategoryValueSleepAnalysis(rawValue: $0.value) ?? .inBed)
            }
            var seconds = 0.0
            let start = now.addingTimeInterval(-24 * 3600)
            var coveredThrough = start
            for segment in segments {
                let end = min(segment.endDate, now)
                seconds += max(0, end.timeIntervalSince(max(coveredThrough, segment.startDate)))
                coveredThrough = max(coveredThrough, end)
            }
            let pulses = try await pulse
            let hrvValue = (try await variability).first
            let metrics = Physiology(bpm: pulses.first,
                delta: pulses.count == 2 ? pulses[0] - pulses[1] : nil,
                hrv: hrvValue, sleepHours: segments.isEmpty ? nil : seconds / 3600)
            if metrics != Probe.shared.physiology, metrics.bpm != nil || metrics.hrv != nil || metrics.sleepHours != nil {
                Probe.shared.add(Entry(kind: "生理数据", detail: "Apple 健康 · 最近 24 小时", physiology: metrics))
            }
        } catch {
            Probe.shared.add(Entry(kind: "查询失败", detail: "\((error as NSError).domain)/\((error as NSError).code)"))
        }
    }

    private func values(_ type: HKQuantityType, unit: HKUnit, predicate: NSPredicate, limit: Int) async throws -> [Double] {
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: limit)
        return try await query.result(for: store).map { $0.quantity.doubleValue(for: unit) }
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
                let current = Probe.shared.physiology
                Probe.shared.variation(id: newest.uuid.uuidString, time: newest.endDate,
                    detail: "心率 \(delta > 0 ? "上升" : "下降") \(Int(abs(delta))) bpm",
                    physiology: Physiology(bpm: value, delta: delta, hrv: current?.hrv, sleepHours: current?.sleepHours))
            }
        }
        return "\(label) \(value.formatted(.number.precision(.fractionLength(1)))) \(isHeart ? "bpm" : "ms") · 样本 \(newest.endDate.ISO8601Format())"
    }
}
#endif
