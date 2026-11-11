import SwiftUI

struct ContentView: View {
    @State private var controller = LockController()
    @State private var isConfirmingLock = false

    var body: some View {
        @Bindable var controller = controller

        NavigationStack {
            Form {
                Section {
                    TextField("Jamf Pro URL", text: $controller.serverURL, prompt: Text("https://yourorg.jamfcloud.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    TextField("API Client ID", text: $controller.clientID)
                        .autocorrectionDisabled()
                    SecureField("API Client Secret", text: $controller.clientSecret)
                } header: {
                    Text("Jamf Pro")
                } footer: {
                    Text("API role needs: Read Computers, Update Computers, Read Smart Computer Groups, Read Computer Extension Attributes, Update Computer Extension Attributes, Send Computer Remote Lock Command. The secret is never saved.")
                }

                Section("Target") {
                    Picker("Send Lock To", selection: $controller.target) {
                        ForEach(LockTarget.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch controller.target {
                    case .serial:
                        TextField("Serial Number", text: $controller.serial)
                            .autocorrectionDisabled()
                    case .smartGroup:
                        HStack {
                            Picker("Smart Group", selection: $controller.selectedGroupID) {
                                Text("Choose…").tag(Int?.none)
                                ForEach(controller.groups) { group in
                                    Text(group.name).tag(Optional(group.id))
                                }
                            }
                            Button("Load Groups") {
                                Task { await controller.loadGroups() }
                            }
                            .disabled(controller.isBusy || !controller.hasCredentials)
                        }
                    }
                }

                Section {
                    TextField("Extension Attribute ID", text: $controller.extensionAttributeID)
                    if let name = controller.extensionAttributeName {
                        LabeledContent("Extension Attribute", value: name)
                    }
                    TextField("Lock Screen Message", text: $controller.lockMessage, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Lock")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A random six digit PIN is created for each Mac and saved to the extension attribute (text field type) before the lock is sent. Message: \(controller.lockMessage.count) characters.")
                        if controller.lockMessage.count > LockController.recommendedMessageLength {
                            Label("Long messages may be cut off on the lock screen. Test on one Mac first.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button("Find Macs") {
                        Task { await controller.findComputers() }
                    }
                    .disabled(!controller.canFind)

                    Button("Lock \(controller.lockableComputers.count) Mac(s)…", role: .destructive) {
                        isConfirmingLock = true
                    }
                    .disabled(!controller.canLock)

                    if controller.isBusy {
                        ProgressView()
                    }
                }

                if let error = controller.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if !controller.results.isEmpty {
                    Section("Results") {
                        ForEach(controller.results) { result in
                            ResultRow(result: result)
                        }
                    }
                } else if !controller.computers.isEmpty {
                    Section("Macs Found (\(controller.computers.count))") {
                        ForEach(controller.computers) { computer in
                            ComputerRow(computer: computer)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Jamf Remote Lock")
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
            // Any change to the inputs clears the preview, so a stale list can't be locked
            .onChange(of: controller.target) { controller.inputsChanged() }
            .onChange(of: controller.serial) { controller.inputsChanged() }
            .onChange(of: controller.selectedGroupID) { controller.inputsChanged() }
            .onChange(of: controller.extensionAttributeID) { controller.inputsChanged() }
            .onChange(of: controller.serverURL) { controller.inputsChanged() }
        }
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
                Text(result.pin)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            StatusLine(title: "Extension attribute", status: result.eaStatus)
            StatusLine(title: "Lock command", status: result.lockStatus)
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
}
