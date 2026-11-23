import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ScanError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class Scanner: ObservableObject {
    @Published var dpi = 300
    @Published var mode = "Color"
    @Published var format = "PDF"
    @Published var busy = false
    @Published var status = "Checking USB connection…"
    @Published var device: String?
    @Published var preview: NSImage?
    @Published var unsaved = false
    @Published private(set) var whitening = max(0, min(100,
        (UserDefaults.standard.object(forKey: "paperWhiteningPercent") as? NSNumber)?.doubleValue ?? 50))
    private var originalThumbnail: CGImage?

    func setWhitening(_ value: Double) {
        let amount = max(0, min(100, value))
        guard whitening != amount else { return }
        do {
            if let originalThumbnail {
                let adjusted = try PaperWhitening.apply(to: originalThumbnail, percent: amount)
                preview = NSImage(cgImage: adjusted, size: .zero)
                unsaved = true
                status = "Paper whitening adjusted. Save to apply."
            }
            whitening = amount
            UserDefaults.standard.set(amount, forKey: "paperWhiteningPercent")
        } catch { status = error.localizedDescription }
    }

    @Published var paper: Paper = .a4 { didSet { applyPaper() } }
    @Published var outline: PageOutline = .full
    private var detected: PageOutline?
    private var rasterSize = CGSize.zero
    private var outputSize: CGSize {
        if let mm = paper.mm {
            return CGSize(width: (mm.width * Double(pageDPI) / 25.4).rounded(),
                          height: (mm.height * Double(pageDPI) / 25.4).rounded())
        }
        return outline.pixels(in: rasterSize)
    }
    var dimensions: String {
        let mm = paper.mm ?? CGSize(width: outputSize.width * 25.4 / Double(pageDPI),
                                     height: outputSize.height * 25.4 / Double(pageDPI))
        return String(format: "%.1f × %.1f mm", mm.width, mm.height)
    }
    func applyPaper() {
        guard rasterSize.width > 0 else { return }
        if paper.mm != nil {
            if let detected,
               abs(detected.pixels(in: rasterSize).width/outputSize.width - 1) < 0.045,
               abs(detected.pixels(in: rasterSize).height/outputSize.height - 1) < 0.045 {
                outline = detected
                status = "Page edges aligned. Drag a corner to refine the crop."
            } else {
                outline = .rectangle(min(1,outputSize.width/rasterSize.width), min(1,outputSize.height/rasterSize.height))
                status = "Paper aligned to the flatbed origin. Drag the corners to adjust."
            }
        } else if paper == .auto, let detected {
            outline = detected
            status = "Review the detected page edges before saving."
        } else {
            outline = .full
            status = paper == .auto ? "No clear page boundary. Drag the corners to fit the paper." : "Full flatbed selected."
        }
        unsaved = true
    }
    private var page: Data?
    private var pageDPI = 300
    private var process: Process?
    private var cancelled = false

    func cancel() {
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    private func run(_ arguments: [String], in folder: URL) async throws -> String {
        let process = Process()
        let resources = Bundle.main.resourceURL!
        process.executableURL = resources.appendingPathComponent("scanimage")
        process.arguments = arguments
        process.environment = ["SANE_CONFIG_DIR": resources.appendingPathComponent("Config").path,
                               "LC_ALL": "C", "TMPDIR": folder.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        let log = folder.appendingPathComponent("diagnostic.txt")
        try Data().write(to: log)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        process.standardError = errors
        self.process = process
        defer { self.process = nil }
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        if cancelled { throw CancellationError() }
        guard code == 0 else {
            let report = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw ScanError(message: report.split(separator: "\n").last.map(String.init) ?? "The scanner stopped. Check the USB cable and try again.")
        }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func perform(scan: Bool) async {
        guard !busy else { return }
        busy = true
        cancelled = false
        defer { busy = false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            status = "Checking USB connection…"
            let devices = try await run(["-f", "%d%n"], in: folder)
            device = devices.split(separator: "\n").map(String.init).first {
                $0.uppercased().hasPrefix("PIXMA:04A9183B")
            }
            guard let device else {
                throw ScanError(message: "Connect the G3010 by USB, turn it on, then click Refresh.")
            }
            guard scan else { status = "Connected over USB"; return }
            status = "Scanning at \(dpi) dpi…"
            let file = folder.appendingPathComponent("page.tiff")
            try await scanPage(device: device, file: file, folder: folder)
        } catch is CancellationError {
            status = "Cancelled."
        } catch {
            status = error.localizedDescription
        }
    }

    private func scanPage(device: String, file: URL, folder: URL) async throws {
        _ = try await run(["-d", device, "--source", "Flatbed", "--mode", mode, "--resolution",
                           String(dpi), "--format=tiff", "-o", file.path], in: folder)
        let bytes = try Data(contentsOf: file)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200
              ] as CFDictionary) else {
            throw ScanError(message: "The scanner returned an incomplete page. Please try again.")
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ScanError(message: "Could not read the scan dimensions.")
        }
        status = "Finding page edges…"
        let candidate = await Task.detached(priority: .userInitiated) { detectPage(thumb) }.value
        if cancelled { throw CancellationError() }
        let adjusted = try PaperWhitening.apply(to: thumb, percent: whitening)
        originalThumbnail = thumb
        detected = candidate
        page = bytes
        pageDPI = dpi
        rasterSize = CGSize(width: width,height: height)
        preview = NSImage(cgImage: adjusted, size: .zero)
        applyPaper()
    }

    func save() {
        guard let page else { return }
        let panel = NSSavePanel()
        let type: UTType = format == "PDF" ? .pdf : format == "JPEG" ? .jpeg : .png
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "Scan " + Date.now.formatted(.iso8601.year().month().day()) + "." + (type.preferredFilenameExtension ?? "pdf")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try exportPage(page, dpi: pageDPI, type: type, outline: outline, size: outputSize, paperMM: paper.mm, whitening: whitening).write(to: destination, options: .atomic)
            unsaved = false
            status = "Saved \(destination.lastPathComponent)"
        } catch { status = error.localizedDescription }
    }
}

