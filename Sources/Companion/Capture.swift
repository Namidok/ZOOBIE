import AppKit
import ApplicationServices
import AVFoundation
import CompanionCore
import ScreenCaptureKit
import Speech
import Vision

enum CaptureError: LocalizedError {
    case noPermission, noDisplay

    var errorDescription: String? {
        switch self {
        case .noPermission: return "Screen Recording permission is needed to read your screen. Grant it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch ZOOBIE."
        case .noDisplay: return "Couldn't find the display under the cursor."
        }
    }
}

/// A screen capture held in memory only; it is never written to disk.
struct Snapshot {
    var context: ScreenContext
    var image: CGImage
    /// The captured display in AppKit global coordinates.
    var screenFrame: CGRect
    /// Downscaled JPEG sent to Claude; its pixel size is the coordinate space for [POINT:x,y] and clicks.
    var jpeg: (base64: String, size: CGSize)?

    var capture: ScreenCapture {
        ScreenCapture(promptBlock: context.promptBlock(), jpegBase64: jpeg?.base64, imageSize: jpeg?.size)
    }

    /// Maps a pixel coordinate in the sent screenshot to AppKit global coordinates.
    func screenPoint(fromImage point: CGPoint) -> CGPoint? {
        guard let size = jpeg?.size, size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: screenFrame.minX + point.x / size.width * screenFrame.width,
                       y: screenFrame.maxY - point.y / size.height * screenFrame.height)
    }
}

enum ScreenReader {
    /// The frontmost app and its focused window title (the title needs Accessibility).
    @MainActor
    static func focusInfo() -> (appName: String?, windowTitle: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        var title: String?
        if let pid = app?.processIdentifier, AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(pid)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success {
                    title = value as? String
                }
            }
        }
        return (app?.localizedName, title)
    }

    /// Captures a display at native resolution, excluding Companion's own windows.
    /// Takes plain values (not NSScreen) because it runs off the main thread.
    static func capture(displayID: CGDirectDisplayID?, pixelScale: CGFloat) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            await Permissions.requestScreenRecordingOnce()
            throw CaptureError.noPermission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ownPID }, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * pixelScale)
        config.height = Int(CGFloat(display.height) * pixelScale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// On-device OCR. Frames are mapped into AppKit global coordinates of `screenFrame`.
    static func recognizeText(in image: CGImage, screenFrame: CGRect) async throws -> [TextElement] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false // code and paths must stay verbatim
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let raw: [(text: String, frame: CGRect)] = (request.results ?? []).compactMap { observation in
                        guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
                        let box = observation.boundingBox // normalized, bottom-left origin — same as AppKit
                        return (text, CGRect(
                            x: screenFrame.minX + box.minX * screenFrame.width,
                            y: screenFrame.minY + box.minY * screenFrame.height,
                            width: box.width * screenFrame.width,
                            height: box.height * screenFrame.height
                        ))
                    }
                    continuation.resume(returning: ScreenContext.orderedElements(raw))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Downscaled JPEG for a vision model; small enough to keep uploads and prompt processing fast.
    /// 1280 px wide matches the resolution vision models locate UI elements most accurately at.
    static func jpeg(_ image: CGImage, maxDimension: CGFloat = 1280) -> (base64: String, size: CGSize)? {
        let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        guard let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return nil }
        return (data.base64EncodedString(), CGSize(width: width, height: height))
    }
}

enum Permissions {
    enum Kind: String, CaseIterable {
        case accessibility = "Accessibility"
        case screenRecording = "Screen Recording"
        case microphone = "Microphone"
        case speech = "Speech Recognition"

        var isGranted: Bool {
            switch self {
            case .accessibility: return AXIsProcessTrusted()
            case .screenRecording: return CGPreflightScreenCaptureAccess()
            case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .speech: return SFSpeechRecognizer.authorizationStatus() == .authorized
            }
        }

        var purpose: String {
            switch self {
            case .accessibility: return "hold-⌃⌥ push-to-talk, window titles"
            case .screenRecording: return "reading your screen"
            case .microphone: return "voice questions"
            case .speech: return "on-device transcription"
            }
        }

        var tccService: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "ScreenCapture"
            case .microphone: return "Microphone"
            case .speech: return "SpeechRecognition"
            }
        }

        var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .screenRecording: anchor = "Privacy_ScreenCapture"
            case .microphone: anchor = "Privacy_Microphone"
            case .speech: anchor = "Privacy_SpeechRecognition"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @MainActor private static var askedForScreenRecording = false

    /// macOS's Screen Recording prompt, shown at most once per run (it used to fire on every screen read).
    @MainActor static func requestScreenRecordingOnce() {
        guard !askedForScreenRecording else { return }
        askedForScreenRecording = true
        CGRequestScreenCaptureAccess()
    }

    /// Clears a permission macOS is holding for an older build of ZOOBIE. An entry can show as switched on in
    /// System Settings yet not apply, because it belongs to a previous code signature; after a reset the next
    /// grant binds to the current, stable signature and survives rebuilds.
    static func reset(_ kind: Kind) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", kind.tccService, Bundle.main.bundleIdentifier ?? "local.companion.agent"]
        try? process.run()
        process.waitUntilExit()
    }
}
