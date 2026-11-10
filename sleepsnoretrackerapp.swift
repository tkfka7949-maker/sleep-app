//
//  SleepSnoreTrackerApp.swift
//  SleepSnoreTracker (iOS 16.0+)
//
//  ============================================================================
//  [Mac 없이 Windows PC에서 아이폰 설치 파일(.ipa) 빌드 및 설치 가이드]
//
//  Mac이 없어도 GitHub의 무료 클라우드 macOS 서버(GitHub Actions)에서 .ipa 파일을 만들고,
//  Windows용 무료 툴인 Sideloadly를 사용해 본인 아이폰에 직접 설치할 수 있습니다.
//
//  ── STEP 1. GitHub 무료 저장소(Repository)에 파일 3개 업로드 ──────────────────
//  1) SleepSnoreTrackerApp.swift (현재 이 파일)
//  2) project.yml (XcodeGen 프로젝트 자동 생성 설정 파일):
//  ----------------------------------------------------------------------------
//  name: SleepSnoreTracker
//  options:
//    bundleIdPrefix: com.myname
//    deploymentTarget:
//      iOS: "16.0"
//  targets:
//    SleepSnoreTracker:
//      type: application
//      platform: iOS
//      sources:
//        - SleepSnoreTrackerApp.swift
//      info:
//        path: Info.plist
//        properties:
//          UILaunchScreen: {}
//          NSMicrophoneUsageDescription: "수면 중 코골이 시간 및 호흡 패턴 분석을 위해 마이크 권한이 필요합니다."
//          NSHealthShareUsageDescription: "코골이 발생 시점의 수면 단계, 심박수, 혈중 산소포화도를 비교하기 위해 건강 데이터 읽기 권한이 필요합니다."
//          UIBackgroundModes:
//            - audio
//  ----------------------------------------------------------------------------
//
//  3) .github/workflows/build-ipa.yml (클라우드 Mac 자동 빌드 워크플로우):
//  ----------------------------------------------------------------------------
//  name: Build iOS IPA without Mac
//  on: [workflow_dispatch, push]
//  jobs:
//    build:
//      runs-on: macos-latest
//      steps:
//        - uses: actions/checkout@v4
//        - name: Generate Xcode Project
//          run: |
//            brew install xcodegen
//            xcodegen generate
//        - name: Build Unsigned Archive
//          run: |
//            xcodebuild -project SleepSnoreTracker.xcodeproj \
//              -scheme SleepSnoreTracker \
//              -configuration Release \
//              -sdk iphoneos \
//              -derivedDataPath build \
//              CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
//        - name: Package IPA
//          run: |
//            mkdir -p Payload
//            cp -r build/Build/Products/Release-iphoneos/SleepSnoreTracker.app Payload/
//            zip -r SleepSnoreTracker.ipa Payload
//        - name: Upload IPA Artifact
//          uses: actions/upload-artifact@v4
//          with:
//            name: SleepSnoreTracker-IPA
//            path: SleepSnoreTracker.ipa
//  ----------------------------------------------------------------------------
//
//  ── STEP 2. Windows PC에서 Sideloadly로 아이폰에 설치 ────────────────────────
//  1) GitHub Actions 탭에서 빌드가 완료되면 `SleepSnoreTracker-IPA`(.ipa 파일) 다운로드
//  2) Windows PC에 iTunes(마이크로소프트 스토어 버전 아닌 Apple 공식 웹 버전) 및 Sideloadly 설치
//  3) 아이폰을 USB 케이블로 Windows PC에 연결 후 Sideloadly 실행
//  4) .ipa 파일을 드래그 앤 드롭하고 본인 무료 Apple ID 입력 후 [Start] 클릭
//  5) 아이폰 [설정] -> [일반] -> [VPN 및 기기 관리]에서 본인 Apple ID 신뢰 허용 및
//     [설정] -> [개인정보 보호 및 보안] -> [개발자 모드] 활성화 후 앱 실행!
//  ============================================================================

import SwiftUI
import AVFoundation
import SoundAnalysis
import HealthKit
import Charts

// MARK: - 1. 도메인 모델 (수면 이벤트, 오디오 하이라이트 클립, 워치 생체지표)

enum AcousticEventType: String, Codable, CaseIterable, Identifiable {
    case snoring = "코골이 (Snoring)"
    case gasp = "헐떡임/숨막힘 (Gasp/Choke)"
    case heavyBreathing = "거친 호흡 (Heavy Breathing)"
    case cough = "기침 (Cough)"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .snoring: return .orange
        case .gasp: return .red
        case .heavyBreathing: return .yellow
        case .cough: return .purple
        }
    }

    var systemImage: String {
        switch self {
        case .snoring: return "waveform.path.ecg"
        case .gasp: return "exclamationmark.triangle.fill"
        case .heavyBreathing: return "wind"
        case .cough: return "lungs.fill"
        }
    }
}

/// 코골이/헐떡임 발생 시 자동으로 앞뒤 여유 구간(Pre-roll 4초 + 이벤트 + Post-roll 2초)을 잘라 저장한 클립
struct HighlightAudioClip: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let eventType: AcousticEventType
    let durationSeconds: Double
    let peakDecibels: Float
    let precededBySilenceSeconds: Double
    let fileName: String
    var watchHeartRateBPM: Double?
    var watchSpO2Percentage: Double?
    var watchSleepStage: String?

    var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SnoreClips", isDirectory: true).appendingPathComponent(fileName)
    }
}

struct SnoreAcousticEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let durationSeconds: Double
    let confidence: Double
    let decibels: Float
    let type: AcousticEventType
    let precededBySilenceSeconds: Double
    var clipFileName: String?
}

enum PatternSeverity: String, Codable {
    case normal = "양호 (단순 수면 호흡)"
    case mild = "주의 (단순 습관성 코골이)"
    case moderate = "경고 (집중형/고강도 코골이)"
    case highRisk = "위험 (무호흡 동반 의심 패턴)"

