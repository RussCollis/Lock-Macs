import Foundation

/// A Mac in Jamf Pro, with the details needed to send it MDM commands.
struct JamfComputer: Identifiable, Hashable {
    let id: String
    let name: String
    let serialNumber: String
    let managementId: String
}

/// A static or smart computer group from the Classic API.
struct JamfComputerGroup: Identifiable, Hashable, Decodable {
    let id: Int
    let name: String
    let isSmart: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isSmart = "is_smart"
    }
}

enum JamfError: LocalizedError {
    case invalidURL
    case noToken
    case http(status: Int, path: String, body: String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Jamf Pro URL is not valid. Use the form https://yourorg.jamfcloud.com"
        case .noToken:
            return "Jamf Pro did not return an access token. Check the client ID and secret."
        case .http(let status, let path, let body):
            let hint: String
            switch status {
            case 401: hint = "Jamf rejected the API client. Check the client ID and secret."
            case 403: hint = "The API client's role is missing a privilege for this call."
            case 404: hint = "Jamf could not find the item."
            default: hint = "Jamf returned an error."
            }
            let detail = body.isEmpty ? "" : "\n\(body.prefix(300))"
            return "\(hint) (HTTP \(status) on \(path))\(detail)"
        case .notFound(let message):
            return message
        }
    }
}

/// Talks to the Jamf Pro API using an API client (OAuth client credentials).
///
/// API role privileges needed:
/// Read Computers, Update Computers, Read Smart Computer Groups,
/// Read Computer Extension Attributes, Update Computer Extension Attributes,
/// Send Computer Remote Lock Command.
final class JamfClient {
    private let baseURL: URL
    private let clientID: String
    private let clientSecret: String
    private let session: URLSession

    private var token: String?
    private var tokenExpiry = Date.distantPast

    init(serverURL: String, clientID: String, clientSecret: String) throws {
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.scheme == "https", url.host() != nil else {
            throw JamfError.invalidURL
        }
        self.baseURL = url
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auth

    /// Returns a valid bearer token, renewing it when it is close to expiry.
    private func bearerToken() async throws -> String {
        if let token, Date.now < tokenExpiry { return token }

        var request = URLRequest(url: baseURL.appending(path: "api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "grant_type", value: "client_credentials")
        ]
        // URLComponents leaves "+" alone, which a form body would read as a space
        let body = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        try check(response, data: data, path: "/api/oauth/token")

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw JamfError.noToken
        }
        token = decoded.access_token
        // Renew at half the lifetime, as API client tokens can be short lived
        tokenExpiry = Date.now.addingTimeInterval(Double(decoded.expires_in) / 2)
        return decoded.access_token
    }

    /// Invalidates the current token on the server. Errors are ignored.
    func invalidateToken() async {
        guard let token else { return }
        var request = URLRequest(url: baseURL.appending(path: "api/v1/auth/invalidate-token"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
        self.token = nil
        tokenExpiry = .distantPast
    }

    // MARK: - Requests

    private func send(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        json: [String: Any]? = nil
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw JamfError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let (data, response) = try await session.data(for: request)
        try check(response, data: data, path: path)
        return data
    }

    private func check(_ response: URLResponse, data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw JamfError.http(status: http.statusCode, path: path, body: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Inventory

    private struct InventoryPage: Decodable {
        struct Record: Decodable {
            struct General: Decodable {
                let name: String?
                let managementId: String?
            }
            struct Hardware: Decodable {
                let serialNumber: String?
            }
            let id: String
            let general: General?
            let hardware: Hardware?
        }
        let totalCount: Int
        let results: [Record]
    }

    /// Runs an RSQL filter against computer inventory and returns every match.
    private func computers(filter: String) async throws -> [JamfComputer] {
        var found: [JamfComputer] = []
        var page = 0
        while true {
            let data = try await send("GET", path: "api/v4/computers-inventory", query: [
                URLQueryItem(name: "section", value: "GENERAL"),
                URLQueryItem(name: "section", value: "HARDWARE"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: "100"),
                URLQueryItem(name: "filter", value: filter)
            ])
            let decoded = try JSONDecoder().decode(InventoryPage.self, from: data)
            found += decoded.results.map {
                JamfComputer(
                    id: $0.id,
                    name: $0.general?.name ?? "Unknown",
                    serialNumber: $0.hardware?.serialNumber ?? "",
                    managementId: $0.general?.managementId ?? ""
                )
            }
            page += 1
            if decoded.results.isEmpty || found.count >= decoded.totalCount { break }
        }
        return found
    }

    /// Looks up a single Mac by serial number.
    func computer(serial: String) async throws -> JamfComputer {
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Serials are letters and digits only; this also keeps the RSQL filter safe
        guard !serial.isEmpty, serial.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw JamfError.notFound("“\(serial)” doesn't look like a serial number.")
        }
        let matches = try await computers(filter: "hardware.serialNumber==\"\(serial)\"")
        guard let match = matches.first else {
            throw JamfError.notFound("No computer with serial \(serial) was found in Jamf Pro.")
        }
        return match
    }

    /// Lists computer groups (Classic API), smart groups only.
    func smartGroups() async throws -> [JamfComputerGroup] {
        struct Response: Decodable { let computer_groups: [JamfComputerGroup] }
        let data = try await send("GET", path: "JSSResource/computergroups")
        return try JSONDecoder().decode(Response.self, from: data).computer_groups
            .filter(\.isSmart)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Returns the members of a computer group, with their management IDs.
    func members(ofGroup groupID: Int) async throws -> [JamfComputer] {
        struct Response: Decodable {
            struct Group: Decodable {
                struct Member: Decodable { let id: Int }
                let computers: [Member]
            }
            let computer_group: Group
        }
        let data = try await send("GET", path: "JSSResource/computergroups/id/\(groupID)")
        let ids = try JSONDecoder().decode(Response.self, from: data).computer_group.computers.map(\.id)

        // Fetch inventory in batches so the filter stays a sensible length
        var result: [JamfComputer] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = ids[start..<min(start + 50, ids.count)].map(String.init).joined(separator: ",")
            result += try await computers(filter: "id=in=(\(batch))")
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Extension attributes

    /// Returns the name of a computer extension attribute, confirming it exists.
    func extensionAttributeName(id: String) async throws -> String {
        struct Response: Decodable { let name: String }
        let data = try await send("GET", path: "api/v1/computer-extension-attributes/\(id)")
        return try JSONDecoder().decode(Response.self, from: data).name
    }

    /// Writes a value to a text-field extension attribute on one computer.
    func setExtensionAttribute(id definitionId: String, value: String, computerID: String) async throws {
        _ = try await send("PATCH", path: "api/v4/computers-inventory-detail/\(computerID)", json: [
            "extensionAttributes": [
                ["definitionId": definitionId, "values": [value]]
            ]
        ])
    }

    // MARK: - MDM

    /// Sends a Device Lock command and returns the command UUID if Jamf supplies one.
    @discardableResult
    func sendDeviceLock(to computer: JamfComputer, pin: String, message: String) async throws -> String? {
        var commandData: [String: Any] = ["commandType": "DEVICE_LOCK", "pin": pin]
        if !message.isEmpty { commandData["message"] = message }

        let data = try await send("POST", path: "api/v2/mdm/commands", json: [
            "clientData": [["managementId": computer.managementId, "clientType": "COMPUTER"]],
            "commandData": commandData
        ])
        struct Sent: Decodable { let id: String? }
        return (try? JSONDecoder().decode([Sent].self, from: data))?.first?.id
    }
}
