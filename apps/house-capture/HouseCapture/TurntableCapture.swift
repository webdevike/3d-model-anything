import SwiftUI
import ARKit
import SceneKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The printed tracking sheet (TurntableSheet.png, tools/turntable-sheet.py). It must be printed at exactly this size.
enum TurntableSheet {
  /// Printed size as measured on the Brother HL-L2350DW (100 mm bar printed at 99 mm).
  static let sizeMM: Double = 178.2
  static let physicalWidth: CGFloat = 0.1782
  static let imageName = "TurntableSheet"
}

enum TurntablePass: String, Codable {
  case upright, flipped
  var title: String { self == .upright ? "Pass 1 · upright" : "Pass 2 · flipped" }
}

/// Viewing-direction bins in the sheet frame (origin sheet centre, +Y up out of the sheet, metres):
/// 24 azimuth sectors × 3 elevation bands around a point 5 cm above the sheet.
enum TurntableGrid {
  static let azimuthBins = 24
  static let bands: [(low: Float, high: Float)] = [(5, 25), (25, 45), (45, 70)]
  static var count: Int { azimuthBins * bands.count }
  static let center = SIMD3<Float>(0, 0.05, 0)
  static let radius: Float = 0.16

  static func band(elevation: Float) -> Int? { bands.firstIndex { elevation >= $0.low && elevation < $0.high } }

  static func bin(azimuth: Float, elevation: Float) -> Int? {
    guard let b = band(elevation: elevation) else { return nil }
    let a = min(azimuthBins - 1, max(0, Int(azimuth / (360 / Float(azimuthBins)))))
    return b * azimuthBins + a
  }

  /// Azimuth in [0, 360) and elevation of the camera, in degrees
  static func view(_ cameraInSheet: simd_float4x4) -> (azimuth: Float, elevation: Float) {
    let v = simd_make_float3(cameraInSheet.columns.3) - center
    var az = atan2(v.z, v.x) * 180 / .pi
    if az < 0 { az += 360 }
    if az >= 360 { az -= 360 }
    return (az, atan2(v.y, hypot(v.x, v.z)) * 180 / .pi)
  }

  static func direction(azimuth: Float, elevation: Float) -> SIMD3<Float> {
    let a = azimuth * .pi / 180, e = elevation * .pi / 180
    return SIMD3(cos(e) * cos(a), sin(e), cos(e) * sin(a))
  }
}

// MARK: screen

struct TurntableCaptureFlow: View {
  let object: ScannedObject
  let onClose: () -> Void
  @StateObject private var model: TurntableCaptureModel

  init(object: ScannedObject, onClose: @escaping () -> Void) {
    self.object = object
    self.onClose = onClose
    _model = StateObject(wrappedValue: TurntableCaptureModel(object: object))
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      TurntableARView(model: model).ignoresSafeArea()
      Color.white.opacity(model.flash ? 0.55 : 0).ignoresSafeArea().allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: model.flash)
      VStack {
        HStack(alignment: .top) {
          Button("Close") { model.stop(); onClose() }.buttonStyle(.bordered).tint(.white)
          Spacer()
          VStack(alignment: .trailing, spacing: 6) {
            Text(model.hud.state).font(.footnote.weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
            Text("\(model.hud.pass.title) · \(model.hud.percent)% · \(model.hud.photos) photos")
              .font(.caption.monospacedDigit()).foregroundStyle(.white)
              .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.45), in: Capsule())
          }
        }.padding()
        Spacer()
        if let failure = model.failure {
          Text(failure).font(.callout).foregroundStyle(.white).padding()
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)).padding()
        }
        HStack {
          if model.hud.pass == .upright {
            Button("I flipped it") { model.flip() }.buttonStyle(.bordered).tint(.white)
          }
          Button("Finish") { model.finish(then: onClose) }.buttonStyle(FieldworkButtonStyle()).disabled(model.finishing)
        }.padding(.horizontal, 24).padding(.bottom, 20)
      }
    }
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }
}