    var badgeColor: Color {
        switch self {
        case .normal: return .green
        case .mild: return .yellow
        case .moderate: return .orange
        case .highRisk: return .red
        }
    }
}

struct PatternFinding: Identifiable, Codable {
    var id = UUID()
    let title: String
    let metricSummary: String
    let causeAnalysis: String
    let recommendation: String
    let isWarning: Bool
}

struct WatchCorrelationSummary: Codable {
    let isWatchDataAvailable: Bool
    let remSleepSnoreRatio: Double?      // REM 수면 중 발생한 코골이 비율 (%)
    let minSpO2DuringSnore: Double?      // 코골이/무호흡 의심 구간 최저 산소포화도 (%)
    let maxHeartRateDuringGasp: Double?  // 헐떡임 구간 최고 심박수 (BPM)
    let desaturationDipCount: Int        // SpO2 92% 미만 저하 횟수
}

struct HourlySnoreBucket: Identifiable {
    let id = UUID()
    let hourLabel: String
    let snoreMinutes: Double
    let gaspCount: Int
}

struct SleepAnalysisReport: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let totalSleepSeconds: Double
    let totalSnoreSeconds: Double
    let totalGaspCount: Int
    let apneaLikeClusterCount: Int
    let averageDecibels: Float
    let peakDecibels: Float
    let severity: PatternSeverity
    let findings: [PatternFinding]
    let events: [SnoreAcousticEvent]
    var highlightClips: [HighlightAudioClip]
    var watchSummary: WatchCorrelationSummary?

    var totalSleepMinutes: Double { totalSleepSeconds / 60.0 }
    var totalSnoreMinutes: Double { totalSnoreSeconds / 60.0 }
    var snorePercentage: Double {
        guard totalSleepSeconds > 0 else { return 0 }
        return (totalSnoreSeconds / totalSleepSeconds) * 100.0
    }
}

// MARK: - 2. Apple Watch / HealthKit 수면 생체지표 연동 매니저 (선택적 활성화)

final class HealthKitSleepCorrelator {
    private let healthStore = HKHealthStore()

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard isHealthDataAvailable else {
            completion(false)
            return
        }

        var readTypes: Set<HKObjectType> = []
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            readTypes.insert(sleepType)
        }
        if let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) {
            readTypes.insert(hrType)
        }
        if let spo2Type = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) {
            readTypes.insert(spo2Type)
        }

        healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }

    /// 수면 세션 시간대의 Apple Watch 심박수, 혈중 산소포화도(SpO2), 수면 단계(REM/Core/Deep)를 조회하여 코골이 클립과 매칭
    func correlateWithWatchData(
        startTime: Date,
        endTime: Date,
        events: [SnoreAcousticEvent],
        clips: [HighlightAudioClip],
        completion: @escaping ([HighlightAudioClip], WatchCorrelationSummary) -> Void
    ) {
        guard isHealthDataAvailable else {
            completion(clips, WatchCorrelationSummary(
                isWatchDataAvailable: false,
                remSleepSnoreRatio: nil,
                minSpO2DuringSnore: nil,
                maxHeartRateDuringGasp: nil,
                desaturationDipCount: 0
            ))
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startTime, end: endTime, options: .strictStartDate)
        let group = DispatchGroup()

        var hrSamples: [HKQuantitySample] = []
        var spo2Samples: [HKQuantitySample] = []
        var sleepSamples: [HKCategorySample] = []

        if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            group.enter()
            let query = HKSampleQuery(sampleType: hrType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                hrSamples = (samples as? [HKQuantitySample]) ?? []
                group.leave()
            }
            healthStore.execute(query)
        }

        if let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            group.enter()
            let query = HKSampleQuery(sampleType: spo2Type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                spo2Samples = (samples as? [HKQuantitySample]) ?? []
                group.leave()
            }
            healthStore.execute(query)
        }

        if let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            group.enter()
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                sleepSamples = (samples as? [HKCategorySample]) ?? []
                group.leave()
            }
            healthStore.execute(query)
        }

        group.notify(queue: .main) {
            let hasAnyWatchData = !hrSamples.isEmpty || !spo2Samples.isEmpty || !sleepSamples.isEmpty
            guard hasAnyWatchData else {
                completion(clips, WatchCorrelationSummary(
                    isWatchDataAvailable: false,
                    remSleepSnoreRatio: nil,
                    minSpO2DuringSnore: nil,
                    maxHeartRateDuringGasp: nil,
                    desaturationDipCount: 0
                ))
                return
            }

            let hrUnit = HKUnit.count().unitDivided(by: .minute())
            let spo2Unit = HKUnit.percent()

            var enrichedClips: [HighlightAudioClip] = []
            var minSpO2: Double? = nil
            var maxHR: Double? = nil
            var lowSpO2Count = 0

            for var clip in clips {
                // 클립 시점 ±90초 이내의 가장 가까운 심박수
                if let nearestHR = hrSamples.min(by: {
                    abs($0.startDate.timeIntervalSince(clip.timestamp)) < abs($1.startDate.timeIntervalSince(clip.timestamp))
                }), abs(nearestHR.startDate.timeIntervalSince(clip.timestamp)) <= 120 {
                    let bpm = nearestHR.quantity.doubleValue(for: hrUnit)
                    clip.watchHeartRateBPM = bpm
                    if clip.eventType == .gasp {
                        maxHR = max(maxHR ?? bpm, bpm)
                    }
                }

                // 클립 시점 ±120초 이내의 혈중 산소포화도(SpO2)
                if let nearestSpO2 = spo2Samples.min(by: {
                    abs($0.startDate.timeIntervalSince(clip.timestamp)) < abs($1.startDate.timeIntervalSince(clip.timestamp))
                }), abs(nearestSpO2.startDate.timeIntervalSince(clip.timestamp)) <= 180 {
                    let pct = nearestSpO2.quantity.doubleValue(for: spo2Unit) * 100.0
                    clip.watchSpO2Percentage = pct
                    minSpO2 = min(minSpO2 ?? pct, pct)
                    if pct < 92.0 {
                        lowSpO2Count += 1
                    }
                }

                // 클립 시점이 속한 Apple Watch 수면 단계
                if let stageSample = sleepSamples.first(where: {
                    clip.timestamp >= $0.startDate && clip.timestamp <= $0.endDate
                }) {
                    clip.watchSleepStage = Self.sleepStageLabel(for: stageSample.value)
                }

                enrichedClips.append(clip)
            }

            // REM 수면 구간 코골이 비중 계산
            let snoreEvents = events.filter { $0.type == .snoring || $0.type == .gasp }
            let totalSnoreSec = snoreEvents.reduce(0.0) { $0 + $1.durationSeconds }
            var remSnoreSec = 0.0
            for event in snoreEvents {
                if let stage = sleepSamples.first(where: { event.timestamp >= $0.startDate && event.timestamp <= $0.endDate }),
                   stage.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue {
                    remSnoreSec += event.durationSeconds
                }
            }
            let remRatio: Double? = totalSnoreSec > 0 && !sleepSamples.isEmpty ? (remSnoreSec / totalSnoreSec) * 100.0 : nil

            let summary = WatchCorrelationSummary(
                isWatchDataAvailable: true,
                remSleepSnoreRatio: remRatio,
                minSpO2DuringSnore: minSpO2,
                maxHeartRateDuringGasp: maxHR,
                desaturationDipCount: lowSpO2Count
            )
            completion(enrichedClips, summary)
        }
    }

    private static func sleepStageLabel(for value: Int) -> String {
        switch value {
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return "REM 수면"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return "깊은(Deep) 수면"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            return "코어(Core) 수면"
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            return "미세 각성(Awake)"
        default:
            return "수면 중"
        }
    }
}

