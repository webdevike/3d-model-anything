import CoreImage
import CoreVideo
import Foundation
import ImageIO
import RealityKit

// object-reconstruct: builds a full-detail model from an Eva object capture
// (guided Object Capture photos or a turntable scan with object masks).
//
//   object-reconstruct <zip-or-folder> [--detail full|medium|reduced|raw] [--no-masks]
//
// Writes data/objects/<id>/model-full.usdz and data/web-assets/objects/<id>/
// (OBJ export + manifest.json), and upserts data/web-assets/objects/index.json.

setvbuf(stdout, nil, _IOLBF, 0)

var tempDirectory: URL?

func cleanUp() {
    if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    cleanUp()
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

// MARK: - Arguments

let usage = "usage: npm run object -- <zip-or-folder> [--detail full|medium|reduced|raw] [--no-masks]"

var inputArgument: String?
var detail: PhotogrammetrySession.Request.Detail = .full
var detailName = "full"
var useMasks = true

var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
    switch arg {
    case "--detail":
        guard let value = argIterator.next() else { fail("--detail needs a value\n\(usage)") }
        switch value {
        case "full": detail = .full
        case "medium": detail = .medium
        case "reduced": detail = .reduced
        case "raw": detail = .raw
        default: fail("unknown detail '\(value)' (full|medium|reduced|raw)")
        }
        detailName = value
    case "--no-masks":
        useMasks = false
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if arg.hasPrefix("--") { fail("unknown option \(arg)\n\(usage)") }
        if inputArgument != nil { fail("only one input path is allowed\n\(usage)") }
        inputArgument = arg
    }
}

guard let inputArgument else { fail(usage) }

// `npm run` changes cwd to the repo root; INIT_CWD is where the user ran it.
let fileManager = FileManager.default
let invocationDirectory = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["INIT_CWD"] ?? fileManager.currentDirectoryPath,
    isDirectory: true
)
let inputURL = URL(fileURLWithPath: (inputArgument as NSString).expandingTildeInPath, relativeTo: invocationDirectory)
    .standardizedFileURL

// MARK: - Repo root

func findRepoRoot() -> URL {
    func isRepoRoot(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("package.json").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("tools/object-reconstruct/Package.swift").path)
    }
    var candidate = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true).standardizedFileURL
    while true {
        if isRepoRoot(candidate) { return candidate }
        let parent = candidate.deletingLastPathComponent()
        if parent.path == candidate.path { break }
        candidate = parent
    }
    // Sources/object-reconstruct/main.swift -> tools/object-reconstruct -> repo root.
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fromPackage = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
    if isRepoRoot(fromPackage) { return fromPackage }
    fail("could not locate the repo root (run from the repo, e.g. `npm run object -- <path>`)")
}

let repoRoot = findRepoRoot()

// MARK: - Input

var isDirectory: ObjCBool = false
guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
    fail("input not found: \(inputURL.path)")
}

func makeTempDirectory() -> URL {
    let url = fileManager.temporaryDirectory.appendingPathComponent("object-reconstruct-\(UUID().uuidString)", isDirectory: true)
    do {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        fail("could not create temp directory: \(error.localizedDescription)")
    }
    tempDirectory = url
    return url
}

var searchRoot = inputURL
if !isDirectory.boolValue {
    guard inputURL.pathExtension.lowercased() == "zip" else {
        fail("input must be a capture folder or a .zip: \(inputURL.path)")
    }
    let unzipDirectory = makeTempDirectory().appendingPathComponent("unzipped", isDirectory: true)
    print("Unzipping \(inputURL.lastPathComponent)…")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-x", "-k", inputURL.path, unzipDirectory.path]
    do {
        try ditto.run()
    } catch {
        fail("could not run ditto: \(error.localizedDescription)")
    }
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else { fail("ditto failed to unzip \(inputURL.path) (status \(ditto.terminationStatus))") }
    searchRoot = unzipDirectory
}

/// Shallowest directory under `root` (inclusive) containing object.json, skipping __MACOSX.
func findObjectFolder(in root: URL) -> URL? {
    var queue = [root]
    while !queue.isEmpty {
        let directory = queue.removeFirst()
        if fileManager.fileExists(atPath: directory.appendingPathComponent("object.json").path) { return directory }
        let children = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where child.lastPathComponent != "__MACOSX"
            && (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            queue.append(child)
        }
    }
    return nil
}

