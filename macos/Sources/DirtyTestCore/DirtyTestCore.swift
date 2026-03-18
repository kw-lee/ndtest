import Foundation
import Darwin

public enum DirtyTestError: Error, LocalizedError {
    case invalidArgument(String)
    case invalidPath(String)
    case diskInfoUnavailable(String)
    case insufficientSpace(String)
    case fileOpenFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            return message
        case .invalidPath(let message):
            return message
        case .diskInfoUnavailable(let message):
            return message
        case .insufficientSpace(let message):
            return message
        case .fileOpenFailed(let message):
            return message
        case .writeFailed(let message):
            return message
        }
    }
}

public enum LeaveUnit: String, CaseIterable, Sendable {
    case gib
    case mib
    case percent
    case writeGib  // 쓸 용량 GiB
    case writeMib  // 쓸 용량 MiB
}

public enum SpeedUnit: String, CaseIterable, Sendable {
    case zeroPointOne = "0.1"
    case one = "1"
    case ten = "10"
}

public enum RepeatMode: String, CaseIterable, Sendable {
    case once
    case infinite
}

public struct DirtyTestConfiguration: Sendable {
    public let targetPath: String
    public let leaveValue: Double
    public let leaveUnit: LeaveUnit
    public let speedUnit: SpeedUnit
    public let useCache: Bool
    public let needDelete: Bool
    public let repeatMode: RepeatMode
    public let logPath: String?
    public let detailedLogPath: String?
    public let bufferMiB: Int
    public let randomnessPercent: Int

    public init(
        targetPath: String,
        leaveValue: Double,
        leaveUnit: LeaveUnit,
        speedUnit: SpeedUnit = .one,
        useCache: Bool = true,
        needDelete: Bool = true,
        repeatMode: RepeatMode = .once,
        logPath: String? = nil,
        detailedLogPath: String? = nil,
        bufferMiB: Int = 8,
        randomnessPercent: Int = 100
    ) {
        self.targetPath = targetPath
        self.leaveValue = leaveValue
        self.leaveUnit = leaveUnit
        self.speedUnit = speedUnit
        self.useCache = useCache
        self.needDelete = needDelete
        self.repeatMode = repeatMode
        self.logPath = logPath
        self.detailedLogPath = detailedLogPath
        self.bufferMiB = bufferMiB
        self.randomnessPercent = randomnessPercent
    }
}

public struct DirtyTestProgress: Sendable {
    public let cycle: Int
    public let progressPercent: Int
    public let writtenMiB: Int
    public let totalToWriteMiB: Int
    public let speedMiBps: Int
    public let freePercent: Double
}

public struct DirtyTestSummary: Sendable {
    public let cycle: Int
    public let elapsedCycleSeconds: Double
    public let elapsedTotalSeconds: Double
    public let maxSpeedMiBps: Int
    public let minSpeedMiBps: Int
    public let averageSpeedMiBps: Int
    public let belowHalfAveragePercent: Double
}

public struct DirtyTestCallbacks: Sendable {
    public var onMessage: @Sendable (String) -> Void
    public var onProgress: @Sendable (DirtyTestProgress) -> Void
    public var onSummary: @Sendable (DirtyTestSummary) -> Void
    public var onCycleStart: @Sendable () -> Void

    public init(
        onMessage: @escaping @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (DirtyTestProgress) -> Void = { _ in },
        onSummary: @escaping @Sendable (DirtyTestSummary) -> Void = { _ in },
        onCycleStart: @escaping @Sendable () -> Void = {}
    ) {
        self.onMessage = onMessage
        self.onProgress = onProgress
        self.onSummary = onSummary
        self.onCycleStart = onCycleStart
    }
}

public final class DirtyTestCancellationToken: @unchecked Sendable {
    private var cancelled = false
    private var paused = false
    private let condition = NSCondition()

    public init() {}