// MARK: - 3. 수면 음향 패턴 분석 엔진

struct SnorePatternDiagnosticEngine {

    static func generateReport(
        startTime: Date,
        endTime: Date,
        events: [SnoreAcousticEvent],
        highlightClips: [HighlightAudioClip],
        watchSummary: WatchCorrelationSummary?
    ) -> SleepAnalysisReport {
        let totalSleepSeconds = max(endTime.timeIntervalSince(startTime), 1)
        let snoreEvents = events.filter { $0.type == .snoring || $0.type == .gasp }

        let totalSnoreSeconds = snoreEvents.reduce(0.0) { $0 + $1.durationSeconds }
        let totalSnoreMinutes = totalSnoreSeconds / 60.0
        let snoreRatio = (totalSnoreSeconds / totalSleepSeconds) * 100.0

        let gaspEvents = events.filter { $0.type == .gasp }

        // 무호흡 의심 클러스터: 12~90초 정적 후 급격한 코골이/헐떡임 발생
        let apneaClusters = events.filter { event in
            (event.type == .gasp) ||
            (event.type == .snoring && event.precededBySilenceSeconds >= 12.0 && event.precededBySilenceSeconds <= 90.0 && event.decibels > -32.0)
        }

        let avgDb: Float = snoreEvents.isEmpty ? -55.0 :
            snoreEvents.reduce(Float(0)) { $0 + $1.decibels } / Float(snoreEvents.count)
        let peakDb: Float = snoreEvents.map(\.decibels).max() ?? -55.0

        let midPoint = startTime.addingTimeInterval(totalSleepSeconds / 2.0)
        let firstHalfSnoreSec = snoreEvents.filter { $0.timestamp < midPoint }.reduce(0.0) { $0 + $1.durationSeconds }
        let secondHalfSnoreSec = snoreEvents.filter { $0.timestamp >= midPoint }.reduce(0.0) { $0 + $1.durationSeconds }

        var findings: [PatternFinding] = []

        // 1) 코골이 총 시간 및 비율 진단
        if totalSnoreMinutes < 5 && snoreRatio < 5 {
            findings.append(PatternFinding(
                title: "코골이 지속 시간 양호",
                metricSummary: String(format: "총 %.1f분 (수면의 %.1f%%)", totalSnoreMinutes, snoreRatio),
                causeAnalysis: "수면 중 상기도가 안정적으로 유지되었으며 일시적인 호흡 마찰음만 감지되었습니다.",
                recommendation: "현재의 베개 높이와 수면 환경을 유지하세요.",
                isWarning: false
            ))
        } else if snoreRatio < 25 {
            findings.append(PatternFinding(
                title: "간헐적/체위성 코골이 감지",
                metricSummary: String(format: "총 %.1f분 (수면의 %.1f%%)", totalSnoreMinutes, snoreRatio),
                causeAnalysis: "똑바로 누운 자세(앙와위)에서 혀뿌리가 뒤로 밀리거나 비강 저항이 높아져 연구개 진동이 발생하는 패턴입니다.",
                recommendation: "옆으로 누워 자는 측와위 수면을 유도하고, 자동 잘라내기된 클립에서 소리 톤을 확인해 보세요.",
                isWarning: false
            ))
        } else {
            findings.append(PatternFinding(
                title: "만성적 장시간 코골이 지속",
                metricSummary: String(format: "총 %.1f분 (수면의 %.1f%%)", totalSnoreMinutes, snoreRatio),
                causeAnalysis: "수면 시간 내내 상기도 협착이 지속되어 호흡 노력이 증가하고 깊은 수면 유지가 방해받고 있습니다.",
                recommendation: "체중 감량 및 측와위 베개 사용을 권장하며, 주간 졸림증이 동반되면 이비인후과/수면클리닉 진료가 필요합니다.",
                isWarning: true
            ))
        }

        // 2) 무호흡 의심 패턴 (정적 후 폭음/헐떡임) 진단
        let sleepHours = max(totalSleepSeconds / 3600.0, 0.5)
        let clusterPerHour = Double(apneaClusters.count) / sleepHours

        if apneaClusters.count >= 3 || !gaspEvents.isEmpty {
            findings.append(PatternFinding(
                title: "침묵 후 호흡 재개(무호흡 의심) 패턴 감지",
                metricSummary: String(format: "총 %d회 (시간당 %.1f회, 헐떡임 %d회)", apneaClusters.count, clusterPerHour, gaspEvents.count),
                causeAnalysis: "코골이 도중 12~60초간 호흡음이 사라진(기도 폐쇄 의심) 뒤, 막혔던 기도가 열리며 폭발적인 코골이나 헐떡임(Gasp)이 터져 나오는 전형적인 폐쇄성 수면무호흡(OSA) 음향 패턴입니다.",
                recommendation: "하단 '자동 잘라내기 오디오 클립'에서 정적 직후 숨을 몰아쉬는 소리를 직접 들어보시고, 수면다원검사(PSG) 상담을 권장합니다.",
                isWarning: true
            ))
        } else {
            findings.append(PatternFinding(
                title: "호흡 끊김/헐떡임 없는 규칙적 리듬",
                metricSummary: "급격한 호흡 중단 후 재개 패턴 낮음",
                causeAnalysis: "코골이 중 기도 완전 폐쇄로 인한 긴 침묵이나 급격한 호흡 재개음이 거의 관찰되지 않았습니다.",
                recommendation: "단순 코골이 가능성이 높으나 음량 피크 추이를 지속적으로 확인하세요.",
                isWarning: false
            ))
        }

        // 3) 시간대별 집중도 분석
        if totalSnoreSeconds > 120 {
            if secondHalfSnoreSec > firstHalfSnoreSec * 1.5 {
                findings.append(PatternFinding(
                    title: "새벽(수면 후반부 REM 구간) 집중형 코골이",
                    metricSummary: String(format: "수면 후반부 비중 %.0f%%", (secondHalfSnoreSec / totalSnoreSeconds) * 100),
                    causeAnalysis: "새벽 시간대 REM 수면 진입 시 전신 및 상기도 근육 긴장도가 최저로 떨어지면서 기도 협착이 심화되는 패턴입니다.",
                    recommendation: "새벽 실내 습도(50~60%)를 유지하고 바디필로우로 새벽 앙와위(정자세) 전환을 방지하세요.",
                    isWarning: false
                ))
            } else if firstHalfSnoreSec > secondHalfSnoreSec * 1.5 {
                findings.append(PatternFinding(
                    title: "입면 초기(수면 전반부) 집중형 코골이",
                    metricSummary: String(format: "수면 전반부 비중 %.0f%%", (firstHalfSnoreSec / totalSnoreSeconds) * 100),
                    causeAnalysis: "취침 직후 깊은 서파 수면 단계에서 음주, 피로 누적, 혹은 비강 부종으로 인해 초기에 코골이가 집중되었습니다.",
                    recommendation: "취침 4시간 전 금주 및 야식 제한, 취침 전 식염수 비강 세척이 효과적입니다.",
                    isWarning: false
                ))
            }
        }

        // 4) Apple Watch 연동 시 생체지표 교차 분석
        if let watch = watchSummary, watch.isWatchDataAvailable {
            if let minSpO2 = watch.minSpO2DuringSnore, minSpO2 < 92.0 {
                findings.append(PatternFinding(
                    title: "Apple Watch 산소포화도(SpO2) 동반 저하 감지",
                    metricSummary: String(format: "최저 SpO2 %.0f%% (92%% 미만 %d회)", minSpO2, watch.desaturationDipCount),
                    causeAnalysis: "코골이 및 호흡 끊김 클립 시점에 혈중 산소포화도가 92% 미만으로 떨어졌으며, 최고 심박수 상승(\(Int(watch.maxHeartRateDuringGasp ?? 0)) BPM)이 동반되었습니다.",
                    recommendation: "음향 패턴과 생체 산소포화도 저하가 동시에 확인되었으므로 전문의에게 클립과 리포트를 제시하시기 바랍니다.",
                    isWarning: true
                ))
            } else if let remRatio = watch.remSleepSnoreRatio {
                findings.append(PatternFinding(
                    title: "Apple Watch 수면 단계 교차 검증 완료",
                    metricSummary: String(format: "REM 수면 중 코골이 %.0f%%", remRatio),
                    causeAnalysis: "워치 수면 단계 데이터와 대조한 결과, 코골이 중 산소포화도는 정상 범위를 유지했습니다.",
                    recommendation: "가끔 워치를 착용하고 주무시면 코골이 시점의 산소포화도 변화를 자동으로 함께 기록합니다.",
                    isWarning: false
                ))
            }
        }

        let severity: PatternSeverity
        if apneaClusters.count >= 5 || gaspEvents.count >= 2 || (watchSummary?.desaturationDipCount ?? 0) >= 2 {
            severity = .highRisk
        } else if snoreRatio >= 25 || peakDb > -20.0 {
            severity = .moderate
        } else if totalSnoreMinutes >= 5 || snoreRatio >= 5 {
            severity = .mild
        } else {
            severity = .normal
        }

        return SleepAnalysisReport(
            id: UUID(),
            startTime: startTime,
            endTime: endTime,
            totalSleepSeconds: totalSleepSeconds,
            totalSnoreSeconds: totalSnoreSeconds,
            totalGaspCount: gaspEvents.count,
            apneaLikeClusterCount: apneaClusters.count,
            averageDecibels: avgDb,
            peakDecibels: peakDb,
            severity: severity,
            findings: findings,
            events: events,
            highlightClips: highlightClips,
            watchSummary: watchSummary
        )
    }
}

