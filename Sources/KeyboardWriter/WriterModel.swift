import AppKit
import WriterCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WriterModel: ObservableObject {
    enum Phase: Equatable {
        case setup
        case preparing
        case flashing
        case finished
        case failed(String)
    }

    /// Where the firmware comes from.
    enum Source: Equatable, Sendable {
        /// A CI firmware .zip, or a folder of .uf2 files.
        case file(URL)
        /// A build published by the config repo, downloaded when flashing starts.
        case build(Build)
    }

    let targets: Targets
    /// The config repo whose builds are offered, as "owner/name".
    private(set) var repo = UserDefaults.standard.string(forKey: "repo") ?? Builds.defaultRepo

    @Published private(set) var keyboard: Keyboard
    /// Names of the devices to flash (all of them unless some are clicked off).
    @Published private(set) var selected: Set<String>
    @Published var reset = false
    @Published var source: Source?
    /// The config repo's builds, newest first (empty until they have loaded).
    @Published private(set) var builds: [Build] = []
    @Published private(set) var buildsProblem: String?
    @Published private(set) var loadingBuilds = false

    @Published private(set) var phase: Phase = .setup
    @Published private(set) var plan: [Step] = []
    @Published private(set) var current = 0
    @Published private(set) var status: StepStatus = .waiting

    /// A newer release of this app, when there is one.
    @Published private(set) var update: AppRelease?
    @Published private(set) var updating = false
    @Published private(set) var updateProblem: String?

    private var roots = Drives.volumes
    private var pretendDrives = false
    private var task: Task<Void, Never>?
    private var startWhenShown = false
    /// False once the person (or smoke.sh) has said which firmware to use.
    private var sourceIsDefault = true

    init() {
        targets = Self.loadTargets()
        keyboard = targets.keyboards[0]
        selected = Set(targets.keyboards[0].devices.map(\.name))
        source = Firmware.newestDownload().map(Source.file)
        readArguments()
        if sourceIsDefault { loadBuilds() }
        checkForUpdate()
    }

    /// targets.json is copied into the .app by build.sh; from `swift run` it is read from the repo.
    private static func loadTargets() -> Targets {
        let inRepo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("targets.json")
        let url = Bundle.main.url(forResource: "targets", withExtension: "json") ?? inRepo
        do {
            return try Targets.load(from: url)
        } catch {
            fatalError("Can't read \(url.path): \(error)")
        }
    }

    /// For smoke.sh: start already set up, against pretend drives.
    private func readArguments() {
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--keyboard":
                if let id = arguments.next(), let match = targets.keyboards.first(where: { $0.id == id }) {
                    choose(match)
                }
            case "--firmware":
                if let path = arguments.next() {
                    use(.file(URL(fileURLWithPath: path)))
                }
            case "--repo":
                if let name = arguments.next() { repo = name }
            case "--reset": reset = true
            case "--start": startWhenShown = true
            case "--volumes":
                if let path = arguments.next() {
                    roots = [URL(fileURLWithPath: path)]
                    pretendDrives = true
                }
            default: break
            }
        }
    }

    // MARK: Setting up

    func choose(_ keyboard: Keyboard) {
        self.keyboard = keyboard
        selected = Set(keyboard.devices.map(\.name))
    }

    func toggle(_ device: Device) {
        if selected.contains(device.name) {
            selected.remove(device.name)
        } else {
            selected.insert(device.name)
        }
    }

    var canStart: Bool { source != nil && !selected.isEmpty && !updating }

    func use(_ source: Source) {
        self.source = source
        sourceIsDefault = false
    }

    var newestDownload: URL? { Firmware.newestDownload() }

    /// Asks the config repo for its builds. Until the person chooses
    /// something themselves, the newest build from main is the one used.
    func loadBuilds() {
        guard !loadingBuilds else { return }
        loadingBuilds = true
        let repo = repo
        Task {
            defer { loadingBuilds = false }
            do {
                builds = try await Builds.list(repo: repo)
                buildsProblem = nil
                if sourceIsDefault, let build = Builds.preferred(builds) {
                    source = .build(build)
                }
            } catch {
                buildsProblem = error.localizedDescription
            }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose the firmware .zip from a build, or a folder of .uf2 files"
        panel.allowedContentTypes = [.zip, .folder]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            use(.file(url))
        }
    }

    // MARK: Updating the app

    /// The running app, when it is a released build in a folder it can replace itself in.
    private var updatableBundle: URL? {
        let bundle = Bundle.main.bundleURL
        guard !pretendDrives,
            bundle.pathExtension == "app",
            let version = runningVersion, !version.isLocalBuild,
            FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
        else { return nil }
        return bundle
    }

    private var runningVersion: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    /// Asks GitHub for a newer release; a failed check shows nothing.
    private func checkForUpdate() {
        guard updatableBundle != nil, let running = runningVersion else { return }
        Task {
            update = try? await AppUpdates.newer(than: running)
        }
    }

    func installUpdate() {
        guard let update, !updating, phase == .setup,
            let bundle = updatableBundle, let identifier = Bundle.main.bundleIdentifier
        else { return }
        updating = true
        updateProblem = nil
        Task {
            do {
                try await Task.detached {
                    try await AppUpdates.install(update, replacing: bundle, bundleIdentifier: identifier)
                }.value
                try AppUpdates.relaunch(bundle)
                NSApp.terminate(nil)
            } catch {
                updateProblem = error.localizedDescription
                updating = false
            }
        }
    }

    // MARK: Flashing

    var step: Step? { plan.indices.contains(current) ? plan[current] : nil }

    func shown() {
        if startWhenShown {
            startWhenShown = false
            start()
        }
    }

    func start() {
        guard let source, canStart else { return }
        let keyboard = keyboard, selected = selected, reset = reset
        plan = []
        current = 0
        phase = .preparing
        task = Task {
            do {
                // Downloading and unzipping take a while, so keep them off the main thread.
                let plan = try await Task.detached { () async throws -> [Step] in
                    let firmware: URL
                    switch source {
                    case .file(let url): firmware = url
                    case .build(let build): firmware = try await Builds.download(build)
                    }
                    return try Firmware.plan(
                        keyboard: keyboard, only: selected, reset: reset, files: Firmware.unpack(firmware))
                }.value
                guard !Task.isCancelled else { return }
                self.plan = plan
                await run(from: 0)
            } catch {
                fail(error)
            }
        }
    }

    /// After a failure: carry on from the step that failed.
    func retry() {
        guard step != nil else { return start() }
        task = Task { await run(from: current) }
    }

    func stop() {
        task?.cancel()
        task = nil
        plan = []
        current = 0
        phase = .setup
    }

    private func run(from first: Int) async {
        phase = .flashing
        do {
            for index in plan.indices.dropFirst(first) {
                current = index
                status = .waiting
                try await flash(
                    plan[index], roots: roots, boards: targets.boards, ports: USBSerialPorts()
                ) { [weak self] status in
                    await self?.update(status)
                }
            }
            phase = .finished
        } catch is CancellationError {
            // stop() has already gone back to the start
        } catch {
            fail(error)
        }
    }

    private func update(_ status: StepStatus) {
        self.status = status
    }

    private func fail(_ error: Error) {
        guard !Task.isCancelled else { return }
        phase = .failed(error.localizedDescription)
    }

    // MARK: For the views

    enum DeviceProgress {
        case off, waiting, next, done
    }

    func progress(of device: Device) -> DeviceProgress {
        let steps = plan.filter { $0.device == device }
        guard let last = steps.last else { return .off }
        if phase == .finished || last.id < current { return .done }
        return steps.contains { $0.id == current } ? .next : .waiting
    }

    func boardLabel(_ board: String) -> String { targets.boards[board]?.label ?? board }
}