    public func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func pause() {
        condition.lock()
        guard !cancelled else {
            condition.unlock()
            return
        }
        paused = true
        condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public var isCancelled: Bool {
        condition.lock()
        let value = cancelled
        condition.unlock()
        return value
    }

    public var isPaused: Bool {
        condition.lock()
        let value = paused
        condition.unlock()
        return value
    }

    @discardableResult
    public func waitIfPaused(
        onPause: (() -> Void)? = nil,
        onResume: (() -> Void)? = nil
    ) -> Bool {
        condition.lock()
        let shouldNotifyPause = paused && !cancelled
        if shouldNotifyPause {
            onPause?()
        }
        while paused && !cancelled {
            condition.wait()
        }
        let didResume = shouldNotifyPause && !cancelled
        condition.unlock()

        if didResume {
            onResume?()
        }
        return !isCancelled
    }
}

public final class DirtyTestEngine {
    private let configuration: DirtyTestConfiguration
    private let fourGiBBytes: UInt64 = 4 * 1024 * 1024 * 1024
    private let oneMiBBytes: UInt64 = 1024 * 1024

    public init(configuration: DirtyTestConfiguration) {
        self.configuration = configuration
    }

    public func run(
        cancellationToken: DirtyTestCancellationToken,
        callbacks: DirtyTestCallbacks = DirtyTestCallbacks()
    ) throws {
        try Self.validate(configuration: configuration)

        let startTimestamp = Date()
        var cycle = 1

        while true {
            if cancellationToken.isCancelled {
                break
            }

            let cycleStart = Date()
            let diskInfoBefore = try Self.readDiskInfo(at: configuration.targetPath)
            let toFillBytes = try calculateToFillBytes(diskInfo: diskInfoBefore)
            let bufferBytes = UInt64(configuration.bufferMiB) * oneMiBBytes

            callbacks.onCycleStart()
            callbacks.onMessage(headerText(cycle: cycle, diskInfo: diskInfoBefore, toFillBytes: toFillBytes))

            let cycleResult = try performSingleCycle(
                cycle: cycle,
                diskInfoAtStart: diskInfoBefore,
                toFillBytes: toFillBytes,
                bufferBytes: bufferBytes,
                cancellationToken: cancellationToken,
                callbacks: callbacks
            )

            if configuration.needDelete {
                try deleteTestFiles(inclusiveRange: cycleResult.fileRange)
            }

            let summary = makeSummary(
                cycle: cycle,
                cycleStart: cycleStart,
                totalStart: startTimestamp,
                speeds: cycleResult.speeds
            )
            callbacks.onSummary(summary)

            if configuration.repeatMode == .once {
                break
            }
            cycle += 1
        }
    }

    private struct DiskInfo {
        let freeBytes: UInt64
        let totalBytes: UInt64
    }

    private struct CycleResult {
        let fileRange: ClosedRange<Int>
        let speeds: [Int]
    }

