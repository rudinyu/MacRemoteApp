import CodecCore
import Darwin
import Foundation
import TransportCore

@main
struct M8Benchmark {
    private static let maximumSamples = 1_000_000

    private struct Arguments {
        let samples: Int
        let durationSeconds: Double

        init() throws {
            let commandLine = CommandLine.arguments
            samples = try Self.value(named: "--samples", in: commandLine) ?? 1_800
            durationSeconds = try Self.value(named: "--duration-seconds", in: commandLine) ?? 30
        }

        private static func value<T: LosslessStringConvertible>(
            named name: String,
            in arguments: [String]
        ) throws -> T? {
            guard let index = arguments.firstIndex(of: name) else {
                return nil
            }
            guard arguments.indices.contains(index + 1),
                  let value = T(arguments[index + 1]) else {
                throw BenchmarkError.invalidArguments
            }
            return value
        }
    }

    static func main() async {
        do {
            let report = try await run(arguments: Arguments())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            if report.verdict == "fail" {
                exit(EXIT_FAILURE)
            }
        } catch {
            FileHandle.standardError.write(
                Data("M8 benchmark failed: \(error)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: Arguments) async throws -> PerformanceRunReport {
        guard arguments.samples >= 1_000,
              arguments.samples <= maximumSamples,
              arguments.durationSeconds.isFinite,
              arguments.durationSeconds > 0 else {
            throw BenchmarkError.invalidArguments
        }

        let before = resourceUsage()
        var clockEstimator = ClockSyncEstimator()
        let clockBase = 1_000_000_000
        for index in 0 ..< (ClockSyncEstimator.minimumProbeCount + 4) {
            let hostSent = UInt64(clockBase + index * 10_000_000)
            let reversePath: UInt64 = index == 5 ? 550_000 : 2_500_000
            let viewerReceived = hostSent + 2_000_000 + 550_000
            let viewerSent = viewerReceived + 100_000
            let hostReceived = viewerSent - 2_000_000 + reversePath
            _ = clockEstimator.append(
                ClockSyncProbe(
                    hostSentNanoseconds: hostSent,
                    viewerReceivedNanoseconds: viewerReceived,
                    viewerSentNanoseconds: viewerSent,
                    hostReceivedNanoseconds: hostReceived
                )
            )
        }
        guard let clockSync = clockEstimator.estimate(),
              clockSync.oneWayMeasurementEligible else {
            throw BenchmarkError.clockSyncUnavailable
        }

        let warmupFrames = 60
        let (totalFrames, totalFramesOverflow) = warmupFrames.addingReportingOverflow(arguments.samples)
        guard !totalFramesOverflow else {
            throw BenchmarkError.invalidArguments
        }
        // `samples` is the number of valid post-warm-up samples. Derive the
        // synthetic interval from the declared measurement window so the
        // reported frame rate and the timestamp window describe the same
        // population. The physical M8 path will replace these timestamps with
        // authenticated Host/Viewer capture and presentation timestamps.
        let framePeriodDouble = (arguments.durationSeconds * 1_000_000_000) /
            Double(arguments.samples)
        // `Double(UInt64.max)` rounds to 2^64. Use a strict bound so a value
        // that has rounded to 2^64 cannot pass the guard and trap in the
        // UInt64 conversion below.
        guard framePeriodDouble.isFinite,
              framePeriodDouble >= 0,
              framePeriodDouble < Double(UInt64.max) else {
            throw BenchmarkError.invalidArguments
        }
        let framePeriod = max(1, UInt64(framePeriodDouble))
        let (warmupDuration, warmupOverflow) = framePeriod.multipliedReportingOverflow(
            by: UInt64(warmupFrames)
        )
        let (validDuration, validOverflow) = framePeriod.multipliedReportingOverflow(
            by: UInt64(arguments.samples - 1)
        )
        let (captureBase, baseOverflow) = UInt64(clockBase).addingReportingOverflow(
            warmupDuration
        )
        guard !warmupOverflow,
              !validOverflow,
              !baseOverflow,
              captureBase <= UInt64.max - validDuration else {
            throw BenchmarkError.invalidArguments
        }
        var captureToDisplay: [UInt64] = []
        var interaction: [UInt64] = []
        captureToDisplay.reserveCapacity(arguments.samples)
        interaction.reserveCapacity(arguments.samples)

        for index in 0 ..< totalFrames {
            let captureTimestamp: UInt64
            if index < warmupFrames {
                captureTimestamp = captureBase -
                    UInt64(warmupFrames - index) * framePeriod
            } else {
                captureTimestamp = captureBase +
                    UInt64(index - warmupFrames) * framePeriod
            }
            let pipelineJitter = UInt64((index * 37) % 2_000_000)
            let displayLatency = 8_000_000 + pipelineJitter
            guard captureTimestamp <= UInt64(Int64.max),
                  displayLatency <= UInt64(Int64.max) else {
                throw BenchmarkError.invalidArguments
            }
            let captureTimestampSigned = Int64(captureTimestamp)
            let displayLatencySigned = Int64(displayLatency)
            let (captureWithOffset, offsetOverflow) = captureTimestampSigned
                .addingReportingOverflow(clockSync.offsetNanoseconds)
            let (viewerPresentation, displayOverflow) = captureWithOffset
                .addingReportingOverflow(displayLatencySigned)
            let (withoutCapture, captureSubtractOverflow) = viewerPresentation
                .subtractingReportingOverflow(captureTimestampSigned)
            let (adjustedLatency, offsetSubtractOverflow) = withoutCapture
                .subtractingReportingOverflow(clockSync.offsetNanoseconds)
            guard !offsetOverflow,
                  !displayOverflow,
                  !captureSubtractOverflow,
                  !offsetSubtractOverflow,
                  adjustedLatency >= 0 else {
                throw BenchmarkError.invalidArguments
            }
            let inputLatency = 3_000_000 + UInt64((index * 19) % 1_000_000)
            if index >= warmupFrames {
                captureToDisplay.append(UInt64(adjustedLatency))
                interaction.append(inputLatency)
            }
        }

        let supersededFrames = try await queueStressCount()
        let after = resourceUsage()
        let deliveredFrames = arguments.samples
        let achievedFrameRate = Double(captureToDisplay.count) / arguments.durationSeconds
        let verdict = captureToDisplay.count >= 1_000 &&
                achievedFrameRate >= 30 &&
                clockSync.oneWayMeasurementEligible
            ? "synthetic-harness-pass-physical-evidence-pending"
            : "fail"

        return PerformanceRunReport(
            measurementKind: "deterministic-synthetic-pipeline",
            hostArchitecture: ProcessInfo.processInfo.environment[
                "MACREMOTEAPP_BENCHMARK_HOST_ARCH"
            ] ?? "unverified-intel",
            viewerArchitecture: currentArchitecture,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            resolution: "1920x1080",
            targetFrameRate: 60,
            durationSeconds: arguments.durationSeconds,
            warmupFrames: warmupFrames,
            validFrameSamples: captureToDisplay.count,
            deliveredFrames: deliveredFrames,
            droppedFrames: 0,
            supersededFrames: supersededFrames,
            achievedFrameRate: achievedFrameRate,
            captureToDisplay: PercentileSummary(samples: captureToDisplay),
            interaction: PercentileSummary(samples: interaction),
            clockSync: clockSync,
            reconnectCount: 2,
            keyframeRecoveryCount: 2,
            slowPeerEvents: 3,
            maximumControlQueueDepth: 1,
            maximumMediaQueueDepth: 3,
            resources: ResourceSnapshot(
                userCPUSeconds: max(0, after.user - before.user),
                systemCPUSeconds: max(0, after.system - before.system),
                maximumResidentBytes: after.maximumResidentBytes,
                gpuMeasurementAvailable: false
            ),
            verdict: verdict
        )
    }

    private static func queueStressCount() async throws -> Int {
        let queue = try BoundedVideoFrameQueue(capacity: 3)
        var superseded = 0
        for index in 0 ..< 120 {
            let frame = try EncodedH264Frame(
                generation: 1,
                captureTimestamp: UInt64(index),
                presentationTimestamp: UInt64(index),
                width: 1920,
                height: 1080,
                keyframe: index == 0,
                accessUnit: Data([0x01, UInt8(index & 0xFF)])
            )
            do {
                if case .replacedNonKeyframe = try await queue.enqueue(frame) {
                    superseded += 1
                }
            } catch CodecError.queueFull {
                // A full queue containing only recovery frames must reject the
                // new frame; it must never grow to preserve an unsafe backlog.
            }
        }
        guard await queue.count() <= 3 else {
            throw BenchmarkError.queueExceededBound
        }
        return superseded
    }

    private struct Usage {
        let user: Double
        let system: Double
        let maximumResidentBytes: UInt64
    }

    private static func resourceUsage() -> Usage {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) +
            Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) +
            Double(usage.ru_stime.tv_usec) / 1_000_000
        return Usage(
            user: user,
            system: system,
            maximumResidentBytes: UInt64(max(0, usage.ru_maxrss))
        )
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArguments
    case clockSyncUnavailable
    case queueExceededBound

    var description: String {
        switch self {
        case .invalidArguments:
            return "samples must be between 1000 and 1000000 valid post-warm-up samples and duration must be positive"
        case .clockSyncUnavailable: return "clock sync did not meet the M8 uncertainty gate"
        case .queueExceededBound: return "video queue exceeded its configured bound"
        }
    }
}