func exportPage(_ data: Data, dpi: Int, type: UTType, outline: PageOutline, size: CGSize, paperMM: CGSize?, whitening: Double = 0) throws -> Data {
    let failure = ScanError(message: "Could not convert the scanned page.")
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw failure }
    let cropped = try croppedPage(original, outline: outline, size: size)
    let image = try PaperWhitening.apply(to: cropped, percent: whitening)
    let result = NSMutableData()
    if type == .pdf {
        var bounds = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / Double(dpi),
                            height: Double(image.height) * 72 / Double(dpi))
        if let mm = paperMM {
            bounds.size = CGSize(width: mm.width * 72 / 25.4, height: mm.height * 72 / 25.4)
        }
        guard let consumer = CGDataConsumer(data: result),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw failure }
        context.beginPDFPage(nil)
        context.draw(image, in: bounds)
        context.endPDFPage()
        context.closePDF()
    } else {
        guard let target = CGImageDestinationCreateWithData(result, type.identifier as CFString, 1, nil) else { throw failure }
        CGImageDestinationAddImage(target, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                                   kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw failure }
    }
    return result as Data
}

struct ScannerView: View {
    @StateObject private var scanner = Scanner()
    @State private var confirmReplace = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Canon G3010", systemImage: "scanner").font(.title2.bold())
                HStack {
                    Label(scanner.device == nil ? "USB scanner" : "USB connected", systemImage: "cable.connector")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await scanner.perform(scan: false) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.accessibilityLabel("Refresh").help("Refresh USB connection").disabled(scanner.busy)
                }
                Divider()
                Picker("Resolution", selection: $scanner.dpi) {
                    ForEach([150, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                }.disabled(scanner.busy)
                Picker("Mode", selection: $scanner.mode) {
                    Text("Color").tag("Color")
                    Text("Grayscale").tag("Gray")
                }.disabled(scanner.busy)
                if scanner.busy {
                    Button("Cancel") { scanner.cancel() }
                } else {
                    Button("Scan page") {
                        if scanner.unsaved { confirmReplace = true } else { scan() }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.return)
                }
                Divider()
                Picker("Paper size", selection: $scanner.paper) {
                    ForEach(Paper.allCases, id: \.self) { Text($0.rawValue) }
                }.disabled(scanner.busy)
                if scanner.preview != nil {
                    Text(scanner.dimensions).font(.callout.monospacedDigit())
                    Button("Reset corners") { scanner.applyPaper() }
                        .disabled(scanner.busy)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Paper whitening")
                        Spacer()
                        Text(scanner.whitening / 100, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: Binding(get: { scanner.whitening }, set: scanner.setWhitening),
                           in: 0...100, step: 5) { Text("Paper whitening") }
                        .labelsHidden().accessibilityLabel("Paper whitening")
                        .accessibilityValue("\(Int(scanner.whitening)) percent")
                        .help("Brighten light, nearly neutral paper. Set to 0% for the original scan.")
                }.disabled(scanner.busy)
                Picker("Save as", selection: $scanner.format) {
                    ForEach(["PDF", "PNG", "JPEG"], id: \.self) { Text($0) }
                }
                Button("Save…") { scanner.save() }.keyboardShortcut("s")
                    .disabled(scanner.preview == nil || scanner.busy)
                Spacer()
                Text(scanner.status).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.padding(22).frame(width: 250)
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = scanner.preview {
                    PageEditor(image: image, outline: Binding(get: { scanner.outline }, set: {
                        scanner.outline = $0
                        scanner.unsaved = true
                        scanner.status = "Crop adjusted. Save to apply."
                    })).disabled(scanner.busy)
                } else {
                    ContentUnavailableView("Page preview", systemImage: "doc.viewfinder",
                        description: Text("Place a page face down on the flatbed."))
                }
                if scanner.busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
            }.frame(minWidth: 330, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        }.task { await scanner.perform(scan: false) }
        .alert("Replace the unsaved scan?", isPresented: $confirmReplace) {
            Button("Cancel", role: .cancel) {}
            Button("Scan new page", role: .destructive) { scan() }
        }
    }
    private func scan() { Task { await scanner.perform(scan: true) } }
}

@main
struct G3010App: App {
    var body: some Scene {
        Window("G3010 USB Scan", id: "scanner") { ScannerView() }
            .defaultSize(width: 780, height: 600)
    }
}