private struct TurntableARView: UIViewRepresentable {
  let model: TurntableCaptureModel
  func makeUIView(context: Context) -> ARSCNView { model.view }
  func updateUIView(_ view: ARSCNView, context: Context) {}
}

// MARK: capture model

@MainActor
final class TurntableCaptureModel: ObservableObject {
  struct HUD: Equatable {
    var state = "Sheet not found"
    var pass: TurntablePass = .upright
    var percent = 0
    var photos = 0
  }

  @Published private(set) var hud = HUD()
  @Published private(set) var flash = false
  @Published private(set) var failure: String?
  @Published private(set) var finishing = false

  let view = ARSCNView(frame: .zero)
  private let object: ScannedObject
  private let delegate = TurntableSessionDelegate()
  private let dome = TurntableDome()
  private let saveQueue = DispatchQueue(label: "turntable.save", qos: .userInitiated)
  private let haptic = UIImpactFeedbackGenerator(style: .medium)

  private var pass: TurntablePass = .upright
  private var covered: [TurntablePass: Set<Int>] = [.upright: [], .flipped: []]
  private var history: [Sample] = []
  private var lastShot: TimeInterval = -.infinity
  private var nextIndex: Int
  private var photos: Int
  private var pendingSaves = 0
  private var running = false

  private struct Sample {
    let time: TimeInterval
    let pose: simd_float4x4
    let luma: [UInt8]
  }

  private static let historySeconds: TimeInterval = 0.6
  private static let stillSeconds: TimeInterval = 0.5
  private static let maxTranslation: Float = 0.003
  private static let maxRotationDeg: Float = 1
  private static let maxLumaDiff: Float = 4
  private static let minShotInterval: TimeInterval = 0.7
  private static let maxPendingSaves = 4

  init(object: ScannedObject) {
    self.object = object
    let names = (try? FileManager.default.contentsOfDirectory(atPath: object.turntable.path)) ?? []
    let indices = names.filter { $0.lowercased().hasSuffix(".jpg") }.compactMap { Int($0.prefix { $0.isNumber }) }
    nextIndex = (indices.max() ?? -1) + 1
    photos = indices.count
    hud.photos = photos
  }

  func start() {
    guard !running else { return }
    guard ARWorldTrackingConfiguration.isSupported else { failure = "This device can't run AR world tracking."; return }
    guard let cg = UIImage(named: TurntableSheet.imageName)?.cgImage else { failure = "The tracking sheet image is missing from the app."; return }
    do {
      try FileManager.default.createDirectory(at: object.turntable, withIntermediateDirectories: true)
    } catch {
      failure = error.localizedDescription
      return
    }
    let reference = ARReferenceImage(cg, orientation: .up, physicalWidth: TurntableSheet.physicalWidth)
    reference.name = "turntable-sheet"
    let config = ARWorldTrackingConfiguration()
    config.detectionImages = [reference]
    config.maximumNumberOfTrackedImages = 1
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }

