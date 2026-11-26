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
    private let resting = HKQuantityType(.restingHeartRate)
    private let sleep = HKCategoryType(.sleepAnalysis)
    private let activeEnergy = HKQuantityType(.activeEnergyBurned)
    private let bpm = HKUnit.count().unitDivided(by: .minute())
    private let milliseconds = HKUnit.secondUnit(with: .milli)
    private var queries: [HKObserverQuery] = []
    private(set) var enabled = UserDefaults.standard.bool(forKey: "health-enabled")

    private var types: [HKSampleType] { [heart, hrv, sleep] }

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthKit unavailable", code: 1)
        }
        try await store.requestAuthorization(toShare: [], read: Set((types + [activeEnergy, resting]).map { $0 as HKObjectType }))
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
                    UserDefaults.standard.set(received, forKey: "monitor-callback")
                    if !Probe.shared.isActive { UserDefaults.standard.set(received, forKey: "monitor-background") }
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
        Task { await register() }
    }

    private var registering = false
    func register() async {
        guard enabled, !registering else { return }
        registering = true
        defer { registering = false }
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

    private var refreshing: Task<Void, Never>?
    private func refreshMetrics() async {
        if let refreshing { await refreshing.value; return }
        let task = Task { await readMetrics() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func readMetrics() async {
        guard enabled else { return }
        await Probe.shared.loadHistoryIfNeeded()
        do {
            let now = Date()
            let today = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-24 * 3600), end: now)
            
            let still = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyHeartRateMotionContext,
                allowedValues: [NSNumber(value: HKHeartRateMotionContext.sedentary.rawValue)])
            async let pulse = quantities(heart, predicate: today, limit: HKObjectQueryNoLimit)
            let month = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-28 * 86400), end: now)
            #if os(watchOS)
            async let restingPulse = quantities(resting, predicate: month, limit: 28)
            #endif
            async let variability = quantities(hrv, predicate: month, limit: 180)
            async let stillPulse = quantities(heart,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [month, still]), limit: 1500)
            let sleepQuery = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: sleep, predicate: HKQuery.predicateForSamples(
                    withStart: now.addingTimeInterval(-48 * 3600), end: now))],
                sortDescriptors: [SortDescriptor(\.startDate)])
            let segments = ((try? await sleepQuery.result(for: store)) ?? []).filter {
                HKCategoryValueSleepAnalysis.allAsleepValues.contains(
                    HKCategoryValueSleepAnalysis(rawValue: $0.value) ?? .inBed)
            }
            let start = now.addingTimeInterval(-24 * 3600)
            let intervals = segments.compactMap { sample -> DateInterval? in
                let end = min(sample.endDate, now)
                return sample.startDate < end ? DateInterval(start: sample.startDate, end: end) : nil
            }
            var seconds = 0.0
            var coveredThrough = start
            for interval in intervals {
                seconds += max(0, interval.end.timeIntervalSince(max(coveredThrough, interval.start)))
                coveredThrough = max(coveredThrough, interval.end)
            }
            let recovery = RecoverySleep.latest(in: intervals.filter {
                now.timeIntervalSince($0.end) <= RecoverySleep.maximumAge
            })
            async let calories = activeCalories(since: recovery?.end, until: now)
            let pulses: [HKQuantitySample]
            do {
                pulses = try await pulse
                let same = pulses.first?.endDate == (UserDefaults.standard.object(forKey: "monitor-heart-date") as? Date)
                UserDefaults.standard.set(pulses.isEmpty ? "查询完成，无可读心率" : (same ? "查询完成，暂无更新的可读心率" : "收到新的可读心率"), forKey: "monitor-heart-state")
                UserDefaults.standard.set(pulses.first?.endDate, forKey: "monitor-heart-date")
            } catch {
                pulses = []
                UserDefaults.standard.set("心率查询失败", forKey: "monitor-heart-state")
            }
            let variabilitySamples = (try? await variability) ?? []
            let hrvValue = variabilitySamples.first.flatMap { sample in
                sample.endDate >= start ? sample.quantity.doubleValue(for: milliseconds) : nil
            }
            let newest = pulses.first
            let latestBPM = newest?.quantity.doubleValue(for: bpm)
            let previous = pulses.dropFirst().first
            let stillSamples = (try? await stillPulse) ?? []
            let typicalStillBPM = newest.flatMap { sample in
                median(stillSamples.filter { (1800...).contains(sample.endDate.timeIntervalSince($0.endDate)) }, unit: bpm)
            }
            let metrics = Physiology(bpm: latestBPM,
                delta: latestBPM.flatMap { value in previous.map { value - $0.quantity.doubleValue(for: bpm) } },
                hrv: hrvValue, sleepHours: seconds > 0 ? seconds / 3600 : nil,
                sampledAt: newest?.endDate,
                heartSampleInterval: newest.flatMap { sample in previous.map { sample.endDate.timeIntervalSince($0.endDate) } },
                typicalStillBPM: typicalStillBPM,
                hrvRelativeToUsual: newest.flatMap { recentHRVRatio(variabilitySamples, at: $0.endDate) },
                inMotion: newest.flatMap(inMotion), recoverySleep: recovery, activeKilocalories: await calories)
            #if os(watchOS)
            let restHistory = (try? await restingPulse) ?? []
            let recent = pulses.reversed()
            var prior: [HKQuantitySample] = []
            var analyses: [Entry] = []
            let known = Set(Probe.shared.entries.filter { $0.analysis != nil }.map(\.id))
            for sample in recent {
                let date = sample.endDate
                prior.removeAll { date.timeIntervalSince($0.endDate) > 1200 }
                defer { prior.append(sample) }
                guard !known.contains(MoodEstimate.analysisID(sample.uuid)), date <= now else { continue }
                let value = sample.quantity.doubleValue(for: bpm)
                let history = stillSamples.filter { date.timeIntervalSince($0.endDate) >= 1800 }
                let hour = Calendar.current.component(.hour, from: date)
                let withinPeriod = history.filter {
                    let gap = abs(Calendar.current.component(.hour, from: $0.endDate) - hour)
                    return min(gap, 24-gap) <= 2
                }
                let recentHistory = withinPeriod.filter { date.timeIntervalSince($0.endDate) < 7 * 86400 }
                let pool = recentHistory.count >= 8 ? recentHistory : (withinPeriod.count >= 8 ? withinPeriod : history)
                let baseline = median(pool, unit: bpm) ?? restHistory.first(where: { $0.endDate <= date })?.quantity.doubleValue(for: bpm)
                let dispersion = baseline.flatMap { center -> Double? in
                    let deviations = pool.map { abs($0.quantity.doubleValue(for: bpm) - center) }.sorted()
                    return deviations.count >= 5 ? deviations[deviations.count / 2] : nil
                }
                let hrvHistory = variabilitySamples.filter { $0.endDate <= date }
                let sleepBefore = intervals.filter { $0.end <= date && date.timeIntervalSince($0.end) <= RecoverySleep.maximumAge }
                var physiology = Physiology(bpm: value, delta: prior.last.map { value - $0.quantity.doubleValue(for: bpm) },
                    hrv: hrvHistory.first.flatMap { date.timeIntervalSince($0.endDate) <= 1800 ? $0.quantity.doubleValue(for: milliseconds) : nil },
                    sampledAt: date, heartSampleInterval: prior.last.map { date.timeIntervalSince($0.endDate) },
                    typicalStillBPM: baseline, hrvRelativeToUsual: recentHRVRatio(hrvHistory, at: date), inMotion: inMotion(sample))
                if prior.count >= 2 {
                    let older = prior.prefix(max(1, prior.count / 2)).map { $0.quantity.doubleValue(for: bpm) }
                    physiology.trendBPM = (value + prior.last!.quantity.doubleValue(for: bpm)) / 2 - older.reduce(0,+) / Double(older.count)
                }
                physiology.stillSpread = dispersion
                physiology.asleep = intervals.contains { $0.contains(date) }
                physiology.recoverySleep = RecoverySleep.latest(in: sleepBefore)
                analyses.append(Entry(id: MoodEstimate.analysisID(sample.uuid), time: date, kind: "分析样本", detail: "手表采样", physiology: physiology))
            }
            Probe.shared.analyzeSamples(analyses)
            #endif
            if metrics != Probe.shared.physiology,
               metrics.bpm != nil || metrics.hrv != nil || metrics.sleepHours != nil || recovery != nil {
                Probe.shared.add(Entry(kind: "生理数据", detail: "Apple 健康 · 最近 24 小时", physiology: metrics))
            }
        }
    }

    private func activeCalories(since start: Date?, until end: Date) async -> Double? {
        guard let start, start < end else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: activeEnergy, predicate: predicate),
            options: .cumulativeSum)
        let statistics = try? await query.result(for: store)
        return statistics?.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private func quantities(_ type: HKQuantityType, predicate: NSPredicate, limit: Int) async throws -> [HKQuantitySample] {
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: limit)
        return try await query.result(for: store)
    }

    private func median(_ samples: [HKQuantitySample], unit: HKUnit) -> Double? {
        let values = samples.map { $0.quantity.doubleValue(for: unit) }.filter { $0.isFinite && $0 > 0 }.sorted()
        guard values.count >= 3 else { return nil }
        return (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
    }

    private func recentHRVRatio(_ samples: [HKQuantitySample], at time: Date) -> Double? {
        guard let recent = samples.first(where: { abs($0.endDate.timeIntervalSince(time)) <= 1800 }),
              let typical = median(samples.filter { time.timeIntervalSince($0.endDate) > 1800 }, unit: milliseconds) else { return nil }
        let value = recent.quantity.doubleValue(for: milliseconds)
        return value.isFinite && value > 0 ? value / typical : nil
    }

    private func inMotion(_ sample: HKQuantitySample) -> Bool? {
        guard let motion = sample.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber else { return nil }
        switch HKHeartRateMotionContext(rawValue: motion.intValue) {
        case .some(.active): return true
        case .some(.sedentary): return false
        default: return nil
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
                let current = Probe.shared.physiology
                let context = current?.sampledAt == newest.endDate ? current : nil
                Probe.shared.variation(id: newest.uuid.uuidString, time: newest.endDate,
                    detail: "心率 \(delta > 0 ? "上升" : "下降") \(Int(abs(delta))) bpm",
                    physiology: Physiology(bpm: value, delta: delta, hrv: current?.hrv, sleepHours: current?.sleepHours,
                        sampledAt: newest.endDate, heartSampleInterval: interval, typicalStillBPM: context?.typicalStillBPM,
                        hrvRelativeToUsual: context?.hrvRelativeToUsual, inMotion: inMotion(newest)))
            }
        }
        return "\(label) \(value.formatted(.number.precision(.fractionLength(1)))) \(isHeart ? "bpm" : "ms") · 样本 \(newest.endDate.ISO8601Format())"
    }
}
#endif
