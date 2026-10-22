import Foundation

/// Sends one HTTP request. Inject a mock in tests; the default is `URLSessionTransport`.
public protocol ProoflineTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed transport. The default session is ephemeral: no cookies, no URL cache.
public struct URLSessionTransport: ProoflineTransport {
    let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSessionTransport.makeDefaultSession()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }
}

/// SDK API client (`/api/sdk/v1/*`). Sends `X-Proofline-Key`, JSON bodies, and maps
/// `{ error: { code, message } }` responses to `ProoflineError`.
struct APIClient: Sendable {
    static let pathPrefix = "api/sdk/v1"
    static let keyHeader = "X-Proofline-Key"

    let appKey: String
    let baseURL: URL
    let transport: any ProoflineTransport
    let timeout: TimeInterval

    func session(_ body: SessionRequest) async throws(ProoflineError) -> SessionResponse {
        try await post("session", body)
    }

    func identify(_ body: IdentifyRequest) async throws(ProoflineError) -> IdentifyResponse {
        try await post("identify", body)
    }

    func code(_ body: CodeRequest) async throws(ProoflineError) -> CodeResponse {
        try await post("code", body)
    }

    func confirm(_ body: ConfirmRequest) async throws(ProoflineError) -> ConfirmResponse {
        try await post("confirm", body)
    }

    func attribution(endUserID: String) async throws(ProoflineError) -> AttributionResponse {
        try await get("attribution", query: [URLQueryItem(name: "endUserId", value: endUserID)])
    }

    func config() async throws(ProoflineError) -> ConfigResponse {
        try await get("config", query: [])
    }

    // MARK: - Request building

    func url(_ endpoint: String, query: [URLQueryItem]) -> URL {
        let url = baseURL.appendingPathComponent(Self.pathPrefix).appendingPathComponent(endpoint)
        guard !query.isEmpty, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = query
        return comps.url ?? url
    }

    func request(_ endpoint: String, method: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url(endpoint, query: query), cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(appKey, forHTTPHeaderField: Self.keyHeader)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func post<B: Encodable, R: Decodable>(_ endpoint: String, _ body: B) async throws(ProoflineError) -> R {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            data = try encoder.encode(body)
        } catch {
            throw .invalidInput("could not encode \(endpoint) request")
        }
        return try await perform(request(endpoint, method: "POST", body: data))
    }

    private func get<R: Decodable>(_ endpoint: String, query: [URLQueryItem]) async throws(ProoflineError) -> R {
        try await perform(request(endpoint, method: "GET", query: query))
    }

    private func perform<R: Decodable>(_ request: URLRequest) async throws(ProoflineError) -> R {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw .network("URLError \(error.code.rawValue)")
        } catch is CancellationError {
            throw .network("cancelled")
        } catch {
            throw .network(String(describing: type(of: error)))
        }
        let status = response.statusCode
        guard (200 ..< 300).contains(status) else { throw Self.mapError(status: status, data: data) }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw .invalidResponse("\(request.url?.lastPathComponent ?? "?") response did not match the contract")
        }
    }

    static func mapError(status: Int, data: Data) -> ProoflineError {
        let body = try? JSONDecoder().decode(ApiErrorBody.self, from: data)
        switch status {
        case 401: return .invalidAppKey
        case 403: return .disabled
        default:
            return .api(status: status, code: body?.error.code ?? "http_\(status)",
                        message: body?.error.message ?? "HTTP \(status)")
        }
    }
}

/// What the SDK does after a failed delivery.
enum DeliveryFailure: Equatable {
    /// Network or server trouble: keep the event and retry with backoff.
    case retry
    /// 401: the key is wrong; stop sending for this process (the queue is kept for a fixed build).
    case invalidKey
    /// 403: remote kill switch.
    case disabled
    /// Other 4xx or an unusable 2xx body: the event can never succeed; drop it.
    case drop

    init(_ error: ProoflineError) {
        switch error {
        case .network: self = .retry
        case .invalidAppKey: self = .invalidKey
        case .disabled: self = .disabled
        case let .api(status, _, _):
            self = (status >= 500 || status == 408 || status == 425 || status == 429) ? .retry : .drop
        case .invalidResponse, .invalidInput, .notConfigured: self = .drop
        }
    }
}
