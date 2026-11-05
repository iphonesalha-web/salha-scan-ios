import Foundation
import WebKit

/// يقدّم ملفات التطبيق المضمّنة من مجلد `web` عبر العنوان app://localhost/
/// حتى تعمل IndexedDB وWeb Workers وملفات wasm كما في المتصفح.
final class LocalScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "app"
    static let startURL = URL(string: "app://localhost/index.html")!

    private let root: URL = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)

    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "js": "application/javascript; charset=utf-8", "mjs": "application/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "webmanifest": "application/manifest+json",
        "wasm": "application/wasm", "gz": "application/gzip",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "svg": "image/svg+xml",
        "webp": "image/webp", "ico": "image/x-icon",
        "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf",
        "traineddata": "application/octet-stream", "txt": "text/plain; charset=utf-8"
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL

        guard file.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain", "Content-Length": "0"])!
            task.didReceive(resp)
            task.didFinish()
            return
        }

        let type = Self.mime[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache"
        ])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