    if dome.root.parent == nil { view.scene.rootNode.addChildNode(dome.root) }
    delegate.model = self
    view.session.delegateQueue = .main
    view.session.delegate = delegate
    view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    UIApplication.shared.isIdleTimerDisabled = true
    haptic.prepare()
    running = true
  }

  func stop() {
    guard running else { return }
    running = false
    view.session.pause()
    UIApplication.shared.isIdleTimerDisabled = false
  }

  func flip() {
    pass = .flipped
    history.removeAll()
    lastShot = -.infinity
    dome.update(covered: covered[pass] ?? [], current: nil)
    setHUD(state: "Turn the plate")
  }

  /// Writes object.json (kind turntable) after every queued photo is on disk, then calls `done`.
  func finish(then done: @escaping () -> Void) {
    guard !finishing else { return }
    finishing = true
    stop()
    var obj = object
    obj.kind = .turntable
    obj.sheetSizeMM = TurntableSheet.sizeMM
    saveQueue.async {
      let result = Result { try obj.save() }
      Task { @MainActor [weak self] in
        if case .failure(let e) = result { self?.failure = e.localizedDescription; self?.finishing = false; return }
        done()
      }
    }
  }

  fileprivate func fail(_ message: String) { failure = message }

  fileprivate func process(_ frame: ARFrame) {
    guard running else { return }
    guard let anchor = frame.anchors.lazy.compactMap({ $0 as? ARImageAnchor }).first(where: { $0.isTracked }) else {
      dome.root.isHidden = true
      history.removeAll()
      setHUD(state: "Sheet not found")
      return
    }
    let cameraInSheet = anchor.transform.inverse * frame.camera.transform
    dome.root.simdTransform = anchor.transform
    dome.root.isHidden = false

    let angles = TurntableGrid.view(cameraInSheet)
    let bin = TurntableGrid.bin(azimuth: angles.azimuth, elevation: angles.elevation)
    let now = frame.timestamp
    history.append(Sample(time: now, pose: cameraInSheet, luma: Self.luma(frame.capturedImage)))
    history.removeAll { now - $0.time > Self.historySeconds }

    var done = covered[pass] ?? []
    if let bin, !done.contains(bin), isStill(), now - lastShot >= Self.minShotInterval, pendingSaves < Self.maxPendingSaves {
      if shoot(frame, cameraInSheet: cameraInSheet, azimuth: angles.azimuth, elevation: angles.elevation) {
        done.insert(bin)
        covered[pass] = done
        lastShot = now
      }
    }
    dome.update(covered: done, current: bin)
    setHUD(state: stateText(bin: bin, elevation: angles.elevation, covered: done))
  }

  private func stateText(bin: Int?, elevation: Float, covered done: Set<Int>) -> String {
    if done.count == TurntableGrid.count { return pass == .upright ? "Pass complete, flip it" : "Pass complete, tap Finish" }
    guard let bin else { return elevation < TurntableGrid.bands[0].low ? "Raise phone" : "Lower phone" }
    let band = bin / TurntableGrid.azimuthBins
    let bandRange = band * TurntableGrid.azimuthBins..<(band + 1) * TurntableGrid.azimuthBins
    if bandRange.allSatisfy(done.contains) {
      let higherOpen = (band + 1..<TurntableGrid.bands.count).contains { b in
        (b * TurntableGrid.azimuthBins..<(b + 1) * TurntableGrid.azimuthBins).contains { !done.contains($0) }
      }
      return higherOpen ? "Raise phone for next ring" : "Lower phone for next ring"
    }
    return done.contains(bin) ? "Turn the plate" : "Hold still…"
  }

  private func setHUD(state: String) {
    let done = covered[pass]?.count ?? 0
    let next = HUD(state: state, pass: pass, percent: done * 100 / TurntableGrid.count, photos: photos)
    if next != hud { hud = next }
  }

  /// Still = over the last 0.5 s the camera moved < 3 mm and < 1° relative to the sheet, and the image barely changed.
  private func isStill() -> Bool {
    guard let current = history.last, let oldest = history.first,
          current.time - oldest.time >= Self.stillSeconds - 0.05, !current.luma.isEmpty else { return false }
    let position = simd_make_float3(current.pose.columns.3)
    let rotation = simd_quatf(Self.rotation(current.pose))
    for s in history where current.time - s.time <= Self.stillSeconds {
      if simd_distance(position, simd_make_float3(s.pose.columns.3)) >= Self.maxTranslation { return false }
      let dot = min(1, abs(simd_dot(rotation.vector, simd_quatf(Self.rotation(s.pose)).vector)))
      if 2 * acos(dot) * 180 / .pi >= Self.maxRotationDeg { return false }
      guard s.luma.count == current.luma.count else { return false }
      var sum = 0
      for i in s.luma.indices { sum += abs(Int(s.luma[i]) - Int(current.luma[i])) }
      if Float(sum) / Float(s.luma.count) >= Self.maxLumaDiff { return false }
    }
    return true
  }

  private static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
    simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
  }

  /// Copies everything the writer needs out of the frame (the frame itself is never retained).
  private func shoot(_ frame: ARFrame, cameraInSheet: simd_float4x4, azimuth: Float, elevation: Float) -> Bool {
    guard let image = TurntableWriter.copy(frame.capturedImage) else { return false }
    let resolution = frame.camera.imageResolution
    let shot = TurntableShot(
      index: nextIndex, pass: pass, azimuth: azimuth, elevation: elevation,
      image: image, width: Int(resolution.width), height: Int(resolution.height),
      intrinsics: frame.camera.intrinsics, cameraInSheet: cameraInSheet, timestamp: frame.timestamp,
      depth: TurntableWriter.copyDepth(frame))
    nextIndex += 1
    photos += 1
    pendingSaves += 1
    haptic.impactOccurred()
    haptic.prepare()
    flash = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.flash = false }
    let folder = object.turntable
    saveQueue.async {
      let result = Result { try TurntableWriter.write(shot, to: folder) }
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.pendingSaves -= 1
        if case .failure(let e) = result { self.failure = "Couldn't save photo: \(e.localizedDescription)" }
      }
    }
    return true
  }

  /// 32×24 luma samples straight from the Y plane
  private static func luma(_ buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard CVPixelBufferGetPlaneCount(buffer) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }
    let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var out = [UInt8]()
    out.reserveCapacity(32 * 24)
    for j in 0..<24 {
      let y = (2 * j + 1) * h / 48
      for i in 0..<32 { out.append(p[y * stride + (2 * i + 1) * w / 64]) }
    }
    return out
  }
}

