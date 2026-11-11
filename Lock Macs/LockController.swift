import Foundation
import Observation

/// What the lock command is sent to.
enum LockTarget: String, CaseIterable, Identifiable {
    case serial = "Serial Number"
    case smartGroup = "Smart Group"
    var id: Self { self }
}

/// The two independent actions, each with its own target.
enum LockOperation {
    case lock
    case removeCodes
}

/// Which Macs an action applies to, and the Macs found for it.
struct TargetSelection {
    var kind: LockTarget = .serial
    var serial = ""
    var groupID: Int?
    var computers: [JamfComputer] = []

    /// Restores the target type and smart group saved under `key`.
    init(savedAs key: String) {
        let defaults = UserDefaults.standard
        kind = defaults.string(forKey: "\(key).kind").flatMap(LockTarget.init(rawValue:)) ?? .serial
        groupID = defaults.object(forKey: "\(key).groupID") as? Int
    }

    /// Remembers the target type and smart group, so they are selected on next launch.
    func save(as key: String) {
        let defaults = UserDefaults.standard
        defaults.set(kind.rawValue, forKey: "\(key).kind")
        defaults.set(groupID, forKey: "\(key).groupID")
    }
}

/// The outcome for one Mac, after locking it or removing its lock code.
struct LockResult: Identifiable {
    enum Status {
        case pending
        case done
        case failed(String)
    }

    let computer: JamfComputer
    /// The new PIN, or empty when the lock code is being removed.
    let pin: String
    var eaStatus: Status = .pending
    /// Nil when only the lock code is being removed and no command is sent.
    var lockStatus: Status? = .pending
    var id: String { computer.id }
}

@Observable
final class LockController {
    // Connection. The URL and client ID are remembered; the secret is held in memory
    // unless the user chooses to save the API details to the Keychain.
    var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var clientID = UserDefaults.standard.string(forKey: "clientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID, forKey: "clientID") }
    }
    var clientSecret = ""
    private(set) var isSavedInKeychain = false

    // Inputs
    var lockSelection = TargetSelection(savedAs: "lockSelection") {
        didSet { lockSelection.save(as: "lockSelection") }
    }
    var removeSelection = TargetSelection(savedAs: "removeSelection") {
        didSet { removeSelection.save(as: "removeSelection") }
    }
    var extensionAttributeID = UserDefaults.standard.string(forKey: "extensionAttributeID") ?? "" {
        didSet { UserDefaults.standard.set(extensionAttributeID, forKey: "extensionAttributeID") }
    }
    var lockMessage = UserDefaults.standard.string(forKey: "lockMessage") ?? "" {
        didSet { UserDefaults.standard.set(lockMessage, forKey: "lockMessage") }
    }

    // State
    private(set) var groups: [JamfComputerGroup] = []
    /// The action whose found Macs or results are shown in the results panel.
    private(set) var panelOperation: LockOperation?
    private(set) var extensionAttributeName: String?
    private(set) var results: [LockResult] = []
    private(set) var isBusy = false
    var errorMessage: String?
    /// The action that produced `errorMessage`, or nil for setup errors such as loading groups.
    private(set) var errorOperation: LockOperation?

    /// Apple documents no hard limit for the lock message, but long text may be
    /// cut off on the lock screen, so the UI warns (without blocking) past this.
    static let recommendedMessageLength = 200

    init() {
        if let saved = KeychainStore.load() {
            serverURL = saved.serverURL
            clientID = saved.clientID
            clientSecret = saved.clientSecret
            isSavedInKeychain = true
        }
    }

    func selection(for operation: LockOperation) -> TargetSelection {
        switch operation {
        case .lock: lockSelection
        case .removeCodes: removeSelection
        }
    }

    private func updateSelection(for operation: LockOperation, _ change: (inout TargetSelection) -> Void) {
        switch operation {
        case .lock: change(&lockSelection)
        case .removeCodes: change(&removeSelection)
        }
    }

    func canFind(for operation: LockOperation) -> Bool {
        !isBusy && findBlocker(for: operation) == nil
    }

    /// Why Find Macs is unavailable for an action, or nil when it can run.
    func findBlocker(for operation: LockOperation) -> String? {
        guard hasCredentials else { return "Enter the Jamf Pro URL, client ID and secret." }
        guard Int(extensionAttributeID.trimmed) != nil else { return "Enter a numeric extension attribute ID." }
        let selection = selection(for: operation)
        switch selection.kind {
        case .serial:
            return selection.serial.trimmed.isEmpty ? "Enter a serial number." : nil
        case .smartGroup:
            return selection.groupID == nil ? "Choose a smart group." : nil
        }
    }

    /// The Macs shown in the results panel before an action runs.
    var panelComputers: [JamfComputer] {
        guard let panelOperation else { return [] }
        return selection(for: panelOperation).computers
    }

    var hasCredentials: Bool {
        !serverURL.trimmed.isEmpty && !clientID.trimmed.isEmpty && !clientSecret.isEmpty
    }

    /// Macs that can actually receive MDM commands.
    var lockableComputers: [JamfComputer] {
        lockSelection.computers.filter { !$0.managementId.isEmpty }
    }

