import Foundation
import DirtyTestCore

private var globalCancellationToken: DirtyTestCancellationToken?

private func installSignalHandlers() {
    signal(SIGINT) { _ in
        globalCancellationToken?.cancel()
    }
    signal(SIGTERM) { _ in
        globalCancellationToken?.cancel()
    }
}

func parseArguments(_ rawArguments: [String]) throws -> DirtyTestConfiguration {
    if rawArguments.contains("--help") || rawArguments.contains("-h") {
        print("""
Usage:
  dirtytest --path <dir> --leave-value <number> --leave-unit <gib|mib|percent> [options]

Options:
  --unit-speed <0.1|1|10>       Log speed per free-space interval (default: 1)
  --cache <on|off>              Keep file cache effect on/off (default: on)
  --delete <on|off>             Delete generated Randomfile* after each cycle (default: on)
  --repeat <once|infinite>      Single run or infinite repeat (default: once)
  --log <path>                  Write summary logs
  --detailed-log <path>         Write CSV detailed log
  --buffer-mib <int>            Buffer chunk size in MiB (default: 8)
  --randomness <0..100>         Percent of each buffer filled with random bytes (default: 100)
""")
        exit(0)
    }

    var values = [String: String]()
    var index = 1
    while index < rawArguments.count {
        let key = rawArguments[index]
        guard key.hasPrefix("--") else {
            throw DirtyTestError.invalidArgument("Unexpected token: \(key)")
        }
        let next = index + 1
        guard next < rawArguments.count else {
            throw DirtyTestError.invalidArgument("Missing value for argument: \(key)")
        }
        values[key] = rawArguments[next]
        index += 2
    }

    guard let targetPath = values["--path"] else {
        throw DirtyTestError.invalidArgument("--path is required")
    }
    guard FileManager.default.fileExists(atPath: targetPath) else {
        throw DirtyTestError.invalidPath("Target path does not exist: \(targetPath)")
    }

    guard let leaveValueRaw = values["--leave-value"], let leaveValue = Double(leaveValueRaw) else {
        throw DirtyTestError.invalidArgument("--leave-value is required and must be numeric")
    }
    guard let leaveUnitRaw = values["--leave-unit"], let leaveUnit = LeaveUnit(rawValue: leaveUnitRaw) else {
        throw DirtyTestError.invalidArgument("--leave-unit must be one of: gib, mib, percent")
    }

    let speedUnitRaw = values["--unit-speed"] ?? "1"
    guard let speedUnit = SpeedUnit(rawValue: speedUnitRaw) else {
        throw DirtyTestError.invalidArgument("--unit-speed must be one of: 0.1, 1, 10")
    }

    let cacheRaw = (values["--cache"] ?? "on").lowercased()
    let useCache: Bool
    switch cacheRaw {
    case "on": useCache = true
    case "off": useCache = false
    default:
        throw DirtyTestError.invalidArgument("--cache must be on or off")
    }

    let deleteRaw = (values["--delete"] ?? "on").lowercased()
    let needDelete: Bool
    switch deleteRaw {
    case "on": needDelete = true
    case "off": needDelete = false
    default:
        throw DirtyTestError.invalidArgument("--delete must be on or off")
    }

    let repeatRaw = (values["--repeat"] ?? "once").lowercased()
    guard let repeatMode = RepeatMode(rawValue: repeatRaw) else {
        throw DirtyTestError.invalidArgument("--repeat must be once or infinite")
    }

    let bufferMiBRaw = values["--buffer-mib"] ?? "8"
    guard let bufferMiB = Int(bufferMiBRaw), bufferMiB > 0 else {
        throw DirtyTestError.invalidArgument("--buffer-mib must be a positive integer")
    }

    let randomnessRaw = values["--randomness"] ?? "100"
    guard let randomnessPercent = Int(randomnessRaw), (0...100).contains(randomnessPercent) else {
        throw DirtyTestError.invalidArgument("--randomness must be in 0...100")
    }

    return DirtyTestConfiguration(
        targetPath: targetPath,
        leaveValue: leaveValue,
        leaveUnit: leaveUnit,
        speedUnit: speedUnit,
        useCache: useCache,
        needDelete: needDelete,
        repeatMode: repeatMode,
        logPath: values["--log"],
        detailedLogPath: values["--detailed-log"],
        bufferMiB: bufferMiB,
        randomnessPercent: randomnessPercent
    )
}

do {
    let configuration = try parseArguments(CommandLine.arguments)
    let token = DirtyTestCancellationToken()
    globalCancellationToken = token
    installSignalHandlers()

    let engine = DirtyTestEngine(configuration: configuration)
    try engine.run(
        cancellationToken: token,
        callbacks: DirtyTestCallbacks(
            onMessage: { message in
                print(message)
            },
            onProgress: { progress in
                let message = "Progress: \(progress.progressPercent)%  \(progress.writtenMiB) / \(progress.totalToWriteMiB) MiB  Speed: \(progress.speedMiBps) MiB/s"
                let padded = message.padding(toLength: 90, withPad: " ", startingAt: 0)
                FileHandle.standardOutput.write(Data(("\r" + padded).utf8))
            },
            onSummary: { summary in
                print("\n=======================================")
                print(String(format: "Cycle: %d", summary.cycle))
                print(String(format: "Cycle time: %.1f sec", summary.elapsedCycleSeconds))
                print(String(format: "Total elapsed: %.1f sec", summary.elapsedTotalSeconds))
                print("Max speed: \(summary.maxSpeedMiBps) MiB/s")
                print("Min speed: \(summary.minSpeedMiBps) MiB/s")
                print("Avg speed: \(summary.averageSpeedMiBps) MiB/s")
                print(String(format: "<= 50%% of average: %.1f%%", summary.belowHalfAveragePercent))
                print("=======================================")
            }
        )
    )
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