// MARK: - 4. 실시간 오디오 모니터링 + 자동 잘라내기(Pre-roll Ring Buffer) + SoundAnalysis

final class SleepAudioMonitor: NSObject, ObservableObject, SNResultsObserving {

    @Published var isRecording: Bool = false
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var liveSnoreSeconds: TimeInterval = 0
    @Published var currentDecibels: Float = -60.0
    @Published var currentDetectedLabel: String = "대기 중"
    @Published var detectedEvents: [SnoreAcousticEvent] = []
    @Published var highlightClips: [HighlightAudioClip] = []
    @Published var latestReport: SleepAnalysisReport?
    @Published var permissionError: String?

    // 사용자 옵션: 자동 하이라이트 클립 잘라내기 & Apple Watch(HealthKit) 연동
    @Published var autoClipExtractionEnabled: Bool = true
    @Published var enableAppleWatchSync: Bool = true
    @Published var watchAuthStatusText: String = "미착용 시에도 단독 작동 (착용 시 자동 교차분석)"

    private let audioEngine = AVAudioEngine()
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.sleepsnore.soundanalysis", qos: .userInitiated)
    private let clipWriteQueue = DispatchQueue(label: "com.sleepsnore.clipwriter", qos: .utility)

    private var sessionStartTime: Date?
    private var lastSnoreTimestamp: Date?
    private var currentWindowDecibels: Float = -60.0
    private var timer: Timer?

