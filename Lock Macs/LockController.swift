import Foundation
import Observation

/// What the lock command is sent to.
enum LockTarget: String, CaseIterable, Identifiable {
    case serial = "Serial Number"
    case smartGroup = "Smart Group"
    var id: Self { self }
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
    var target: LockTarget = .serial
    var serial = ""
    var selectedGroupID: Int?
    var extensionAttributeID = UserDefaults.standard.string(forKey: "extensionAttributeID") ?? "" {
        didSet { UserDefaults.standard.set(extensionAttributeID, forKey: "extensionAttributeID") }
    }
    var lockMessage = UserDefaults.standard.string(forKey: "lockMessage") ?? "" {
        didSet { UserDefaults.standard.set(lockMessage, forKey: "lockMessage") }
    }

    // State
    private(set) var groups: [JamfComputerGroup] = []
    private(set) var computers: [JamfComputer] = []
    private(set) var extensionAttributeName: String?
    private(set) var results: [LockResult] = []
    private(set) var isBusy = false
    var errorMessage: String?

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

    var canFind: Bool {
        guard !isBusy, hasCredentials, Int(extensionAttributeID.trimmed) != nil else { return false }
        switch target {
        case .serial: return !serial.trimmed.isEmpty
        case .smartGroup: return selectedGroupID != nil
        }
    }

    var hasCredentials: Bool {
        !serverURL.trimmed.isEmpty && !clientID.trimmed.isEmpty && !clientSecret.isEmpty
    }

    /// Macs that can actually receive MDM commands.
    var lockableComputers: [JamfComputer] {
        computers.filter { !$0.managementId.isEmpty }
    }

    var canLock: Bool {
        !isBusy && !lockableComputers.isEmpty && extensionAttributeName != nil
    }

    /// Removing a lock code only edits inventory, so Macs without MDM are included.
    var canRemoveCodes: Bool {
        !isBusy && !computers.isEmpty && extensionAttributeName != nil
    }

    /// Clears the previewed Macs when an input changes, so a stale list can't be locked.
    func inputsChanged() {
        computers = []
        extensionAttributeName = nil
        results = []
    }

    // MARK: - Keychain

    func saveToKeychain() {
        do {
            try KeychainStore.save(SavedCredentials(serverURL: serverURL.trimmed, clientID: clientID.trimmed, clientSecret: clientSecret))
            isSavedInKeychain = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFromKeychain() {
        do {
            try KeychainStore.delete()
            isSavedInKeychain = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    func loadGroups() async {
        await run { client in
            groups = try await client.smartGroups()
            if let selectedGroupID, !groups.contains(where: { $0.id == selectedGroupID }) {
                self.selectedGroupID = nil
            }
        }
    }

    /// Resolves the target Macs and checks the extension attribute, without changing anything.
    func findComputers() async {
        inputsChanged()
        await run { client in
            let eaID = extensionAttributeID.trimmed
            extensionAttributeName = try await client.extensionAttributeName(id: eaID)

            switch target {
            case .serial:
                computers = [try await client.computer(serial: serial)]
            case .smartGroup:
                guard let selectedGroupID else { return }
                computers = try await client.members(ofGroup: selectedGroupID)
                if computers.isEmpty {
                    throw JamfError.notFound("That smart group has no members.")
                }
            }
        }
    }

    /// For each Mac: generates a PIN, stores it in the extension attribute, then sends the lock.
    /// The lock is only sent once the PIN is safely stored, so a code is never lost.
    func lockComputers() async {
        let targets = lockableComputers
        let eaID = extensionAttributeID.trimmed
        let message = lockMessage.trimmed
        results = targets.map { LockResult(computer: $0, pin: Self.makePIN()) }

        await run { client in
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

    /// Clears the stored PIN from the extension attribute on each found Mac.
    func removeLockCodes() async {
        let eaID = extensionAttributeID.trimmed
        results = computers.map { LockResult(computer: $0, pin: "", lockStatus: nil) }

        await run { client in
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
    private func run(_ work: (JamfClient) async throws -> Void) async {
        isBusy = true
        errorMessage = nil
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
