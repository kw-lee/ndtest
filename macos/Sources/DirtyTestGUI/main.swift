import SwiftUI
import AppKit
import Charts
import DirtyTestCore

private let unofficialAppName = "DirtyTest"
private let unofficialAppVersion = "1.0.0"
private let unofficialDisclaimer = "나래온 더티 테스트는 프리웨어입니다. 개발자는 이 프로그램의 부작용에 대해서 어떠한 책임도 지지 않습니다. 자세한 내용은 GPL 3.0을 참고하세요."

@main
struct DirtyTestGUIApp: App {
    @StateObject private var viewModel = DirtyTestViewModel()

    var body: some Scene {
        WindowGroup(unofficialAppName) {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 860, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("\(unofficialAppName) 정보") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: unofficialAppName,
                        .applicationVersion: unofficialAppVersion,
                        .credits: NSAttributedString(
                            string: """
                            비공식 포크 안내

                            이 소프트웨어는 원저작자의 승인을 받은 공식 배포본이 아닌,
                            Naraeon Dirty Test를 Swift로 macOS에 옮긴 비공식 포크입니다.

                            원저작: Naraeon Dirty Test
                            https://github.com/naraeon/nand-ssd-analysis-tool

                            \(unofficialDisclaimer)

                            라이선스: GNU General Public License v3.0 (GPLv3)
                            이 프로그램은 자유 소프트웨어이며, GPLv3 조건 하에
                            수정 및 재배포할 수 있습니다.
                            """,
                            attributes: [.font: NSFont.systemFont(ofSize: 11)]
                        )
                    ])
                }
            }
        }
    }
}

@MainActor
final class DirtyTestViewModel: ObservableObject {
    struct VolumeInfo: Identifiable, Hashable {
        let id = UUID()
        let path: String
        let displayName: String
        let freeMiB: Int
        let totalMiB: Int

        var freeText: String {
            freeMiB >= 1024
                ? String(format: "%.1f GiB", Double(freeMiB) / 1024)
                : "\(freeMiB) MiB"
        }
        var totalText: String {
            totalMiB >= 1024
                ? String(format: "%.1f GiB", Double(totalMiB) / 1024)
                : "\(totalMiB) MiB"
        }
    }

    @Published var targetPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var mountedVolumes: [VolumeInfo] = []
    @Published var selectedVolume: VolumeInfo? = nil
    @Published var diskFreeText: String = ""
    @Published var diskTotalText: String = ""
    @Published var diskModel: String = ""
    @Published var leaveValueText: String = "10"
    @Published var leaveUnit: LeaveUnit = .gib
    @Published var writeMode: Bool = false  // true = 쓸 용량, false = 남길 용량
    @Published var speedUnit: SpeedUnit = .one
    @Published var useCache: Bool = false
    @Published var needDelete: Bool = true
    @Published var repeatMode: RepeatMode = .once
    @Published var bufferMiBText: String = "8"
    @Published var randomnessText: String = "100"
    @Published var logPath: String = ""
    @Published var detailedLogPath: String = ""

    @Published var currentCycleLogs: [String] = []
    @Published var logTab: Int = 0
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var progressPercent = 0
    @Published var writtenMiB = 0
    @Published var totalMiB = 0
    @Published var speedMiBps = 0
    @Published var runningMeanSpeedMiBps = 0
    @Published var freePercent = 0.0
    @Published var etaText: String = "예상 남은 시간: --"

    struct SpeedPoint: Identifiable {
        let id = UUID()
        let freePercent: Double
        let speedMiBps: Int
    }

    @Published var summaryText = ""
    @Published var logs: [String] = []
    @Published var errorText = ""
    @Published var speedPoints: [SpeedPoint] = []
    @Published var halfMeanSpeed: Int = 0

    private var runTask: Task<Void, Never>?
    private var token: DirtyTestCancellationToken?
    private var recentSpeedWindow: [Int] = []
    private var speedSampleCount = 0
    private var speedSampleSum = 0