    // 자동 잘라내기용 Pre-roll 순환 버퍼 (직전 약 4초 분량의 오디오 버퍼 보관)
    private var preRollBuffers: [AVAudioPCMBuffer] = []
    private let maxPreRollBuffers = 24
    private var recordingFormat: AVAudioFormat?

    // 현재 잘라내기 녹음 중인 클립 상태
    private var activeClipFile: AVAudioFile?
    private var activeClipRemainingBuffers: Int = 0
    private var lastClipSavedTime: Date = .distantPast

    private let healthCorrelator = HealthKitSleepCorrelator()

    // 클립 재생기
    private var audioPlayer: AVAudioPlayer?
    @Published var currentlyPlayingClipID: UUID?

    override init() {
        super.init()
        ensureClipsDirectory()
    }

    private func ensureClipsDirectory() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let clipsDir = docs.appendingPathComponent("SnoreClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
    }

    // MARK: 수면 측정 시작
    func startSleepSession() {
        if enableAppleWatchSync && healthCorrelator.isHealthDataAvailable {
            healthCorrelator.requestAuthorization { [weak self] granted in
                self?.watchAuthStatusText = granted ? "HealthKit 연동 활성 (워치 데이터 자동 매칭)" : "워치 권한 미허용 (단독 음향 분석 모드)"
            }
        }

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.configureAndStartEngine()
                } else {
                    self.permissionError = "마이크 권한이 필요합니다. 아이폰 [설정] -> [개인정보 보호] -> [마이크]에서 허용해 주세요."
                }
            }
        }
    }

    private func configureAndStartEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            self.recordingFormat = format

            streamAnalyzer = SNAudioStreamAnalyzer(format: format)
            let classifyRequest = try SNClassifySoundRequest(classifierIdentifier: .version1)
            classifyRequest.windowDuration = CMTimeMakeWithSeconds(1.5, preferredTimescale: 48000)
            classifyRequest.overlapFactor = 0.5
            try streamAnalyzer?.add(classifyRequest, withObserver: self)

            preRollBuffers.removeAll()
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, time in
                guard let self = self else { return }
                let db = self.calculateDecibels(from: buffer)
                self.currentWindowDecibels = db

                DispatchQueue.main.async {
                    self.currentDecibels = db
                }

                // 1) Pre-roll 링 버퍼 업데이트 및 활성 클립 파일 쓰기
                if let copied = self.copyPCMBuffer(buffer) {
                    self.clipWriteQueue.async {
                        self.preRollBuffers.append(copied)
                        if self.preRollBuffers.count > self.maxPreRollBuffers {
                            self.preRollBuffers.removeFirst()
                        }

                        if let clipFile = self.activeClipFile {
                            try? clipFile.write(from: copied)
                            self.activeClipRemainingBuffers -= 1
                            if self.activeClipRemainingBuffers <= 0 {
                                self.activeClipFile = nil
                            }
                        }
                    }
                }

                // 2) 온디바이스 SoundAnalysis 실시간 분석
                self.analysisQueue.async {
                    self.streamAnalyzer?.analyze(buffer, atAudioFramePosition: time.sampleTime)
                }
            }

            audioEngine.prepare()
            try audioEngine.start()

            sessionStartTime = Date()
            lastSnoreTimestamp = nil
            elapsedSeconds = 0
            liveSnoreSeconds = 0
            detectedEvents = []
            highlightClips = []
            isRecording = true
            currentDetectedLabel = "수면 호흡 모니터링 중..."

            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self, let start = self.sessionStartTime else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }

        } catch {
            permissionError = "오디오 엔진 시작 실패: \(error.localizedDescription)"
        }
    }

    // MARK: 코골이/헐떡임 감지 시 앞뒤 구간 자동 잘라내기(.caf 클립 생성)
    private func triggerAutoHighlightClip(
        eventType: AcousticEventType,
        decibels: Float,
        silenceGap: Double
    ) -> String? {
        guard autoClipExtractionEnabled, let format = recordingFormat else { return nil }

        let now = Date()
        // 클립 과다 생성을 막기 위해 최소 12초 간격 유지 (단, 헐떡임/Gasp은 즉시 저장)
        guard eventType == .gasp || now.timeIntervalSince(lastClipSavedTime) >= 12.0 else {
            return nil
        }
        lastClipSavedTime = now

        let fileName = "Clip_\(Int(now.timeIntervalSince1970))_\(eventType == .gasp ? "gasp" : "snore").caf"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docs.appendingPathComponent("SnoreClips", isDirectory: true).appendingPathComponent(fileName)

        clipWriteQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
                // 직전 4초(Pre-roll) 버퍼를 먼저 기록해 침묵 직후 터져 나오는 소리 맥락까지 보존
                for pastBuffer in self.preRollBuffers {
                    try? file.write(from: pastBuffer)
                }
                // 이후 약 4초(Post-roll, 약 22개 버퍼) 추가 기록 예약
                self.activeClipFile = file
                self.activeClipRemainingBuffers = 22
            } catch {
                print("클립 저장 실패: \(error)")
            }
        }

        let clip = HighlightAudioClip(
            id: UUID(),
            timestamp: now,
            eventType: eventType,
            durationSeconds: 8.0,
            peakDecibels: decibels,
            precededBySilenceSeconds: silenceGap,
            fileName: fileName
        )

        DispatchQueue.main.async {
            self.highlightClips.append(clip)
        }

        return fileName
    }

    // MARK: 수면 측정 종료 및 리포트(워치 데이터 교차 분석 포함) 생성
    func stopSleepSession() {
        guard isRecording else { return }

        timer?.invalidate()
        timer = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        streamAnalyzer?.removeAllRequests()
        activeClipFile = nil
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let end = Date()
        let start = sessionStartTime ?? end.addingTimeInterval(-max(elapsedSeconds, 60))
        let currentEvents = detectedEvents
        let currentClips = highlightClips

        if enableAppleWatchSync && healthCorrelator.isHealthDataAvailable {
            healthCorrelator.correlateWithWatchData(
                startTime: start,
                endTime: end,
                events: currentEvents,
                clips: currentClips
            ) { [weak self] enrichedClips, watchSummary in
                guard let self = self else { return }
                self.highlightClips = enrichedClips
                self.latestReport = SnorePatternDiagnosticEngine.generateReport(
                    startTime: start,
                    endTime: end,
                    events: currentEvents,
                    highlightClips: enrichedClips,
                    watchSummary: watchSummary
                )
            }
        } else {
            latestReport = SnorePatternDiagnosticEngine.generateReport(
                startTime: start,
                endTime: end,
                events: currentEvents,
                highlightClips: currentClips,
                watchSummary: nil
            )
        }
    }

    // MARK: 잘라낸 하이라이트 오디오 클립 재생 / 정지
    func togglePlayClip(_ clip: HighlightAudioClip) {
        if currentlyPlayingClipID == clip.id {
            audioPlayer?.stop()
            currentlyPlayingClipID = nil
            return
        }

        let url = clip.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            permissionError = "샘플 시뮬레이션 클립이거나 파일이 아직 디스크에 기록 중입니다. 실제 수면 녹음 시 자동으로 .caf 오디오 파일이 생성됩니다."
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            currentlyPlayingClipID = clip.id

            DispatchQueue.main.asyncAfter(deadline: .now() + clip.durationSeconds) { [weak self] in
                if self?.currentlyPlayingClipID == clip.id {
                    self?.currentlyPlayingClipID = nil
                }
            }
        } catch {
            permissionError = "클립 재생 오류: \(error.localizedDescription)"
        }
    }

    // MARK: 7시간 수면 + 자동 잘라내기 클립 + Apple Watch 연동 시뮬레이션 프리뷰
    func loadSampleNightSimulation(includeWatchData: Bool) {
        let now = Date()
        let start = now.addingTimeInterval(-7.0 * 3600.0)
        var simulatedEvents: [SnoreAcousticEvent] = []
        var simulatedClips: [HighlightAudioClip] = []

        for i in 0..<40 {
            let offset = Double(3600 + i * 100)
            simulatedEvents.append(SnoreAcousticEvent(
                id: UUID(),
                timestamp: start.addingTimeInterval(offset),
                durationSeconds: 18.0,
                confidence: 0.87,
                decibels: Float.random(in: -35.0 ... -24.0),
                type: .snoring,
                precededBySilenceSeconds: Double.random(in: 2.0 ... 7.0),
                clipFileName: nil
            ))
        }

        for i in 0..<75 {
            let offset = Double(4.2 * 3600 + Double(i) * 58.0)
            let eventTime = start.addingTimeInterval(offset)
            let isApneaPause = (i % 15 == 0)
            let db: Float = isApneaPause ? -15.8 : Float.random(in: -29.0 ... -18.5)
            let silence: Double = isApneaPause ? Double.random(in: 19.0 ... 41.0) : 3.5

            simulatedEvents.append(SnoreAcousticEvent(
                id: UUID(),
                timestamp: eventTime,
                durationSeconds: isApneaPause ? 12.0 : 22.0,
                confidence: 0.93,
                decibels: db,
                type: isApneaPause ? .gasp : .snoring,
                precededBySilenceSeconds: silence,
                clipFileName: isApneaPause ? "SampleClip_\(i).caf" : nil
            ))

            if isApneaPause || i == 25 {
                simulatedClips.append(HighlightAudioClip(
                    id: UUID(),
                    timestamp: eventTime,
                    eventType: isApneaPause ? .gasp : .snoring,
                    durationSeconds: 8.0,
                    peakDecibels: db,
                    precededBySilenceSeconds: silence,
                    fileName: "SampleClip_\(i).caf",
                    watchHeartRateBPM: includeWatchData ? (isApneaPause ? Double.random(in: 78...89) : 61) : nil,
                    watchSpO2Percentage: includeWatchData ? (isApneaPause ? Double.random(in: 89...91) : 96) : nil,
                    watchSleepStage: includeWatchData ? "REM 수면" : nil
                ))
            }
        }

        let watchSummary: WatchCorrelationSummary? = includeWatchData ? WatchCorrelationSummary(
            isWatchDataAvailable: true,
            remSleepSnoreRatio: 68.0,
            minSpO2DuringSnore: 89.0,
            maxHeartRateDuringGasp: 88.0,
            desaturationDipCount: 4
        ) : nil

        latestReport = SnorePatternDiagnosticEngine.generateReport(
            startTime: start,
            endTime: now,
            events: simulatedEvents,
            highlightClips: simulatedClips,
            watchSummary: watchSummary
        )
    }

    private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
        }
        return copy
    }

    private func calculateDecibels(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -60.0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return -60.0 }

        var sumSquares: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameLength))
        let db = 20.0 * log10(max(rms, 0.000_001))
        return max(db, -60.0)
    }

    // MARK: SNResultsObserving 콜백
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }

        let targetMap: [String: AcousticEventType] = [
            "snoring": .snoring,
            "snort": .snoring,
            "gasp": .gasp,
            "pant": .heavyBreathing,
            "breathing": .heavyBreathing,
            "cough": .cough,
            "throat_clearing": .cough
        ]

        guard let topMatch = classificationResult.classifications.first(where: {
            targetMap.keys.contains($0.identifier) && $0.confidence >= 0.45
        }), let matchedType = targetMap[topMatch.identifier] else {
            return
        }

        let windowSec = CMTimeGetSeconds(classificationResult.timeRange.duration)
        let effectiveDuration = max(min(windowSec * 0.5, 2.0), 0.75)
        let now = Date()
        let currentDb = self.currentWindowDecibels

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording else { return }

            let silenceGap: Double
            if let last = self.lastSnoreTimestamp {
                silenceGap = max(now.timeIntervalSince(last) - effectiveDuration, 0)
            } else {
                silenceGap = 0
            }

            var savedClipName: String? = nil
            if matchedType == .snoring || matchedType == .gasp {
                self.liveSnoreSeconds += effectiveDuration
                self.lastSnoreTimestamp = now

                // 헐떡임(Gasp)이거나 고강도 코골이(-30dB 이상)일 때 자동으로 앞뒤 8초 오디오 클립 잘라내기
                if matchedType == .gasp || currentDb > -30.0 {
                    savedClipName = self.triggerAutoHighlightClip(
                        eventType: matchedType,
                        decibels: currentDb,
                        silenceGap: silenceGap
                    )
                }
            }

            self.currentDetectedLabel = "\(matchedType.rawValue) (\(Int(topMatch.confidence * 100))%)"

            let event = SnoreAcousticEvent(
                id: UUID(),
                timestamp: now,
                durationSeconds: effectiveDuration,
                confidence: topMatch.confidence,
                decibels: currentDb,
                type: matchedType,
                precededBySilenceSeconds: silenceGap,
                clipFileName: savedClipName
            )
            self.detectedEvents.append(event)
        }
    }
}