guard let objectFolder = findObjectFolder(in: searchRoot) else {
    fail("no object.json found in \(inputURL.path)")
}

struct ObjectInfo: Decodable {
    var id: String
    var name: String?
    var createdAt: String?
    var kind: String?
    var sheetSizeMM: Double?
}

let info: ObjectInfo
do {
    info = try JSONDecoder().decode(ObjectInfo.self, from: Data(contentsOf: objectFolder.appendingPathComponent("object.json")))
} catch {
    fail("could not read object.json: \(error.localizedDescription)")
}

let objectID = info.id
guard !objectID.isEmpty, objectID != ".", objectID != "..",
      objectID.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:")) == nil else {
    fail("object.json has an unusable id '\(objectID)'")
}
let objectName = info.name?.isEmpty == false ? info.name! : objectID
let kind = info.kind ?? "guided"

guard PhotogrammetrySession.isSupported else {
    fail("PhotogrammetrySession is not supported on this Mac (needs Apple silicon or a supported GPU)")
}

// MARK: - Turntable samples

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

func makePixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
    return status == kCVReturnSuccess ? buffer : nil
}

/// Full-res JPEG in its stored (sensor) orientation as BGRA.
func loadImageBuffer(_ url: URL) -> CVPixelBuffer? {
    guard let image = CIImage(contentsOf: url) else { return nil }
    let extent = image.extent.integral
    guard let buffer = makePixelBuffer(width: Int(extent.width), height: Int(extent.height), format: kCVPixelFormatType_32BGRA) else {
        return nil
    }
    ciContext.render(image, to: buffer, bounds: extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return buffer
}

/// 8-bit gray mask scaled to the image size (contract: same size already).
func loadMaskBuffer(_ url: URL, width: Int, height: Int) -> CVPixelBuffer? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let buffer = makePixelBuffer(width: width, height: height, format: kCVPixelFormatType_OneComponent8) else {
        return nil
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}

/// EXIF/TIFF metadata (focal length etc.) minus orientation: pixels and masks are in sensor orientation.
func loadMetadata(_ url: URL) -> [String: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }
    properties.removeValue(forKey: kCGImagePropertyOrientation as String)
    if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    return properties
}

struct TurntableFrame {
    var index: Int
    var image: URL
    var mask: URL?
}

/// Loads frames lazily so only a few full-res buffers are alive at once.
struct TurntableSamples: Sequence {
    let frames: [TurntableFrame]

    func makeIterator() -> AnyIterator<PhotogrammetrySample> {
        var remaining = frames.makeIterator()
        return AnyIterator {
            while let frame = remaining.next() {
                let sample: PhotogrammetrySample? = autoreleasepool {
                    guard let image = loadImageBuffer(frame.image) else {
                        warn("skipping \(frame.image.lastPathComponent): could not decode image")
                        return nil
                    }
                    var sample = PhotogrammetrySample(id: frame.index, image: image)
                    sample.metadata = loadMetadata(frame.image)
                    if let maskURL = frame.mask {
                        if let mask = loadMaskBuffer(
                            maskURL, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)
                        ) {
                            sample.objectMask = mask
                        } else {
                            warn("\(maskURL.lastPathComponent): could not decode mask, using none")
                        }
                    }
                    return sample
                }
                if let sample { return sample }
            }
            return nil
        }
    }
}

func turntableFrames(in directory: URL) -> [TurntableFrame] {
    let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    var frames: [TurntableFrame] = []
    var missingMasks = 0
    for file in files where file.pathExtension.lowercased() == "jpg" {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let index = Int(stem) else { continue }
        var mask: URL?
        if useMasks {
            let maskURL = directory.appendingPathComponent("\(stem)-mask.png")
            if fileManager.fileExists(atPath: maskURL.path) { mask = maskURL } else { missingMasks += 1 }
        }
        frames.append(TurntableFrame(index: index, image: file, mask: mask))
    }
    if missingMasks > 0 { warn("\(missingMasks) frame(s) have no mask") }
    return frames.sorted { $0.index < $1.index }
}

// MARK: - Session

let objectsDirectory = repoRoot.appendingPathComponent("data/objects/\(objectID)", isDirectory: true)
let webObjectsDirectory = repoRoot.appendingPathComponent("data/web-assets/objects", isDirectory: true)
let webDirectory = webObjectsDirectory.appendingPathComponent(objectID, isDirectory: true)
let modelDirectory = webDirectory.appendingPathComponent("model", isDirectory: true)
let usdzURL = objectsDirectory.appendingPathComponent("model-full.usdz")