    private func performSingleCycle(
        cycle: Int,
        diskInfoAtStart: DiskInfo,
        toFillBytes: UInt64,
        bufferBytes: UInt64,
        cancellationToken: DirtyTestCancellationToken,
        callbacks: DirtyTestCallbacks
    ) throws -> CycleResult {
        guard bufferBytes > 0 else {
            throw DirtyTestError.invalidArgument("Buffer size must be greater than zero")
        }

        let randomnessBytes = Int(Double(bufferBytes) * (Double(configuration.randomnessPercent) / 100.0))
        var writeBuffer = Self.makeBuffer(totalBytes: Int(bufferBytes), randomBytes: randomnessBytes)
        let startFileNumber = firstAvailableFileNumber()

        let originalFilledMiB = Double(diskInfoAtStart.totalBytes - diskInfoAtStart.freeBytes) / Double(oneMiBBytes)
        let diskSizeMiB = Double(diskInfoAtStart.totalBytes) / Double(oneMiBBytes)

        var detailLogger: FileLogger?
        if let detailedLogPath = configuration.detailedLogPath {
            detailLogger = try FileLogger(path: detailedLogPath)
            detailLogger?.write("free_percent,speed_mibps")
        }

        let logger = try configuration.logPath.map { try FileLogger(path: $0) }

        var remainingBytes = toFillBytes
        var writtenBytes: UInt64 = 0
        var currentFileDescriptor: Int32 = -1
        var lastDrivePercent: Double? = nil
        var speeds = [Int]()

        defer {
            if currentFileDescriptor >= 0 {
                close(currentFileDescriptor)
            }
        }

        while remainingBytes >= bufferBytes {
            if cancellationToken.isCancelled {
                break
            }
            if !cancellationToken.waitIfPaused(
                onPause: {
                    callbacks.onMessage("- \(Self.pauseTimestamp()) 에 일시정지 시작 -")
                },
                onResume: {
                    callbacks.onMessage("- \(Self.pauseTimestamp()) 에 일시정지 종료 -")
                }
            ) {
                break
            }

            if writtenBytes % fourGiBBytes == 0 {
                if currentFileDescriptor >= 0 {
                    close(currentFileDescriptor)
                }
                let fileNumber = startFileNumber + Int(writtenBytes / fourGiBBytes)
                let filePath = buildFilePath(fileNumber: fileNumber)
                currentFileDescriptor = try openFile(path: filePath, useCache: configuration.useCache)
            }

            if randomnessBytes > 0 {
                Self.refreshRandomPrefix(in: &writeBuffer, randomBytes: randomnessBytes)
            }

            let begin = DispatchTime.now().uptimeNanoseconds
            try writeFully(fileDescriptor: currentFileDescriptor, data: writeBuffer)
            let end = DispatchTime.now().uptimeNanoseconds

            let latencySeconds = max(Double(end - begin) / 1_000_000_000, 0.000_001)
            let speedMiBps = Int((Double(bufferBytes) / Double(oneMiBBytes)) / latencySeconds)
            speeds.append(speedMiBps)

            writtenBytes += bufferBytes
            remainingBytes -= bufferBytes

            let writtenMiB = Double(writtenBytes) / Double(oneMiBBytes)
            let toFillMiB = Double(toFillBytes) / Double(oneMiBBytes)
            let progressPercent = Int((writtenMiB / toFillMiB) * 100)
            let currentDrivePercent = normalizedDrivePercent(
                diskSizeMiB: diskSizeMiB,
                originalFilledMiB: originalFilledMiB,
                writtenMiB: writtenMiB
            )

            if shouldEmitSpeedLog(lastPercent: lastDrivePercent, currentPercent: currentDrivePercent) {
                let line = String(format: "%.1f%% at %d MiB/s", currentDrivePercent, speedMiBps)
                callbacks.onMessage(line)
                logger?.write(line)
                lastDrivePercent = currentDrivePercent
            }

            let freePercent = ((diskSizeMiB - (originalFilledMiB + writtenMiB)) / diskSizeMiB) * 100
            detailLogger?.write(String(format: "%.2f,%d", freePercent, speedMiBps))

            callbacks.onProgress(
                DirtyTestProgress(
                    cycle: cycle,
                    progressPercent: progressPercent,
                    writtenMiB: Int(writtenMiB),
                    totalToWriteMiB: Int(toFillMiB),
                    speedMiBps: speedMiBps,
                    freePercent: freePercent
                )
            )
        }

        let endFileNumber = startFileNumber + Int(max(0, (writtenBytes == 0 ? 0 : (writtenBytes - 1) / fourGiBBytes)))
        return CycleResult(fileRange: startFileNumber...endFileNumber, speeds: speeds)
    }