/// ARSession delegate on the main queue; forwards frames to the model.
private final class TurntableSessionDelegate: NSObject, ARSessionDelegate {
  weak var model: TurntableCaptureModel?

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    MainActor.assumeIsolated { model?.process(frame) }
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    let message = error.localizedDescription
    MainActor.assumeIsolated { model?.fail(message) }
  }
}

// MARK: coverage dome

/// One translucent tile per bin on a hemisphere around the object: red = still needed, green = covered,
/// the tile under the current view brighter with a white outline.
@MainActor
private final class TurntableDome {
  let root = SCNNode()
  private var tiles: [SCNNode] = []
  private var looks: [Look?]
  private let outline = SCNNode()
  private var outlined: Int?? = .none

  private enum Look: Equatable { case open, done, openHere, doneHere }

  init() {
    looks = Array(repeating: nil, count: TurntableGrid.count)
    let step = 360 / Float(TurntableGrid.azimuthBins)
    let gap: Float = 0.8
    for (b, band) in TurntableGrid.bands.enumerated() {
      for a in 0..<TurntableGrid.azimuthBins {
        let corners = Self.corners(a0: Float(a) * step + gap, a1: Float(a + 1) * step - gap,
                                   e0: band.low + gap, e1: band.high - gap, radius: TurntableGrid.radius)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners)],
                                   elements: [SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.blendMode = .alpha
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = "bin-\(b * TurntableGrid.azimuthBins + a)"
        node.renderingOrder = 10
        tiles.append(node)
        root.addChildNode(node)
      }
    }
    outline.renderingOrder = 11
    root.addChildNode(outline)
  }

  private static func corners(a0: Float, a1: Float, e0: Float, e1: Float, radius: Float) -> [SCNVector3] {
    [(a0, e0), (a1, e0), (a1, e1), (a0, e1)].map { a, e in
      let p = TurntableGrid.center + TurntableGrid.direction(azimuth: a, elevation: e) * radius
      return SCNVector3(p.x, p.y, p.z)
    }
  }

  func update(covered: Set<Int>, current: Int?) {
    for i in tiles.indices {
      let isDone = covered.contains(i), here = i == current
      let look: Look = here ? (isDone ? .doneHere : .openHere) : (isDone ? .done : .open)
      guard looks[i] != look else { continue }
      looks[i] = look
      let material = tiles[i].geometry?.firstMaterial
      switch look {
      case .open: material?.diffuse.contents = UIColor.systemRed; material?.transparency = 0.35
      case .done: material?.diffuse.contents = UIColor.systemGreen; material?.transparency = 0.35
      case .openHere: material?.diffuse.contents = UIColor(red: 1, green: 0.45, blue: 0.4, alpha: 1); material?.transparency = 0.75
      case .doneHere: material?.diffuse.contents = UIColor(red: 0.5, green: 1, blue: 0.55, alpha: 1); material?.transparency = 0.75
      }
    }
    if outlined != .some(current) {
      outlined = .some(current)
      outline.geometry = current.map(Self.outlineGeometry)
    }
  }

  private static func outlineGeometry(_ bin: Int) -> SCNGeometry {
    let step = 360 / Float(TurntableGrid.azimuthBins)
    let a = bin % TurntableGrid.azimuthBins, band = TurntableGrid.bands[bin / TurntableGrid.azimuthBins]
    let corners = Self.corners(a0: Float(a) * step + 0.4, a1: Float(a + 1) * step - 0.4,
                               e0: band.low + 0.4, e1: band.high - 0.4, radius: TurntableGrid.radius * 1.004)
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners)],
                               elements: [SCNGeometryElement(indices: [Int32(0), 1, 1, 2, 2, 3, 3, 0], primitiveType: .line)])
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = UIColor.white
    material.writesToDepthBuffer = false
    material.readsFromDepthBuffer = false
    geometry.materials = [material]
    return geometry
  }
}