    func refreshVolumes() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRemovableKey]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return }
        let infos: [VolumeInfo] = urls.compactMap { url in
            guard let res = try? url.resourceValues(forKeys: Set(keys)),
                  let total = res.volumeTotalCapacity,
                  let free = res.volumeAvailableCapacity else { return nil }
            let name = res.volumeName ?? url.lastPathComponent
            return VolumeInfo(
                path: url.path,
                displayName: name,
                freeMiB: free / (1024 * 1024),
                totalMiB: total / (1024 * 1024)
            )
        }
        mountedVolumes = infos
        if selectedVolume == nil, let first = infos.first {
            selectVolume(first)
        }
    }

    func selectVolume(_ volume: VolumeInfo) {
        selectedVolume = volume
        // For the root volume ("/"), default to the home directory so the test
        // files are written to a user-writable location, not the FS root.
        let writePath = volume.path == "/"
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : volume.path
        targetPath = writePath
        diskFreeText = volume.freeText
        diskTotalText = volume.totalText
        Task.detached { [path = volume.path] in
            let model = readDiskModel(forPath: path) ?? "알 수 없음"
            await MainActor.run { self.diskModel = model }
        }
    }

    func pickTargetDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            targetPath = url.path
            updateDiskInfo(for: url.path)
        }
    }

    func updateDiskInfo(for path: String) {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return }
        let blockSize = UInt64(stats.f_bsize)
        let freeMiB = Int(UInt64(stats.f_bavail) * blockSize / (1024 * 1024))
        let totalMiB = Int(UInt64(stats.f_blocks) * blockSize / (1024 * 1024))
        diskFreeText = freeMiB >= 1024
            ? String(format: "%.1f GiB", Double(freeMiB) / 1024)
            : "\(freeMiB) MiB"
        diskTotalText = totalMiB >= 1024
            ? String(format: "%.1f GiB", Double(totalMiB) / 1024)
            : "\(totalMiB) MiB"
        Task.detached { [path] in
            let model = readDiskModel(forPath: path) ?? "알 수 없음"
            await MainActor.run { self.diskModel = model }
        }
    }

    func pickLogFile(isDetailed: Bool) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = isDetailed ? "dirtytest-detail.csv" : "dirtytest.log"
        if panel.runModal() == .OK, let url = panel.url {
            if isDetailed {
                detailedLogPath = url.path
            } else {
                logPath = url.path
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        do {
            let config = try makeConfiguration()
            let token = DirtyTestCancellationToken()
            self.token = token

            logs.removeAll()
            currentCycleLogs.removeAll()
            summaryText = ""
            errorText = ""
            resetProgressState()
            speedPoints = []
            halfMeanSpeed = 0
            recentSpeedWindow.removeAll()
            isRunning = true
            isPaused = false

            runTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let engine = DirtyTestEngine(configuration: config)
                do {
                    try engine.run(
                        cancellationToken: token,
                        callbacks: DirtyTestCallbacks(
                            onMessage: { message in
                                Task { @MainActor in
                                    self.appendLog(message)
                                }
                            },
                            onProgress: { progress in
                                Task { @MainActor in
                                    self.handleProgress(progress)
                                }
                            },
                            onSummary: { summary in
                                let text = String(
                                    format: "Cycle %d | Max %d MiB/s | Min %d MiB/s | Mean %d MiB/s | <=50%% Mean %.1f%% | Cycle %.1fs",
                                    summary.cycle,
                                    summary.maxSpeedMiBps,
                                    summary.minSpeedMiBps,
                                    summary.averageSpeedMiBps,
                                    summary.belowHalfAveragePercent,
                                    summary.elapsedCycleSeconds
                                )
                                Task { @MainActor in
                                    self.summaryText = text
                                    self.appendLog(text)
                                    self.halfMeanSpeed = summary.averageSpeedMiBps / 2
                                    self.runningMeanSpeedMiBps = summary.averageSpeedMiBps
                                }
                            },
                            onCycleStart: {
                                Task { @MainActor in
                                    self.currentCycleLogs.removeAll()
                                    self.resetProgressState()
                                    self.speedPoints.removeAll()
                                    self.halfMeanSpeed = 0
                                    self.recentSpeedWindow.removeAll()
                                }
                            }
                        )
                    )
                    Task { @MainActor in
                        self.isRunning = false
                        self.isPaused = false
                        self.token = nil
                        self.runTask = nil
                    }
                } catch {
                    Task { @MainActor in
                        self.errorText = error.localizedDescription
                        self.isRunning = false
                        self.isPaused = false
                        self.token = nil
                        self.runTask = nil
                    }
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func stop() {
        token?.cancel()
        isPaused = false
    }

    func togglePause() {
        guard let token, isRunning else { return }
        if isPaused {
            token.resume()
            isPaused = false
        } else {
            token.pause()
            isPaused = true
        }
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        currentCycleLogs.append(message)
    }

    private func handleProgress(_ progress: DirtyTestProgress) {
        progressPercent = progress.progressPercent
        writtenMiB = progress.writtenMiB
        totalMiB = progress.totalToWriteMiB
        speedMiBps = progress.speedMiBps
        freePercent = progress.freePercent

        if progress.speedMiBps > 0 {
            speedSampleCount += 1
            speedSampleSum += progress.speedMiBps
            runningMeanSpeedMiBps = speedSampleSum / speedSampleCount
        }

        updateEta(writtenMiB: progress.writtenMiB, totalMiB: progress.totalToWriteMiB, speedMiBps: progress.speedMiBps)
        speedPoints.append(
            SpeedPoint(freePercent: progress.freePercent, speedMiBps: progress.speedMiBps)
        )
    }

    private func resetProgressState() {
        progressPercent = 0
        writtenMiB = 0
        totalMiB = 0
        speedMiBps = 0
        runningMeanSpeedMiBps = 0
        freePercent = 0
        etaText = "예상 남은 시간: --"
        speedSampleCount = 0
        speedSampleSum = 0
    }

    private func updateEta(writtenMiB: Int, totalMiB: Int, speedMiBps: Int) {
        if speedMiBps > 0 {
            recentSpeedWindow.append(speedMiBps)
            if recentSpeedWindow.count > 20 {
                recentSpeedWindow.removeFirst(recentSpeedWindow.count - 20)
            }
        }

        let validSpeeds = recentSpeedWindow.filter { $0 > 0 }
        guard !validSpeeds.isEmpty else {
            etaText = "예상 남은 시간: --"
            return
        }

        let remainingMiB = max(totalMiB - writtenMiB, 0)
        if remainingMiB == 0 {
            etaText = "예상 남은 시간: 00:00"
            return
        }

        let meanSpeed = Double(validSpeeds.reduce(0, +)) / Double(validSpeeds.count)
        let seconds = Int(Double(remainingMiB) / max(meanSpeed, 1.0))
        etaText = "예상 남은 시간: \(formatDuration(seconds))"
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func makeConfiguration() throws -> DirtyTestConfiguration {
        guard let leaveValue = Double(leaveValueText) else {
            throw DirtyTestError.invalidArgument("Leave value must be numeric")
        }

        guard let bufferMiB = Int(bufferMiBText), bufferMiB > 0 else {
            throw DirtyTestError.invalidArgument("Buffer MiB must be a positive integer")
        }

        guard let randomnessPercent = Int(randomnessText), (0...100).contains(randomnessPercent) else {
            throw DirtyTestError.invalidArgument("Randomness must be in 0...100")
        }

        // Map writeMode + leaveUnit to the effective LeaveUnit enum value.
        let effectiveUnit: LeaveUnit
        if writeMode {
            effectiveUnit = leaveUnit == .mib ? .writeMib : .writeGib
        } else {
            effectiveUnit = leaveUnit
        }

        return DirtyTestConfiguration(
            targetPath: targetPath,
            leaveValue: leaveValue,
            leaveUnit: effectiveUnit,
            speedUnit: speedUnit,
            useCache: useCache,
            needDelete: needDelete,
            repeatMode: repeatMode,
            logPath: logPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : logPath,
            detailedLogPath: detailedLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : detailedLogPath,
            bufferMiB: bufferMiB,
            randomnessPercent: randomnessPercent
        )
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: DirtyTestViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SettingsPanel(viewModel: viewModel)
                .frame(width: 320)
                .padding(12)

            Divider()

            ResultsPanel(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
        .onAppear {
            viewModel.refreshVolumes()
            viewModel.updateDiskInfo(for: viewModel.targetPath)
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var viewModel: DirtyTestViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("드라이브") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("볼륨", selection: $viewModel.selectedVolume) {
                            ForEach(viewModel.mountedVolumes) { vol in
                                Text("\(vol.displayName) (\(vol.freeText) free)").tag(Optional(vol))
                            }
                        }
                        .onChange(of: viewModel.selectedVolume) { vol in
                            if let vol { viewModel.selectVolume(vol) }
                        }

                        HStack {
                            TextField("경로", text: $viewModel.targetPath)
                                .onChange(of: viewModel.targetPath) { path in
                                    viewModel.updateDiskInfo(for: path)
                                }
                            Button("선택") { viewModel.pickTargetDirectory() }
                        }

                        if !viewModel.diskFreeText.isEmpty {
                            HStack(spacing: 16) {
                                Label("여유: \(viewModel.diskFreeText)", systemImage: "internaldrive")
                                    .font(.callout)
                                Text("전체: \(viewModel.diskTotalText)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !viewModel.diskModel.isEmpty {
                            Label(viewModel.diskModel, systemImage: "cpu")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("테스트 설정") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $viewModel.writeMode) {
                            Text("남길 용량").tag(false)
                            Text("쓸 용량").tag(true)
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text(viewModel.writeMode ? "쓸 용량" : "남길 용량")
                            TextField("10", text: $viewModel.leaveValueText)
                                .frame(width: 70)
                            Picker("", selection: $viewModel.leaveUnit) {
                                Text("GiB").tag(LeaveUnit.gib)
                                Text("MiB").tag(LeaveUnit.mib)
                                if !viewModel.writeMode {
                                    Text("%").tag(LeaveUnit.percent)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: viewModel.writeMode) { isWrite in
                                if isWrite && viewModel.leaveUnit == .percent {
                                    viewModel.leaveUnit = .gib
                                }
                            }
                        }

                        HStack {
                            Text("속도 로그 단위")
                            Picker("", selection: $viewModel.speedUnit) {
                                Text("0.1%").tag(SpeedUnit.zeroPointOne)
                                Text("1%").tag(SpeedUnit.one)
                                Text("10%").tag(SpeedUnit.ten)
                            }
                            .pickerStyle(.segmented)
                        }

                        HStack {
                            Toggle("캐시 사용", isOn: $viewModel.useCache)
                            Toggle("파일 삭제", isOn: $viewModel.needDelete)
                        }

                        Picker("반복 모드", selection: $viewModel.repeatMode) {
                            Text("1회").tag(RepeatMode.once)
                            Text("무한 반복").tag(RepeatMode.infinite)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                GroupBox("고급 설정") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("버퍼 (MiB)")
                            TextField("8", text: $viewModel.bufferMiBText)
                                .frame(width: 60)
                            Text("랜덤")
                            TextField("100", text: $viewModel.randomnessText)
                                .frame(width: 50)
                            Text("%")
                        }
                    }
                }

                GroupBox("로그 저장") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("요약 로그 경로", text: $viewModel.logPath)
                            Button("선택") { viewModel.pickLogFile(isDetailed: false) }
                        }
                        HStack {
                            TextField("상세 CSV 경로", text: $viewModel.detailedLogPath)
                            Button("선택") { viewModel.pickLogFile(isDetailed: true) }
                        }
                    }
                }
            }
            .disabled(viewModel.isRunning)

            Spacer()

            HStack(spacing: 8) {
                Button {
                    viewModel.start()
                } label: {
                    Label("시작", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRunning)

                Button {
                    viewModel.togglePause()
                } label: {
                    Label(viewModel.isPaused ? "재개" : "일시정지", systemImage: viewModel.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(!viewModel.isRunning)

                Button {
                    viewModel.stop()
                } label: {
                    Label("중지", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(!viewModel.isRunning)
            }

            if !viewModel.errorText.isEmpty {
                Text(viewModel.errorText)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ResultsPanel: View {
    @ObservedObject var viewModel: DirtyTestViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("진행 상황") {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(viewModel.progressPercent), total: 100)
                        .progressViewStyle(.linear)
                    HStack(spacing: 20) {
                        Label("\(viewModel.progressPercent)%", systemImage: "chart.bar.fill")
                        Label("\(viewModel.writtenMiB) / \(viewModel.totalMiB) MiB", systemImage: "arrow.up.doc.fill")
                        Label("현재 \(viewModel.speedMiBps) MiB/s", systemImage: "speedometer")
                        Label("평균 \(viewModel.runningMeanSpeedMiBps) MiB/s", systemImage: "chart.line.uptrend.xyaxis")
                        Label(String(format: "여유 공간: %.1f%%", viewModel.freePercent), systemImage: "internaldrive")
                        Label(viewModel.etaText, systemImage: "clock")
                    }
                    .font(.callout.weight(.medium))
                    if !viewModel.summaryText.isEmpty {
                        Text(viewModel.summaryText)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            GroupBox("속도 그래프") {
                SpeedChartView(
                    speedPoints: viewModel.speedPoints,
                    halfMeanSpeed: viewModel.halfMeanSpeed
                )
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            }

            GroupBox("로그") {
                VStack(spacing: 4) {
                    Picker("", selection: $viewModel.logTab) {
                        Text("전체 로그").tag(0)
                        Text("현재 사이클").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(
                                    Array((viewModel.logTab == 0 ? viewModel.logs : viewModel.currentCycleLogs).enumerated()),
                                    id: \.offset
                                ) { index, line in
                                    Text(line)
                                        .font(.system(.footnote, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id(index)
                                }
                            }
                        }
                        .onChange(of: viewModel.logs.count) { newCount in
                            if viewModel.logTab == 0, newCount > 0 {
                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
                        .onChange(of: viewModel.currentCycleLogs.count) { newCount in
                            if viewModel.logTab == 1, newCount > 0 {
                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

struct SpeedChartView: View {
    let speedPoints: [DirtyTestViewModel.SpeedPoint]
    let halfMeanSpeed: Int

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Adaptive colours

    private var plotBackground: Color {
        colorScheme == .dark ? Color.black.opacity(0.82) : Color(nsColor: .controlBackgroundColor)
    }
    private var outerBackground: Color {
        colorScheme == .dark ? Color.black.opacity(0.9) : Color(nsColor: .windowBackgroundColor)
    }
    private var plotBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.12)
    }
    private var gridColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.1)
    }
    private var tickColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.5)
    }
    private var labelColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.9) : Color.primary
    }
    private var emptyTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.75) : Color.secondary
    }

    // MARK: - Dynamic domains

    /// X domain: reversed (높은 % 왼쪽 → 낮은 % 오른쪽), 실제 데이터 범위에 맞게 자동 줌
    private var xDomain: [Double] {
        guard !speedPoints.isEmpty else { return [100.0, 0.0] }
        let hi = speedPoints.map(\.freePercent).max()!
        let lo = speedPoints.map(\.freePercent).min()!
        let range = max(hi - lo, 1.0)
        let pad = range * 0.04
        return [min(hi + pad, 100.0), max(lo - pad, 0.0)]
    }

    /// Y domain: 0 ~ 최고 속도의 115% (그래프가 꽉 차도록 + 여백)
    private var yUpper: Double {
        let maxSpeed = speedPoints.map(\.speedMiBps).max() ?? 100
        return Double(maxSpeed) * 1.15
    }

    var body: some View {
        Chart {
            ForEach(speedPoints) { point in
                AreaMark(
                    x: .value("남은 용량", point.freePercent),
                    y: .value("속도", point.speedMiBps)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.blue.opacity(0.55))

                LineMark(
                    x: .value("남은 용량", point.freePercent),
                    y: .value("속도", point.speedMiBps)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }

            if halfMeanSpeed > 0 {
                RuleMark(y: .value("산술평균 50%", halfMeanSpeed))
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("산술평균(Mean)의 50%: \(halfMeanSpeed) MiB/s")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: [0.0, yUpper])
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(gridColor)
                AxisTick(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(tickColor)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%.0f%%", v))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(labelColor)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(gridColor)
                AxisTick(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(tickColor)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(labelColor)
                    }
                }
            }
        }
        .chartXAxisLabel("남은 용량 (%)", alignment: .center)
        .chartYAxisLabel("속도 (MiB/s)")
        .chartPlotStyle { plot in
            plot
                .background(plotBackground)
                .border(plotBorder, width: 1)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(outerBackground)
        }
        .overlay {
            if speedPoints.isEmpty {
                Text("속도 그래프는 테스트 시작 후 표시됩니다")
                    .font(.caption)
                    .foregroundStyle(emptyTextColor)
            }
        }
    }
}
