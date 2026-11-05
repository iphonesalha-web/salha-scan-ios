import UIKit
import WebKit
import VisionKit
import Vision

/// الجسر بين صفحة الويب والأدوات الأصلية: الماسح، التعرف على النص، المشاركة.
/// تستدعيه الصفحة بـ: await window.webkit.messageHandlers.native.postMessage({cmd: ...})
final class NativeBridge: NSObject, WKScriptMessageHandlerWithReply {
    private weak var host: WebViewController?
    private let scanner = Scanner()

    init(host: WebViewController) { self.host = host }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        let reply: (Any?) -> Void = { value in DispatchQueue.main.async { replyHandler(value, nil) } }

        switch cmd {
        case "info":
            reply(["scanner": VNDocumentCameraViewController.isSupported,
                   "ocrLangs": OCR.supportedLanguages()])

        case "scan":
            guard let host = host, VNDocumentCameraViewController.isSupported else {
                reply(["unsupported": true]); return
            }
            scanner.start(from: host) { pages in reply(["pages": pages]) }

        case "ocr":
            guard let b64 = body["image"] as? String,
                  let data = Data(base64Encoded: b64),
                  let image = UIImage(data: data)?.cgImage else {
                reply(["error": "bad image"]); return
            }
            let langs = (body["langs"] as? String) ?? "deu+ara+eng"
            DispatchQueue.global(qos: .userInitiated).async {
                reply(OCR.recognize(image, langs: langs))
            }

        case "share":
            let files = (body["files"] as? [[String: Any]]) ?? []
            let text = body["text"] as? String
            share(files: files, text: text, reply: reply)

        case "haptic":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            reply(true)

        default:
            replyHandler(nil, "unknown command")
        }
    }

    private func share(files: [[String: Any]], text: String?, reply: @escaping (Any?) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var items: [Any] = []
        for f in files {
            guard let b64 = f["b64"] as? String, let data = Data(base64Encoded: b64) else { continue }
            var name = (f["name"] as? String) ?? "file"
            name = name.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent(name)
            if (try? data.write(to: url)) != nil { items.append(url) }
        }
        if let t = text, !t.isEmpty { items.append(t) }
        guard !items.isEmpty, let host = host else { reply(["completed": false]); return }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in
            reply(["completed": completed])
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        DispatchQueue.main.async { host.present(vc) }
    }
}

// MARK: - ماسح المستندات من آبل

final class Scanner: NSObject, VNDocumentCameraViewControllerDelegate {
    private var done: (([String]) -> Void)?
    private let maxSide: CGFloat = 2600

    func start(from host: UIViewController, done: @escaping ([String]) -> Void) {
        DispatchQueue.main.async {
            self.done = done
            let cam = VNDocumentCameraViewController()
            cam.delegate = self
            if let web = host as? WebViewController { web.present(cam) } else { host.present(cam, animated: true) }
        }
    }

    private func finish(_ pages: [String]) {
        let d = done
        done = nil
        d?(pages)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                      didFinishWith scan: VNDocumentCameraScan) {
        let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
        controller.dismiss(animated: true)
        let maxSide = self.maxSide
        DispatchQueue.global(qos: .userInitiated).async {
            let out = images.compactMap { img -> String? in
                Scanner.downscale(img, maxSide: maxSide).jpegData(compressionQuality: 0.9)?.base64EncodedString()
            }
            DispatchQueue.main.async { self.finish(out) }
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
        finish([])
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true)
        finish([])
    }

    static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        let k = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - التعرف على النص من آبل

enum OCR {
    private static let map: [String: String] = ["deu": "de-DE", "ara": "ar-SA", "eng": "en-US"]

    private static func makeRequest() -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        if #available(iOS 16.0, *) { req.revision = VNRecognizeTextRequestRevision3 }
        return req
    }

    static func supportedLanguages() -> [String] {
        (try? makeRequest().supportedRecognitionLanguages()) ?? []
    }

    static func recognize(_ image: CGImage, langs: String) -> [String: Any] {
        let supported = supportedLanguages()
        let wanted = langs.split(separator: "+").compactMap { map[String($0)] }
        let usable = wanted.filter { w in supported.contains { $0.lowercased() == w.lowercased() } }
        if usable.isEmpty { return ["unsupported": true] }

        let W = CGFloat(image.width), H = CGFloat(image.height)

        func run(_ languages: [String]) -> [VNRecognizedTextObservation]? {
            let req = makeRequest()
            req.recognitionLanguages = languages
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
                return req.results ?? []
            } catch { return nil }
        }

        var observations = run(usable)
        if observations == nil, usable.count > 1 {
            // بعض اللغات لا تعمل معاً؛ نقرأ كل لغة وحدها ونأخذ الأفضل
            observations = usable.compactMap { run([$0]) }.max { a, b in
                a.reduce(0) { $0 + ($1.topCandidates(1).first?.string.count ?? 0) } <
                b.reduce(0) { $0 + ($1.topCandidates(1).first?.string.count ?? 0) }
            }
        }
        guard let obs = observations else { return ["error": "recognition failed"] }

        func box(_ r: CGRect) -> [String: Int] {
            ["x0": Int((r.minX * W).rounded(.down)), "y0": Int(((1 - r.maxY) * H).rounded(.down)),
             "x1": Int((r.maxX * W).rounded(.up)), "y1": Int(((1 - r.minY) * H).rounded(.up))]
        }

        var lines: [[String: Any]] = []
        for o in obs {
            guard let cand = o.topCandidates(1).first else { continue }
            let text = cand.string
            let conf = cand.confidence >= 0.3 ? 90.0 : Double(cand.confidence) * 100
            var words: [[String: Any]] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { sub, range, _, _ in
                guard let sub = sub, !sub.isEmpty else { return }
                let r = (try? cand.boundingBox(for: range))?.boundingBox ?? o.boundingBox
                var w: [String: Any] = ["text": sub, "conf": conf]
                box(r).forEach { w[$0.key] = $0.value }
                words.append(w)
            }
            var line: [String: Any] = ["text": text, "conf": conf, "words": words]
            box(o.boundingBox).forEach { line[$0.key] = $0.value }
            lines.append(line)
        }
        let text = lines.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return ["text": text, "lines": lines]
    }
}