let session: PhotogrammetrySession
let photoCount: Int
print("Object \(objectName) (\(objectID)), kind \(kind), detail \(detailName)")

switch kind {
case "guided":
    let imagesDirectory = objectFolder.appendingPathComponent("Images", isDirectory: true)
    let images = ((try? fileManager.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? [])
        .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
    guard !images.isEmpty else { fail("no photos in \(imagesDirectory.path)") }
    photoCount = images.count
    var configuration = PhotogrammetrySession.Configuration()
    // Reuse the phone's checkpoint (copied so the capture folder is never modified).
    let checkpoint = objectFolder.appendingPathComponent("Checkpoint", isDirectory: true)
    if let contents = try? fileManager.contentsOfDirectory(atPath: checkpoint.path), !contents.isEmpty {
        let copy = (tempDirectory ?? makeTempDirectory()).appendingPathComponent("Checkpoint", isDirectory: true)
        do {
            try fileManager.copyItem(at: checkpoint, to: copy)
            configuration.checkpointDirectory = copy
        } catch {
            warn("ignoring checkpoint: \(error.localizedDescription)")
        }
    }
    print("\(photoCount) photos from Images/")
    do {
        session = try PhotogrammetrySession(input: imagesDirectory, configuration: configuration)
    } catch {
        fail("could not start PhotogrammetrySession: \(error.localizedDescription)")
    }
case "turntable":
    let turntableDirectory = objectFolder.appendingPathComponent("Turntable", isDirectory: true)
    let frames = turntableFrames(in: turntableDirectory)
    guard !frames.isEmpty else { fail("no NNNN.jpg frames in \(turntableDirectory.path)") }
    photoCount = frames.count
    var configuration = PhotogrammetrySession.Configuration()
    configuration.isObjectMaskingEnabled = true
    configuration.featureSensitivity = .high
    configuration.sampleOrdering = .unordered
    print("\(photoCount) frames from Turntable/, masks \(useMasks ? "on" : "off")")
    do {
        session = try PhotogrammetrySession(input: TurntableSamples(frames: frames), configuration: configuration)
    } catch {
        fail("could not start PhotogrammetrySession: \(error.localizedDescription)")
    }
default:
    fail("unknown object kind '\(kind)' (guided|turntable)")
}

let usdzRequest = PhotogrammetrySession.Request.modelFile(url: usdzURL, detail: detail)
let objRequest = PhotogrammetrySession.Request.modelFile(url: modelDirectory, detail: detail)

func label(_ request: PhotogrammetrySession.Request) -> String {
    request == usdzRequest ? "usdz" : request == objRequest ? "obj" : "request"
}

func stageName(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> String {
    switch stage {
    case .preProcessing: return "pre-processing"
    case .imageAlignment: return "aligning images"
    case .pointCloudGeneration: return "point cloud"
    case .meshGeneration: return "mesh"
    case .textureMapping: return "textures"
    case .optimization: return "optimizing"
    @unknown default: return "processing"
    }
}

do {
    try fileManager.createDirectory(at: objectsDirectory, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: modelDirectory.path) { try fileManager.removeItem(at: modelDirectory) }
    try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: usdzURL.path) { try fileManager.removeItem(at: usdzURL) }
} catch {
    fail("could not prepare output directories: \(error.localizedDescription)")
}

do {
    try session.process(requests: [usdzRequest, objRequest])
} catch {
    fail("PhotogrammetrySession could not process: \(error.localizedDescription)")
}

var lastPercent: [String: Int] = [:]
var lastStage: [String: String] = [:]
var completed: Set<String> = []
var errors: [String] = []
var invalidSamples = 0
var skippedSamples = 0

outputLoop: for try await output in session.outputs {
    switch output {
    case .requestProgress(let request, let fraction):
        let name = label(request)
        let percent = Int((fraction * 100).rounded(.down))
        if lastPercent[name] != percent {
            lastPercent[name] = percent
            print("[\(name)] \(percent)%")
        }
    case .requestProgressInfo(let request, let progress):
        let name = label(request)
        if let stage = progress.processingStage.map(stageName), lastStage[name] != stage {
            lastStage[name] = stage
            let remaining = progress.estimatedRemainingTime.map { String(format: " (~%.0fs left)", $0) } ?? ""
            print("[\(name)] \(stage)\(remaining)")
        }
    case .requestComplete(let request, _):
        completed.insert(label(request))
        print("[\(label(request))] done")
    case .requestError(let request, let error):
        errors.append("\(label(request)): \(error.localizedDescription)")
        FileHandle.standardError.write(Data("error: [\(label(request))] \(error)\n".utf8))
    case .inputComplete:
        print("Input loaded.")
    case .invalidSample(let id, let reason):
        invalidSamples += 1
        warn("sample \(id) invalid: \(reason)")
    case .skippedSample(let id):
        skippedSamples += 1
        warn("sample \(id) skipped")
    case .automaticDownsampling:
        warn("images were automatically downsampled (not enough memory for full resolution)")
    case .stitchingIncomplete:
        warn("not all photos could be stitched into one model; add overlapping shots")
    case .processingCancelled:
        fail("processing was cancelled")
    case .processingComplete:
        break outputLoop
    @unknown default:
        break
    }
}

if !errors.isEmpty {
    fail("PhotogrammetrySession failed:\n  " + errors.joined(separator: "\n  "))
}
guard completed.contains("usdz"), completed.contains("obj") else {
    fail("PhotogrammetrySession finished without producing both models")
}
if invalidSamples + skippedSamples > 0 {
    print("\(invalidSamples) invalid, \(skippedSamples) skipped of \(photoCount) photos")
}

// MARK: - Web assets

func relativePath(of url: URL, to base: URL) -> String {
    let path = url.standardizedFileURL.path
    let basePath = base.standardizedFileURL.path + "/"
    return path.hasPrefix(basePath) ? String(path.dropFirst(basePath.count)) : url.lastPathComponent
}

func firstFile(withExtension ext: String, in directory: URL) -> URL? {
    let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil)
    var matches: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
        if url.pathExtension.lowercased() == ext { matches.append(url) }
    }
    return matches.min { $0.path.count == $1.path.count ? $0.path < $1.path : $0.path.count < $1.path.count }
}

