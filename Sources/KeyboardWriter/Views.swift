import AppKit
import WriterCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: WriterModel

    var body: some View {
        Group {
            switch model.phase {
            case .setup: SetupView()
            case .preparing: PreparingView()
            case .flashing: FlashingView()
            case .finished: FinishedView()
            case .failed(let message): FailedView(message: message)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if model.phase == .setup, let update = model.update {
                UpdateButton(release: update)
                    .padding(.top, 4)
                    .padding(.trailing, 12)
            }
        }
        .animation(.default, value: model.phase)
        .onAppear { model.shown() }
    }
}

// MARK: - Setting up

struct SetupView: View {
    @EnvironmentObject private var model: WriterModel

    var body: some View {
        VStack(spacing: 22) {
            Picker("Keyboard", selection: Binding(get: { model.keyboard }, set: { model.choose($0) })) {
                ForEach(model.targets.keyboards) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            Spacer(minLength: 0)
            KeyboardPicture(
                devices: model.keyboard.devices,
                look: { model.selected.contains($0.name) ? .idle : .off },
                tap: { model.toggle($0) })
            Text("Click a device to leave it out")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)

            Toggle(isOn: $model.reset) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset settings first")
                    Text("Clears Bluetooth pairings, including this Mac's")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)

            FirmwareRow()

            Button {
                model.start()
            } label: {
                Text("Start").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canStart)
        }
    }
}

/// Sits in the window's top margin, so the setup layout stays where it is.
struct UpdateButton: View {
    @EnvironmentObject private var model: WriterModel
    let release: AppRelease

    var body: some View {
        HStack(spacing: 6) {
            if let problem = model.updateProblem {
                Text(problem)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(problem)
            }
            if model.updating {
                ProgressView().controlSize(.mini)
                Text("Updating…").foregroundStyle(.secondary)
            } else {
                Button("Update to \(release.version.description)") { model.installUpdate() }
                    .buttonStyle(.borderless)
                    .help("Install Keyboard Writer \(release.version.description) and reopen it")
            }
        }
        .font(.footnote)
        .frame(maxWidth: 300, alignment: .trailing)
    }
}

struct FirmwareRow: View {
    @EnvironmentObject private var model: WriterModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Menu("Choose…") {
                if model.builds.isEmpty {
                    Text(model.buildsProblem ?? "No builds from \(model.repo) yet")
                } else {
                    if let problem = model.buildsProblem { Text(problem) }
                    Section("Builds from \(model.repo)") {
                        ForEach(model.builds) { build in
                            Button(verbatim("\(build.title) (\(ago(build.date)))")) { model.use(.build(build)) }
                        }
                    }
                }
                Divider()
                if let download = model.newestDownload {
                    Button(verbatim("\(download.lastPathComponent) in Downloads")) { model.use(.file(download)) }
                }
                Button("Choose a File…") { model.chooseFile() }
            }
            .fixedSize()
            Button {
                model.loadBuilds()
            } label: {
                if model.loadingBuilds {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 22, height: 22)
            .buttonStyle(.borderless)
            .disabled(model.loadingBuilds)
            .help("Check \(model.repo) for new builds")
            .accessibilityLabel(model.loadingBuilds ? "Checking for builds" : "Check for new builds")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary))
    }

    private var title: String {
        switch model.source {
        case .build(let build)?: return build.title
        case .file(let url)?: return url.lastPathComponent
        case nil: return "No firmware chosen"
        }
    }

    private var detail: String? {
        switch model.source {
        case .build(let build)?: return "Built \(ago(build.date)) · \(model.repo)"
        case .file(let url)?: return "From \(ago(Firmware.modified(url)))"
        case nil: return model.buildsProblem
        }
    }

    /// A plain String, so a commit subject isn't read as Markdown.
    private func verbatim(_ text: String) -> String { text }

    private func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

struct PreparingView: View {
    var body: some View {
        ProgressView()
    }
}

// MARK: - Flashing

struct FlashingView: View {
    @EnvironmentObject private var model: WriterModel

    var body: some View {
        VStack(spacing: 0) {
            if let step = model.step {
                Text("Step \(step.id + 1) of \(model.plan.count) · \(step.kind == .settingsReset ? "settings reset" : "firmware")")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(step.id), total: Double(model.plan.count))
                    .padding(.top, 8)
                    .animation(.default, value: step.id)

                Spacer(minLength: 0)
                KeyboardPicture(devices: model.keyboard.devices, look: look)
                    .animation(.default, value: step.id)
                Spacer(minLength: 0)

                Text(step.device.what)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Instruction(step: step, status: model.status, again: again(step))
                    .padding(.top, 8)
                    .frame(height: 76, alignment: .top)

                if model.reset, let note = model.keyboard.resetNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                }
            }
            Button("Stop") { model.stop() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func look(_ device: Device) -> DeviceTile.Look {
        switch model.progress(of: device) {
        case .off: return .off
        case .waiting: return .idle
        case .next: return .next
        case .done: return .done
        }
    }

    /// True for a device's second trip into the bootloader (firmware after a settings reset).
    private func again(_ step: Step) -> Bool {
        model.plan.contains { $0.device == step.device && $0.id < step.id }
    }
}

/// What to do right now, or what is happening.
struct Instruction: View {
    @EnvironmentObject private var model: WriterModel
    let step: Step
    let status: StepStatus
    let again: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text(text)
                .font(.title3)
                .foregroundStyle(problem ? Color.orange : Color.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !problem {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .animation(.default, value: status)
    }

    private var problem: Bool {
        switch status {
        case .wrongBoard, .tooManyDrives: return true
        default: return false
        }
    }

    private var text: String {
        switch status {
        case .waiting, .starting:
            return again ? "Keep it plugged in" : "Plug it in"
        case .wrongBoard(let found):
            return "That's a \(model.boardLabel(found)), and this should be a "
                + "\(model.boardLabel(step.device.board)). Unplug it; nothing was copied."
        case .tooManyDrives:
            return "More than one bootloader drive is connected. Unplug the others."
        case .copying, .restarting, .done:
            return "Leave it plugged in"
        }
    }

    private var activity: String {
        switch status {
        case .waiting, .wrongBoard, .tooManyDrives:
            return "Waiting for it… double-tap reset if nothing happens"
        case .starting: return "Starting its bootloader…"
        case .copying: return step.kind == .settingsReset ? "Clearing its settings…" : "Copying the firmware…"
        case .restarting: return "Restarting…"
        case .done: return "Done"
        }
    }
}

// MARK: - The end

struct FinishedView: View {
    @EnvironmentObject private var model: WriterModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            KeyboardPicture(
                devices: model.keyboard.devices,
                look: { model.progress(of: $0) == .done ? .done : .off })
            Spacer(minLength: 0)
            Text("All done")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            if model.reset {
                Text("Pairings were cleared. Forget the keyboard in this Mac's Bluetooth settings, then pair it again.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Flash Something Else") { model.stop() }
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct FailedView: View {
    @EnvironmentObject private var model: WriterModel
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            if let step = model.step {
                Text(step.device.what).font(.title2.bold())
            }
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { model.stop() }
                Button("Try Again") { model.retry() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