// MARK: writing

/// @unchecked: `image` is a private deep copy handed to the save queue and never touched again.
struct TurntableShot: @unchecked Sendable {
  struct Depth {
    let width: Int, height: Int
    let values: [Float32]
    /// ARConfidenceLevel raw values per pixel, if available
    let confidence: [UInt8]?
  }

  let index: Int
  let pass: TurntablePass
  let azimuth: Float, elevation: Float
  /// Deep copy of the captured YCbCr frame
  let image: CVPixelBuffer
  let width: Int, height: Int
  let intrinsics: simd_float3x3
  let cameraInSheet: simd_float4x4
  let timestamp: TimeInterval
  let depth: Depth?
}

/// NNNN.json next to NNNN.jpg / NNNN-mask.png
private struct TurntableFrameRecord: Codable {
  let index: Int
  let pass: String
  let azimuthDeg: Double
  let elevationDeg: Double
  let imageSize: [Int]
  let intrinsics: [Float]
  let cameraInSheet: [Float]
  let timestamp: Double
}

enum TurntableWriter {
  /// Mask region in the sheet frame: a cylinder over the sheet
  static let maskRadius: Float = 0.13
  static let maskFloor: Float = -0.01
  static let maskDepthTop: Float = 0.6
  static let maskFallbackTop: Float = 0.4

  private static let context = CIContext()

