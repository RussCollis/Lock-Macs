import SwiftUI

struct ContentView: View {
    @State private var controller = LockController()
    @State private var isConfirmingLock = false
    @State private var isConfirmingRemove = false

    var body: some View {
        @Bindable var controller = controller

        NavigationStack {
            HStack(spacing: 0) {
                LockSidePanel()
                // Setup column
                Form {
                    Section {
                        TextField("Jamf Pro URL", text: $controller.serverURL, prompt: Text("https://yourorg.jamfcloud.com"))
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                        TextField("API Client ID", text: $controller.clientID)
                            .autocorrectionDisabled()
                        SecureField("API Client Secret", text: $controller.clientSecret)

                        HStack {
                            Button("Save to Keychain", systemImage: "key.fill") {
                                controller.saveToKeychain()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                            .disabled(!controller.hasCredentials)

                            Button("Remove from Keychain", systemImage: "trash", role: .destructive) {
                                controller.removeFromKeychain()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(!controller.isSavedInKeychain)

                            Spacer()

                            if controller.isSavedInKeychain {
                                Label("Saved in Keychain", systemImage: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    } header: {
                        Text("Jamf Pro")
                    } footer: {
                        Text("API role needs: Read Computers, Update Computers, Read Smart Computer Groups, Read Computer Extension Attributes, Update Computer Extension Attributes, Send Computer Remote Lock Command. The secret is only stored if you save it to the Keychain.")
                    }

                    Section {
                        TextField("Extension Attribute ID", text: $controller.extensionAttributeID)
                        if let name = controller.extensionAttributeName {
                            LabeledContent("Extension Attribute", value: name)
                        }
                    } header: {
                        Text("Extension Attribute")
                    } footer: {
                        Text("A text field extension attribute that holds each Mac's lock PIN. Used by both Lock and Remove Lock Codes.")
                    }

                    if let error = controller.errorMessage, controller.errorOperation == nil {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .formStyle(.grouped)

                Divider()

                // Actions sit in a second column so the whole window fits without scrolling
                Form {

                    Section {
                        TargetFields(controller: controller, selection: $controller.lockSelection, title: "Lock")
                        TextField("Lock Screen Message", text: $controller.lockMessage, axis: .vertical)
                            .lineLimit(3...5)

                        HStack {
                            Button("Find Macs", systemImage: "magnifyingglass") {
                                Task { await controller.findComputers(for: .lock) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(!controller.canFind(for: .lock))

                            Button("Lock \(controller.lockableComputers.count) Mac(s)…", systemImage: "lock.fill", role: .destructive) {
                                isConfirmingLock = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(!controller.canLock)

                            Spacer()

                            if controller.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        ActionStatus(controller: controller, operation: .lock)
                    } header: {
                        Text("Lock")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A random six digit PIN is created for each Mac and saved to the extension attribute before the lock is sent. Message: \(controller.lockMessage.count) characters.")
                            if controller.lockMessage.count > LockController.recommendedMessageLength {
                                Label("Long messages may be cut off on the lock screen. Test on one Mac first.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Section {
                        TargetFields(controller: controller, selection: $controller.removeSelection, title: "Remove Codes From")

                        HStack {
                            Button("Find Macs", systemImage: "magnifyingglass") {
                                Task { await controller.findComputers(for: .removeCodes) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(!controller.canFind(for: .removeCodes))

                            Button("Remove Codes (\(controller.removeSelection.computers.count))…", systemImage: "lock.open.fill") {
                                isConfirmingRemove = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(!controller.canRemoveCodes)

                            Spacer()

                            if controller.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        ActionStatus(controller: controller, operation: .removeCodes)
                    } header: {
                        Text("Remove Lock Codes")
                    } footer: {
                        Text("Clears the stored PIN from the extension attribute. Independent of the Lock target above.")
                    }

                }
                .formStyle(.grouped)

                Divider()

                ResultsPanel(controller: controller)
                    .frame(width: 320)
            }
            .navigationTitle("Jamf Remote Lock")
            #if os(macOS)
            // The title is shown in the side panel, so hide it from the title bar
            .toolbar(removing: .title)
            #endif
            #if os(macOS)
            // Large enough to show every option in one window without scrolling
            .frame(minWidth: 1320, minHeight: 760)
            #endif
            .confirmationDialog(
                "Lock \(controller.lockableComputers.count) Mac(s)?",
                isPresented: $isConfirmingLock,
                titleVisibility: .visible
            ) {
                Button("Lock", role: .destructive) {
                    Task { await controller.lockComputers() }
                }
            } message: {
                Text("Each Mac will be locked with its own PIN, saved to “\(controller.extensionAttributeName ?? "")”. The Macs will restart and can only be unlocked with that PIN.")
            }
            .confirmationDialog(
                "Remove lock codes from \(controller.removeSelection.computers.count) Mac(s)?",
                isPresented: $isConfirmingRemove,
                titleVisibility: .visible
            ) {
                Button("Remove Lock Codes", role: .destructive) {
                    Task { await controller.removeLockCodes() }
                }
            } message: {
                Text("This clears “\(controller.extensionAttributeName ?? "")” for each Mac. Only do this once the Macs are unlocked, as any Mac that is still locked will need its PIN.")
            }
            // Any change to the inputs clears the preview, so a stale list can't be locked
            .onChange(of: controller.lockSelection.kind) { controller.inputsChanged(for: .lock) }
            .onChange(of: controller.lockSelection.serial) { controller.inputsChanged(for: .lock) }
            .onChange(of: controller.lockSelection.groupID) { controller.inputsChanged(for: .lock) }
            .onChange(of: controller.removeSelection.kind) { controller.inputsChanged(for: .removeCodes) }
            .onChange(of: controller.removeSelection.serial) { controller.inputsChanged(for: .removeCodes) }
            .onChange(of: controller.removeSelection.groupID) { controller.inputsChanged(for: .removeCodes) }
            .onChange(of: controller.extensionAttributeID) { controller.sharedInputsChanged() }
            .onChange(of: controller.serverURL) { controller.sharedInputsChanged() }
            // Restores a smart group selected last time the app was used
            .task { await controller.loadGroupsIfNeeded() }
        }
    }
}

/// Serial number or smart group inputs for one action.
private struct TargetFields: View {
    let controller: LockController
    @Binding var selection: TargetSelection
    let title: String

    var body: some View {
        Picker(title, selection: $selection.kind) {
            ForEach(LockTarget.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: selection.kind) {
            // Load the groups the first time a smart group target is chosen
            if selection.kind == .smartGroup, controller.groups.isEmpty, controller.hasCredentials, !controller.isBusy {
                Task { await controller.loadGroups() }
            }
        }

        switch selection.kind {
        case .serial:
            TextField("Serial Number", text: $selection.serial)
                .autocorrectionDisabled()
        case .smartGroup:
            HStack {
                Picker("Smart Group", selection: $selection.groupID) {
                    Text(controller.groups.isEmpty ? "Load groups first" : "Choose…").tag(Int?.none)
                    // A saved group shows by ID until the list loads, so the picker never
                    // has a selection without a matching tag (which can reset it)
                    if let id = selection.groupID, !controller.groups.contains(where: { $0.id == id }) {
                        Text("Group \(id)").tag(Optional(id))
                    }
                    ForEach(controller.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                Button("Load Groups", systemImage: "arrow.clockwise") {
                    Task { await controller.loadGroups() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(controller.isBusy || !controller.hasCredentials)
            }
            if !controller.groups.isEmpty {
                Text("\(controller.groups.count) smart groups loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows an action's error, or why its Find Macs button is unavailable.
private struct ActionStatus: View {
    let controller: LockController
    let operation: LockOperation

    var body: some View {
        if let error = controller.errorMessage, controller.errorOperation == operation {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if !controller.isBusy, let reason = controller.findBlocker(for: operation) {
            Label(reason, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Right-hand panel listing the Macs found, then the outcome for each once an action runs.
private struct ResultsPanel: View {
    let controller: LockController

    private var panelTitle: String {
        let action = controller.panelOperation == .removeCodes ? "Remove Codes" : "Lock"
        return "Macs Found for \(action) (\(controller.panelComputers.count))"
    }

    var body: some View {
        if !controller.results.isEmpty {
            Form {
                Section("Results") {
                    ForEach(controller.results) { result in
                        ResultRow(result: result)
                    }
                }
            }
            .formStyle(.grouped)
        } else if !controller.panelComputers.isEmpty {
            Form {
                Section(panelTitle) {
                    ForEach(controller.panelComputers) { computer in
                        ComputerRow(computer: computer)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No Macs Yet",
                systemImage: "desktopcomputer",
                description: Text("Click Find Macs to list the Macs that will be locked or have their lock codes removed. Results appear here.")
            )
        }
    }
}

/// Decorative column beside the form showing a locked Mac.
private struct LockSidePanel: View {
    /// For example "Version 1.0 (42)"; the build number goes up on every build.
    static let versionText: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }()

    var body: some View {
        VStack(spacing: 12) {
            Image("SidebarImage")
                .resizable()
                .scaledToFit()
                .frame(width: 170)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            // Scales down rather than truncating, so the title always fits the bar
            Text("Jamf Remote Lock")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Spacer()
            Text(Self.versionText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 20)
        }
        .padding(.top, 36)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: 190)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.35, green: 0.70, blue: 1.00),
                    Color(red: 0.10, green: 0.45, blue: 0.90),
                    Color(red: 0.05, green: 0.20, blue: 0.60),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lock Macs")
    }
}

private struct ComputerRow: View {
    let computer: JamfComputer

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(computer.name)
                Text(computer.serialNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if computer.managementId.isEmpty {
                Label("Not MDM managed, will be skipped", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct ResultRow: View {
    let result: LockResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.computer.name)
                Text(result.computer.serialNumber)
                    .foregroundStyle(.secondary)
                Spacer()
                if !result.pin.isEmpty {
                    Text(result.pin)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let lockStatus = result.lockStatus {
                StatusLine(title: "Extension attribute", status: result.eaStatus)
                StatusLine(title: "Lock command", status: lockStatus)
            } else {
                StatusLine(title: "Remove lock code", status: result.eaStatus)
            }
        }
    }
}

private struct StatusLine: View {
    let title: String
    let status: LockResult.Status

    var body: some View {
        switch status {
        case .pending:
            Label("\(title): waiting", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .done:
            Label("\(title): sent", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let reason):
            Label("\(title): \(reason)", systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1340, height: 800)
}