    var canLock: Bool {
        !isBusy && !lockableComputers.isEmpty && extensionAttributeName != nil
    }

    /// Removing a lock code only edits inventory, so Macs without MDM are included.
    var canRemoveCodes: Bool {
        !isBusy && !removeSelection.computers.isEmpty && extensionAttributeName != nil
    }

    /// Clears one action's previewed Macs when its target changes, so a stale list can't be used.
    func inputsChanged(for operation: LockOperation) {
        updateSelection(for: operation) { $0.computers = [] }
        if panelOperation == operation {
            results = []
        }
    }

    /// Clears everything found when a shared input (server or extension attribute) changes.
    func sharedInputsChanged() {
        lockSelection.computers = []
        removeSelection.computers = []
        extensionAttributeName = nil
        results = []
        panelOperation = nil
    }

    // MARK: - Keychain

    func saveToKeychain() {
        errorOperation = nil
        do {
            try KeychainStore.save(SavedCredentials(serverURL: serverURL.trimmed, clientID: clientID.trimmed, clientSecret: clientSecret))
            isSavedInKeychain = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFromKeychain() {
        errorOperation = nil
        do {
            try KeychainStore.delete()
            isSavedInKeychain = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    /// Loads the groups at launch when a saved target is a smart group, so its selection shows.
    func loadGroupsIfNeeded() async {
        let usesGroups = lockSelection.kind == .smartGroup || removeSelection.kind == .smartGroup
        guard usesGroups, groups.isEmpty, hasCredentials, !isBusy else { return }
        await loadGroups()
    }

    func loadGroups() async {
        await run { client in
            groups = try await client.smartGroups()
            let ids = Set(groups.map(\.id))
            if let id = lockSelection.groupID, !ids.contains(id) { lockSelection.groupID = nil }
            if let id = removeSelection.groupID, !ids.contains(id) { removeSelection.groupID = nil }
            if groups.isEmpty {
                throw JamfError.notFound("Jamf Pro returned no smart computer groups. Check the API role can read smart and static computer groups.")
            }
        }
    }

    /// Resolves the target Macs and checks the extension attribute, without changing anything.
    func findComputers(for operation: LockOperation) async {
        inputsChanged(for: operation)
        results = []
        panelOperation = operation
        let selection = selection(for: operation)
        await run(for: operation) { client in
            let eaID = extensionAttributeID.trimmed
            extensionAttributeName = try await client.extensionAttributeName(id: eaID)

            let found: [JamfComputer]
            switch selection.kind {
            case .serial:
                found = [try await client.computer(serial: selection.serial)]
            case .smartGroup:
                guard let groupID = selection.groupID else { return }
                found = try await client.members(ofGroup: groupID)
                if found.isEmpty {
                    throw JamfError.notFound("That smart group has no members, or none of its members could be found in inventory.")
                }
            }
            updateSelection(for: operation) { $0.computers = found }
        }
    }

    /// For each Mac: generates a PIN, stores it in the extension attribute, then sends the lock.
    /// The lock is only sent once the PIN is safely stored, so a code is never lost.
    func lockComputers() async {
        let targets = lockableComputers
        let eaID = extensionAttributeID.trimmed
        let message = lockMessage.trimmed
        panelOperation = .lock
        results = targets.map { LockResult(computer: $0, pin: Self.makePIN()) }

        await run(for: .lock) { client in
            for index in results.indices {
                let result = results[index]
                do {
                    try await client.setExtensionAttribute(id: eaID, value: result.pin, computerID: result.computer.id)
                    results[index].eaStatus = .done
                } catch {
                    results[index].eaStatus = .failed(error.localizedDescription)
                    results[index].lockStatus = .failed("Not sent: the PIN could not be saved to the extension attribute.")
                    continue
                }
                do {
                    try await client.sendDeviceLock(to: result.computer, pin: result.pin, message: message)
                    results[index].lockStatus = .done
                } catch {
                    results[index].lockStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Clears the stored PIN from the extension attribute on each Mac found for removal.
    func removeLockCodes() async {
        let eaID = extensionAttributeID.trimmed
        panelOperation = .removeCodes
        results = removeSelection.computers.map { LockResult(computer: $0, pin: "", lockStatus: nil) }

        await run(for: .removeCodes) { client in
            for index in results.indices {
                do {
                    try await client.setExtensionAttribute(id: eaID, value: "", computerID: results[index].computer.id)
                    results[index].eaStatus = .done
                } catch {
                    results[index].eaStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Helpers

    /// A random six digit PIN, as required by the macOS Device Lock command.
    /// SystemRandomNumberGenerator is cryptographically secure on Apple platforms.
    static func makePIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    /// Creates a client, runs the work, shows any error and always tidies up the token.
    private func run(for operation: LockOperation? = nil, _ work: (JamfClient) async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        errorOperation = operation
        defer { isBusy = false }
        do {
            let client = try JamfClient(serverURL: serverURL, clientID: clientID, clientSecret: clientSecret)
            do {
                try await work(client)
            } catch {
                errorMessage = error.localizedDescription
            }
            await client.invalidateToken()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