    private func makeSummary(cycle: Int, cycleStart: Date, totalStart: Date, speeds: [Int]) -> DirtyTestSummary {
        let elapsedCycle = Date().timeIntervalSince(cycleStart)
        let elapsedTotal = Date().timeIntervalSince(totalStart)

        guard !speeds.isEmpty else {
            return DirtyTestSummary(
                cycle: cycle,
                elapsedCycleSeconds: elapsedCycle,
                elapsedTotalSeconds: elapsedTotal,
                maxSpeedMiBps: 0,
                minSpeedMiBps: 0,
                averageSpeedMiBps: 0,
                belowHalfAveragePercent: 0
            )
        }

        let maxSpeed = speeds.max() ?? 0
        let minSpeed = speeds.min() ?? 0
        let average = speeds.reduce(0, +) / speeds.count
        let halfAverage = average / 2
        let belowHalfCount = speeds.filter { $0 <= halfAverage }.count
        let belowHalfPercent = Double(belowHalfCount) / Double(speeds.count) * 100.0

        return DirtyTestSummary(
            cycle: cycle,
            elapsedCycleSeconds: elapsedCycle,
            elapsedTotalSeconds: elapsedTotal,
            maxSpeedMiBps: maxSpeed,
            minSpeedMiBps: minSpeed,
            averageSpeedMiBps: average,
            belowHalfAveragePercent: belowHalfPercent
        )
    }

    private func headerText(cycle: Int, diskInfo: DiskInfo, toFillBytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        let totalText = formatter.string(fromByteCount: Int64(diskInfo.totalBytes))
        let freeText = formatter.string(fromByteCount: Int64(diskInfo.freeBytes))
        let fillText = formatter.string(fromByteCount: Int64(toFillBytes))
        let model = readDiskModel(forPath: configuration.targetPath) ?? "Unknown"

        return """
=======================================
DirtyTest (macOS unofficial fork)
Cycle: \(cycle)
모델명: \(model)
Target: \(configuration.targetPath)
Total: \(totalText) / Free: \(freeText)
Planned write: \(fillText)
=======================================
"""
    }

    private func shouldEmitSpeedLog(lastPercent: Double?, currentPercent: Double) -> Bool {
        guard let lastPercent else {
            return true
        }

        switch configuration.speedUnit {
        case .ten:
            return abs(currentPercent - lastPercent) >= 10.0
        case .one, .zeroPointOne:
            return currentPercent != lastPercent
        }
    }

    private func normalizedDrivePercent(diskSizeMiB: Double, originalFilledMiB: Double, writtenMiB: Double) -> Double {
        let current = ((diskSizeMiB - (originalFilledMiB + writtenMiB)) / diskSizeMiB) * 100.0
        switch configuration.speedUnit {
        case .ten, .one:
            return Double(Int(round(current)))
        case .zeroPointOne:
            return (current * 10.0).rounded() / 10.0
        }
    }

    private func calculateToFillBytes(diskInfo: DiskInfo) throws -> UInt64 {
        let freeMiB = Double(diskInfo.freeBytes) / Double(oneMiBBytes)
        let totalMiB = Double(diskInfo.totalBytes) / Double(oneMiBBytes)

        let rawMiB: Double
        switch configuration.leaveUnit {
        case .gib:
            rawMiB = freeMiB - 1.0 - (configuration.leaveValue * 1024.0)
        case .mib:
            rawMiB = freeMiB - 1.0 - configuration.leaveValue
        case .percent:
            guard configuration.leaveValue <= 100 else {
                throw DirtyTestError.invalidArgument("Percent leave value must be <= 100")
            }
            rawMiB = freeMiB - 1.0 - (totalMiB * configuration.leaveValue / 100.0)
        case .writeGib:
            rawMiB = configuration.leaveValue * 1024.0
        case .writeMib:
            rawMiB = configuration.leaveValue
        }

        let bufferMiB = Double(configuration.bufferMiB)
        let alignedMiB = floor(rawMiB / bufferMiB) * bufferMiB
        if alignedMiB <= 0 {
            throw DirtyTestError.insufficientSpace(
                "Computed writable size is <= 0 MiB. Reduce leave value or choose a different target path."
            )
        }

        // For write-amount modes, ensure requested size does not exceed available free space.
        let isWriteMode = configuration.leaveUnit == .writeGib || configuration.leaveUnit == .writeMib
        if isWriteMode && alignedMiB > freeMiB - 1.0 {
            throw DirtyTestError.insufficientSpace(
                "Requested write size (\(Int(alignedMiB)) MiB) exceeds available free space (\(Int(freeMiB)) MiB)."
            )
        }

        return UInt64(alignedMiB * Double(oneMiBBytes))
    }

