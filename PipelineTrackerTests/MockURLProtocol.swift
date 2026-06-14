import Foundation

/// URLProtocol subclass that intercepts URLSession requests in unit tests.
/// Register via URLSessionConfiguration.protocolClasses before creating the session.
final class MockURLProtocol: URLProtocol {
    /// Set before each test to return a canned (response, data) or throw an error.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Convenience: build a URLSession wired to MockURLProtocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Convenience: stub a JSON response.
    static func stub(statusCode: Int = 200, json: String, for url: URL? = nil) {
        requestHandler = { request in
            if let url, request.url != url {
                throw URLError(.badURL)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode,
                httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
    }
}