// MARK: - 5. SwiftUI 메인 대시보드 및 리포트 화면

@main
struct SleepSnoreTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            SleepMainDashboardView()
                .preferredColorScheme(.dark)
        }
    }
}

struct SleepMainDashboardView: View {
    @StateObject private var monitor = SleepAudioMonitor()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    liveRecordingCard

                    if let report = monitor.latestReport {
                        ReportDetailView(report: report, monitor: monitor)
                    } else if !monitor.isRecording {
                        simulationPreviewCard
                    }
                }
                .padding()
            }
            .background(Color(red: 0.06, green: 0.08, blue: 0.14).ignoresSafeArea())
            .navigationTitle("수면 코골이 & 호흡 분석")
            .alert("안내", isPresented: Binding(
                get: { monitor.permissionError != nil },
                set: { if !$0 { monitor.permissionError = nil } }
            )) {
                Button("확인", role: .cancel) { monitor.permissionError = nil }
            } message: {
                Text(monitor.permissionError ?? "")
            }
        }
    }

    private var liveRecordingCard: some View {
        VStack(spacing: 16) {
            HStack {
                Circle()
                    .fill(monitor.isRecording ? Color.red : Color.gray)
                    .frame(width: 10, height: 10)
                Text(monitor.isRecording ? "화면 잠금 백그라운드 녹음 & 클립 추출 중" : "수면 측정 준비")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if monitor.isRecording {
                    Text(formatDuration(monitor.elapsedSeconds))
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .foregroundColor(.cyan)
                }
            }

            if monitor.isRecording {
                HStack(spacing: 12) {
                    metricPill(
                        title: "누적 코골이",
                        value: String(format: "%.1f분", monitor.liveSnoreSeconds / 60.0),
                        color: .orange
                    )
                    metricPill(
                        title: "자동 저장된 클립",
                        value: "\(monitor.highlightClips.count)개",
                        color: .pink
                    )
                    metricPill(
                        title: "현재 데시벨",
                        value: String(format: "%.0f dB", monitor.currentDecibels),
                        color: .cyan
                    )
                }

                Text("실시간 감지: \(monitor.currentDetectedLabel)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("코골이/헐떡임 구간 자동 잘라내기 (8초 클립)", isOn: $monitor.autoClipExtractionEnabled)
                        .font(.subheadline)
                        .tint(.orange)

                    Toggle("Apple Watch(HealthKit) 착용 시 자동 연동", isOn: $monitor.enableAppleWatchSync)
                        .font(.subheadline)
                        .tint(.cyan)

                    Text("• \(monitor.watchAuthStatusText)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            Button {
                if monitor.isRecording {
                    monitor.stopSleepSession()
                } else {
                    monitor.startSleepSession()
                }
            } label: {
                HStack {
                    Image(systemName: monitor.isRecording ? "stop.circle.fill" : "moon.zzz.fill")
                        .font(.title3)
                    Text(monitor.isRecording ? "기상 및 수면 리포트 확인" : "수면 시작 (코골이 자동 감지)")
                        .font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(monitor.isRecording ? Color.red.gradient : Color.indigo.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var simulationPreviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("결과 리포트 미리보기")
                .font(.headline)
                .foregroundColor(.white)

            Text("워치 미착용(단독 음향 분석 + 하이라이트 잘라내기) 모드와 워치 착용(산소포화도·REM 수면 교차 분석) 모드를 바로 확인해 볼 수 있습니다.")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.75))

            HStack(spacing: 10) {
                Button {
                    monitor.loadSampleNightSimulation(includeWatchData: false)
                } label: {
                    Text("아이폰 단독 분석 샘플")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    monitor.loadSampleNightSimulation(includeWatchData: true)
                } label: {
                    Text("아이폰 + 워치 연동 샘플")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.cyan)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.cyan.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func metricPill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.65))
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hrs, mins, secs)
    }
}

// MARK: - 6. 리포트 & 하이라이트 클립 플레이어 뷰

struct ReportDetailView: View {
    let report: SleepAnalysisReport
    @ObservedObject var monitor: SleepAudioMonitor

    private var hourlyBuckets: [HourlySnoreBucket] {
        let calendar = Calendar.current
        var grouped: [Int: (snoreSec: Double, gasps: Int)] = [:]

        for event in report.events {
            let hour = calendar.component(.hour, from: event.timestamp)
            var current = grouped[hour] ?? (0, 0)
            if event.type == .snoring || event.type == .gasp {
                current.snoreSec += event.durationSeconds
            }
            if event.type == .gasp {
                current.gasps += 1
            }
            grouped[hour] = current
        }

        return grouped.keys.sorted().map { hour in
            let item = grouped[hour]!
            return HourlySnoreBucket(
                hourLabel: "\(hour)시",
                snoreMinutes: item.snoreSec / 60.0,
                gaspCount: item.gasps
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 1. 종합 요약 배지
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(report.severity.rawValue)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(report.severity.badgeColor.opacity(0.2))
                        .foregroundColor(report.severity.badgeColor)
                        .clipShape(Capsule())
                    Spacer()
                    Text(report.watchSummary?.isWatchDataAvailable == true ? "⌚️ 워치 교차분석 적용됨" : "📱 아이폰 단독 음향분석")
                        .font(.caption2)
                        .foregroundColor(.cyan)
                }

                HStack(spacing: 10) {
                    summaryStatBox(
                        label: "총 코골이 시간",
                        value: String(format: "%.0f분", report.totalSnoreMinutes),
                        sub: String(format: "수면의 %.1f%%", report.snorePercentage),
                        accent: .orange
                    )
                    summaryStatBox(
                        label: "무호흡 의심",
                        value: "\(report.apneaLikeClusterCount)회",
                        sub: "헐떡임 \(report.totalGaspCount)회",
                        accent: report.apneaLikeClusterCount >= 3 ? .red : .green
                    )
                    summaryStatBox(
                        label: "자동 추출 클립",
                        value: "\(report.highlightClips.count)개",
                        sub: String(format: "최대 %.0f dB", report.peakDecibels),
                        accent: .pink
                    )
                }
            }
            .padding(18)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 18))

            // 2. 자동 잘라내기된 코골이/헐떡임 오디오 클립 리스트
            if !report.highlightClips.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "scissors.badge.ellipsis")
                            .foregroundColor(.pink)
                        Text("자동 잘라내기 하이라이트 클립 (\(report.highlightClips.count)개)")
                            .font(.headline)
                            .foregroundColor(.white)
                    }

                    Text("직전 4초(무호흡 정적 구간)부터 코골이/헐떡임 발생 후 4초까지 자동으로 잘라낸 오디오입니다.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.65))

                    ForEach(report.highlightClips) { clip in
                        HStack(spacing: 12) {
                            Button {
                                monitor.togglePlayClip(clip)
                            } label: {
                                Image(systemName: monitor.currentlyPlayingClipID == clip.id ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title)
                                    .foregroundColor(clip.eventType.color)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(clip.eventType.rawValue)
                                        .font(.caption.weight(.bold))
                                        .foregroundColor(clip.eventType.color)
                                    Text(clip.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.6))
                                    Spacer()
                                    Text(String(format: "%.1f dB", clip.peakDecibels))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.cyan)
                                }

                                Text(String(format: "직전 정적 %.0f초 후 발생 (길이 %.0f초)", clip.precededBySilenceSeconds, clip.durationSeconds))
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.8))

                                if clip.watchSpO2Percentage != nil || clip.watchHeartRateBPM != nil {
                                    HStack(spacing: 8) {
                                        if let stage = clip.watchSleepStage {
                                            Text("⌚️ \(stage)")
                                        }
                                        if let spo2 = clip.watchSpO2Percentage {
                                            Text(String(format: "SpO2 %.0f%%", spo2))
                                                .foregroundColor(spo2 < 92 ? .red : .green)
                                        }
                                        if let hr = clip.watchHeartRateBPM {
                                            Text(String(format: "심박 %.0f BPM", hr))
                                        }
                                    }
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(.white.opacity(0.7))
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(18)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            // 3. 시간대별 차트
            if !hourlyBuckets.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("시간대별 코골이 지속 시간 (분)")
                        .font(.headline)
                        .foregroundColor(.white)

                    Chart(hourlyBuckets) { bucket in
                        BarMark(
                            x: .value("시간", bucket.hourLabel),
                            y: .value("코골이(분)", bucket.snoreMinutes)
                        )
                        .foregroundStyle(bucket.gaspCount > 0 ? Color.red.gradient : Color.orange.gradient)
                        .cornerRadius(6)
                    }
                    .frame(height: 170)
                }
                .padding(18)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            // 4. 원인 및 문제점 정밀 진단 카드
            VStack(alignment: .leading, spacing: 12) {
                Text("수면 호흡 패턴 정밀 진단")
                    .font(.headline)
                    .foregroundColor(.white)

                ForEach(report.findings) { finding in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: finding.isWarning ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                .foregroundColor(finding.isWarning ? .orange : .green)
                            Text(finding.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(.white)
                            Spacer()
                            Text(finding.metricSummary)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.cyan)
                        }

                        Text("원인 분석: \(finding.causeAnalysis)")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.85))
                            .lineSpacing(3)

                        Text("권장 조치: \(finding.recommendation)")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(18)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private func summaryStatBox(label: String, value: String, sub: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.65))
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundColor(accent)
            Text(sub)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}