    private func firstAvailableFileNumber() -> Int {
        var fileNumber = 0
        while FileManager.default.fileExists(atPath: buildFilePath(fileNumber: fileNumber)) {
            fileNumber += 1
        }
        return fileNumber
    }

    private func buildFilePath(fileNumber: Int) -> String {
        (configuration.targetPath as NSString).appendingPathComponent("Randomfile\(fileNumber)")
    }

    private func deleteTestFiles(inclusiveRange: ClosedRange<Int>) throws {
        for fileNumber in inclusiveRange {
            let path = buildFilePath(fileNumber: fileNumber)
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private func openFile(path: String, useCache: Bool) throws -> Int32 {
        let mode = O_RDWR | O_CREAT | O_EXCL
        let fd = open(path, mode, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        guard fd >= 0 else {
            throw DirtyTestError.fileOpenFailed("Failed to open \(path): \(String(cString: strerror(errno)))")
        }

        if !useCache {
            _ = fcntl(fd, F_NOCACHE, 1)
        }

        return fd
    }

    private func writeFully(fileDescriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else {
                throw DirtyTestError.writeFailed("Buffer pointer is nil")
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, pointer, remaining)
                if written < 0 {
                    throw DirtyTestError.writeFailed("Write failed: \(String(cString: strerror(errno)))")
                }
                if written == 0 {
                    throw DirtyTestError.writeFailed("Write returned 0 bytes")
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func readDiskInfo(at path: String) throws -> DiskInfo {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else {
            throw DirtyTestError.diskInfoUnavailable(
                "Failed to read disk information for \(path): \(String(cString: strerror(errno)))"
            )
        }

        let blockSize = UInt64(stats.f_bsize)
        let freeBytes = UInt64(stats.f_bavail) * blockSize
        let totalBytes = UInt64(stats.f_blocks) * blockSize
        return DiskInfo(freeBytes: freeBytes, totalBytes: totalBytes)
    }

    private static func makeBuffer(totalBytes: Int, randomBytes: Int) -> Data {
        let clampedRandomBytes = max(0, min(randomBytes, totalBytes))
        var data = Data(count: totalBytes)
        guard clampedRandomBytes > 0 else { return data }

        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            arc4random_buf(baseAddress, clampedRandomBytes)
        }
        return data
    }

    private static func refreshRandomPrefix(in data: inout Data, randomBytes: Int) {
        let clampedRandomBytes = max(0, min(randomBytes, data.count))
        guard clampedRandomBytes > 0 else { return }

        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            arc4random_buf(baseAddress, clampedRandomBytes)
        }
    }

    private static func validate(configuration: DirtyTestConfiguration) throws {
        guard FileManager.default.fileExists(atPath: configuration.targetPath) else {
            throw DirtyTestError.invalidPath("Target path does not exist: \(configuration.targetPath)")
        }

        if configuration.bufferMiB <= 0 {
            throw DirtyTestError.invalidArgument("bufferMiB must be positive")
        }

        if !(0...100).contains(configuration.randomnessPercent) {
            throw DirtyTestError.invalidArgument("randomnessPercent must be in 0...100")
        }

        if configuration.leaveUnit == .percent && configuration.leaveValue > 100 {
            throw DirtyTestError.invalidArgument("Percent leave value must be <= 100")
        }
    }

    private static func pauseTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yy/MM/dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}

final class FileLogger {
    private let fileHandle: FileHandle

    init(path: String) throws {
        let fileManager = FileManager.default
        let expandedPath = (path as NSString).expandingTildeInPath
        let directory = (expandedPath as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: expandedPath) {
            fileManager.createFile(atPath: expandedPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: expandedPath) else {
            throw DirtyTestError.invalidPath("Cannot open log file: \(expandedPath)")
        }
        handle.truncateFile(atOffset: 0)
        self.fileHandle = handle
    }

    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        fileHandle.write(data)
    }

    deinit {
        try? fileHandle.close()
    }
}