  static func write(_ shot: TurntableShot, to folder: URL) throws {
    let name = String(format: "%04d", shot.index)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let jpeg = context.jpegRepresentation(of: CIImage(cvPixelBuffer: shot.image), colorSpace: space,
                                                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "JPEG encoding failed"]) }
    try jpeg.write(to: folder.appendingPathComponent("\(name).jpg"), options: .atomic)

    let k = shot.intrinsics, m = shot.cameraInSheet
    let record = TurntableFrameRecord(
      index: shot.index, pass: shot.pass.rawValue,
      azimuthDeg: Double(shot.azimuth), elevationDeg: Double(shot.elevation),
      imageSize: [shot.width, shot.height],
      intrinsics: (0..<3).flatMap { r in (0..<3).map { c in k[c][r] } },
      cameraInSheet: (0..<4).flatMap { c in (0..<4).map { r in m[c][r] } },
      timestamp: shot.timestamp)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: folder.appendingPathComponent("\(name).json"), options: .atomic)

    let (grid, gw, gh) = shot.depth.map { depthMask(shot, $0) } ?? cylinderMask(shot)
    let dilated = dilate(grid, gw, gh, radius: 2)
    try writePNG(upscale(dilated, gw, gh, to: shot.width, shot.height), shot.width, shot.height,
                 to: folder.appendingPathComponent("\(name)-mask.png"))
  }

  /// Depth pixels (medium/high confidence) whose 3D point lies inside the cylinder over the sheet
  private static func depthMask(_ shot: TurntableShot, _ depth: TurntableShot.Depth) -> ([UInt8], Int, Int) {
    let k = shot.intrinsics, m = shot.cameraInSheet
    let fx = k[0][0], fy = k[1][1], cx = k[2][0], cy = k[2][1]
    let sx = Float(shot.width) / Float(depth.width), sy = Float(shot.height) / Float(depth.height)
    let r2 = maskRadius * maskRadius
    var out = [UInt8](repeating: 0, count: depth.width * depth.height)
    for v in 0..<depth.height {
      for u in 0..<depth.width {
        let i = v * depth.width + u
        if let c = depth.confidence, c[i] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
        let d = depth.values[i]
        guard d.isFinite, d > 0 else { continue }
        let x = ((Float(u) + 0.5) * sx - cx) / fx * d
        let y = ((Float(v) + 0.5) * sy - cy) / fy * d
        let p = m * SIMD4<Float>(x, -y, -d, 1)
        if p.x * p.x + p.z * p.z < r2, p.y >= maskFloor, p.y <= maskDepthTop { out[i] = 255 }
      }
    }
    return (out, depth.width, depth.height)
  }

  /// No depth: pixels whose camera ray passes through the cylinder (r 0.13 m, 0.4 m tall) over the sheet
  private static func cylinderMask(_ shot: TurntableShot) -> ([UInt8], Int, Int) {
    let scale = 8
    let gw = max(1, shot.width / scale), gh = max(1, shot.height / scale)
    let k = shot.intrinsics, m = shot.cameraInSheet
    let fx = k[0][0], fy = k[1][1], cx = k[2][0], cy = k[2][1]
    let sx = Float(shot.width) / Float(gw), sy = Float(shot.height) / Float(gh)
    let o = simd_make_float3(m.columns.3)
    let rot = simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
    let r2 = maskRadius * maskRadius
    var out = [UInt8](repeating: 0, count: gw * gh)
    for v in 0..<gh {
      for u in 0..<gw {
        let px = (Float(u) + 0.5) * sx, py = (Float(v) + 0.5) * sy
        let d = rot * SIMD3<Float>((px - cx) / fx, -(py - cy) / fy, -1)
        var lo: Float = 0, hi = Float.greatestFiniteMagnitude
        // side wall: x² + z² < r²
        let a = d.x * d.x + d.z * d.z, b = 2 * (o.x * d.x + o.z * d.z), c = o.x * o.x + o.z * o.z - r2
        if a < 1e-9 {
          if c >= 0 { continue }
        } else {
          let disc = b * b - 4 * a * c
          if disc < 0 { continue }
          let s = disc.squareRoot()
          lo = max(lo, (-b - s) / (2 * a)); hi = min(hi, (-b + s) / (2 * a))
        }
        // caps: floor ≤ y ≤ top
        if abs(d.y) < 1e-9 {
          if o.y < maskFloor || o.y > maskFallbackTop { continue }
        } else {
          let t0 = (maskFloor - o.y) / d.y, t1 = (maskFallbackTop - o.y) / d.y
          lo = max(lo, min(t0, t1)); hi = min(hi, max(t0, t1))
        }
        if lo < hi { out[v * gw + u] = 255 }
      }
    }
    return (out, gw, gh)
  }

  private static func dilate(_ src: [UInt8], _ w: Int, _ h: Int, radius: Int) -> [UInt8] {
    var horizontal = [UInt8](repeating: 0, count: src.count)
    for y in 0..<h {
      for x in 0..<w where src[y * w + x] != 0 {
        for xx in max(0, x - radius)...min(w - 1, x + radius) { horizontal[y * w + xx] = 255 }
      }
    }
    var out = [UInt8](repeating: 0, count: src.count)
    for y in 0..<h {
      for x in 0..<w where horizontal[y * w + x] != 0 {
        for yy in max(0, y - radius)...min(h - 1, y + radius) { out[yy * w + x] = 255 }
      }
    }
    return out
  }

  /// Nearest-neighbour upscale to the photo's pixel size
  private static func upscale(_ src: [UInt8], _ w: Int, _ h: Int, to width: Int, _ height: Int) -> [UInt8] {
    let columns = (0..<width).map { min(w - 1, $0 * w / width) }
    var out = [UInt8](repeating: 0, count: width * height)
    out.withUnsafeMutableBufferPointer { dst in
      src.withUnsafeBufferPointer { s in
        for y in 0..<height {
          let row = min(h - 1, y * h / height) * w
          let base = y * width
          for x in 0..<width { dst[base + x] = s[row + columns[x]] }
        }
      }
    }
    return out
  }

  private static func writePNG(_ pixels: [UInt8], _ width: Int, _ height: Int, to url: URL) throws {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Mask encoding failed"]) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
  }

  /// Deep copy so ARKit's capture buffer pool isn't held while the JPEG is encoded
  static func copy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
    var out: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    guard CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), CVPixelBufferGetPixelFormatType(src), attrs, &out) == kCVReturnSuccess,
          let dst = out else { return nil }
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
      CVPixelBufferUnlockBaseAddress(dst, [])
      CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
    let planes = CVPixelBufferGetPlaneCount(src)
    if planes == 0 {
      guard let s = CVPixelBufferGetBaseAddress(src), let d = CVPixelBufferGetBaseAddress(dst) else { return nil }
      copyRows(s, CVPixelBufferGetBytesPerRow(src), d, CVPixelBufferGetBytesPerRow(dst), rows: CVPixelBufferGetHeight(src))
    } else {
      for p in 0..<planes {
        guard let s = CVPixelBufferGetBaseAddressOfPlane(src, p), let d = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { return nil }
        copyRows(s, CVPixelBufferGetBytesPerRowOfPlane(src, p), d, CVPixelBufferGetBytesPerRowOfPlane(dst, p),
                 rows: CVPixelBufferGetHeightOfPlane(src, p))
      }
    }
    return dst
  }

  private static func copyRows(_ s: UnsafeMutableRawPointer, _ sStride: Int, _ d: UnsafeMutableRawPointer, _ dStride: Int, rows: Int) {
    if sStride == dStride { memcpy(d, s, sStride * rows); return }
    let n = min(sStride, dStride)
    for r in 0..<rows { memcpy(d + r * dStride, s + r * sStride, n) }
  }

  static func copyDepth(_ frame: ARFrame) -> TurntableShot.Depth? {
    guard let sceneDepth = frame.sceneDepth else { return nil }
    let map = sceneDepth.depthMap
    let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
    guard let values: [Float32] = read(map, w, h) else { return nil }
    let confidence: [UInt8]? = sceneDepth.confidenceMap.flatMap { c in
      CVPixelBufferGetWidth(c) == w && CVPixelBufferGetHeight(c) == h ? read(c, w, h) : nil
    }
    return TurntableShot.Depth(width: w, height: h, values: values, confidence: confidence)
  }

  private static func read<T>(_ buffer: CVPixelBuffer, _ w: Int, _ h: Int) -> [T]? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard stride >= w * MemoryLayout<T>.size else { return nil }
    return [T](unsafeUninitializedCapacity: w * h) { out, count in
      for y in 0..<h {
        let row = (base + y * stride).assumingMemoryBound(to: T.self)
        for x in 0..<w { (out.baseAddress! + y * w + x).initialize(to: row[x]) }
      }
      count = w * h
    }
  }
}