guard let objURL = firstFile(withExtension: "obj", in: modelDirectory) else {
    fail("no .obj was written to \(modelDirectory.path)")
}
let mtlURL = firstFile(withExtension: "mtl", in: modelDirectory)

let webUSDZ = webDirectory.appendingPathComponent("model.usdz")
var usdzRelative: String?
do {
    if fileManager.fileExists(atPath: webUSDZ.path) { try fileManager.removeItem(at: webUSDZ) }
    try fileManager.copyItem(at: usdzURL, to: webUSDZ)
    usdzRelative = "model.usdz"
} catch {
    warn("could not copy usdz into web assets: \(error.localizedDescription)")
}

let builtAt = ISO8601DateFormatter().string(from: Date())

struct Manifest: Codable {
    var id: String
    var name: String
    var obj: String
    var mtl: String?
    var usdz: String?
    var photos: Int
    var builtAt: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(obj, forKey: .obj)
        try container.encode(mtl, forKey: .mtl) // explicit null when absent
        try container.encode(usdz, forKey: .usdz)
        try container.encode(photos, forKey: .photos)
        try container.encode(builtAt, forKey: .builtAt)
    }
}

struct IndexEntry: Codable {
    var id: String
    var name: String
    var builtAt: String
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

let manifest = Manifest(
    id: objectID,
    name: objectName,
    obj: relativePath(of: objURL, to: webDirectory),
    mtl: mtlURL.map { relativePath(of: $0, to: webDirectory) },
    usdz: usdzRelative,
    photos: photoCount,
    builtAt: builtAt
)

let indexURL = webObjectsDirectory.appendingPathComponent("index.json")
var index = (try? JSONDecoder().decode([IndexEntry].self, from: Data(contentsOf: indexURL))) ?? []
index.removeAll { $0.id == objectID }
index.append(IndexEntry(id: objectID, name: objectName, builtAt: builtAt))
index.sort { $0.builtAt > $1.builtAt }

do {
    try encoder.encode(manifest).write(to: webDirectory.appendingPathComponent("manifest.json"), options: .atomic)
    try encoder.encode(index).write(to: indexURL, options: .atomic)
} catch {
    fail("could not write manifest/index: \(error.localizedDescription)")
}

cleanUp()
print("""
Built \(objectName):
  \(relativePath(of: usdzURL, to: repoRoot))
  \(relativePath(of: webDirectory.appendingPathComponent("manifest.json"), to: repoRoot))
""")
