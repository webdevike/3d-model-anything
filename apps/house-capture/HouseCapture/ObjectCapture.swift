import SwiftUI
import RealityKit
import QuickLook

/// One scanned object: Documents/Objects/<id>/ with Images/ (posed photos from Object Capture),
/// Checkpoint/ (reconstruction cache), model.usdz (on-device photogrammetry) and object.json.
struct ScannedObject: Identifiable, Codable, Hashable {
  var id: String
  var name: String
  var createdAt: Date

  static var root: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Objects", isDirectory: true)
  }
  var url: URL { Self.root.appendingPathComponent(id, isDirectory: true) }
  var images: URL { url.appendingPathComponent("Images", isDirectory: true) }
  var checkpoint: URL { url.appendingPathComponent("Checkpoint", isDirectory: true) }
  var model: URL { url.appendingPathComponent("model.usdz") }
  var hasModel: Bool { FileManager.default.fileExists(atPath: model.path) }
  var photoCount: Int { (try? FileManager.default.contentsOfDirectory(atPath: images.path).filter { $0.hasSuffix(".HEIC") || $0.hasSuffix(".heic") }.count) ?? 0 }

  static func all() -> [ScannedObject] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.compactMap { dir in
      guard let data = try? Data(contentsOf: dir.appendingPathComponent("object.json")) else { return nil }
      return try? JSONDecoder.iso.decode(ScannedObject.self, from: data)
    }.sorted { $0.createdAt > $1.createdAt }
  }

  static func create(name: String) throws -> ScannedObject {
    let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
    let obj = ScannedObject(id: "\(slug.isEmpty ? "object" : slug)-\(Int(Date().timeIntervalSince1970))", name: name, createdAt: Date())
    for dir in [obj.images, obj.checkpoint] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    try obj.save()
    return obj
  }

  func save() throws {
    try JSONEncoder.iso.encode(self).write(to: url.appendingPathComponent("object.json"), options: .atomic)
  }

  func delete() throws { try FileManager.default.removeItem(at: url) }
}

private extension JSONEncoder {
  static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
}
private extension JSONDecoder {
  static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

// MARK: list

struct ObjectsScreen: View {
  @State private var objects: [ScannedObject] = []
  @State private var naming = false
  @State private var newName = ""
  @State private var scanning: ScannedObject?
  @State private var deleting: ScannedObject?
  @State private var error: String?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Objects").font(.largeTitle.weight(.bold)).tracking(-1)
          Text("\(objects.count) object\(objects.count == 1 ? "" : "s")").font(.title3).foregroundStyle(Fieldwork.secondary)
        }.padding(.top, 12).padding(.bottom, 28)
        FieldworkRule()
        if objects.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "cube.transparent").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Fieldwork.orange)
            Text("Scan a single thing.").font(.title2.bold())
            Text("Put an object on a plain surface with space around it, then circle it slowly. Works best on matte, textured things from a mug to a chair.")
              .foregroundStyle(Fieldwork.secondary)
          }.padding(.vertical, 40)
        }
        ForEach(objects) { obj in
          NavigationLink { ObjectDetailScreen(object: obj, onRescan: { scanning = obj }) } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(obj.name).font(.headline)
                Text(obj.hasModel ? "Model ready" : "\(obj.photoCount) photos · not built yet")
                  .font(.subheadline).foregroundStyle(Fieldwork.secondary)
              }
              Spacer()
              Image(systemName: "arrow.up.right").foregroundStyle(Fieldwork.orange)
            }.padding(.vertical, 18).contentShape(Rectangle())
          }.buttonStyle(.plain)
          .contextMenu { Button("Delete object", systemImage: "trash", role: .destructive) { deleting = obj } }
          FieldworkRule()
        }
        if !ObjectCaptureSession.isSupported {
          Text("Object scanning requires an iPhone or iPad with LiDAR.").font(.footnote).foregroundStyle(Fieldwork.secondary).padding(.vertical, 24)
        }
      }.padding(.horizontal, 24).padding(.bottom, 20)
    }
    .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .principal) { FieldworkEyebrow(text: "3D Model Anything") } }
    .safeAreaInset(edge: .bottom) {
      Button { newName = ""; naming = true } label: { Label("Scan an object", systemImage: "cube.transparent") }
        .buttonStyle(FieldworkButtonStyle()).disabled(!ObjectCaptureSession.isSupported)
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10).background(Fieldwork.paper)
    }
    .onAppear(perform: reload)
    .alert("Name the object", isPresented: $naming) {
      TextField("Name", text: $newName)
      Button("Scan") {
        do { scanning = try ScannedObject.create(name: newName.isEmpty ? "Object" : newName) }
        catch { self.error = error.localizedDescription }
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") { error = nil }
    } message: { Text(error ?? "") }
    .confirmationDialog("Delete \(deleting?.name ?? "object")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
      Button("Delete object and photos", role: .destructive) {
        do { try deleting?.delete() } catch { self.error = error.localizedDescription }
        deleting = nil
        reload()
      }
    }
    .fullScreenCover(item: $scanning, onDismiss: reload) { obj in
      ObjectCaptureFlow(object: obj) { scanning = nil }
    }
  }

  private func reload() { objects = ScannedObject.all() }
}

// MARK: capture

/// Apple's guided Object Capture UI, then on-device reconstruction to model.usdz.
struct ObjectCaptureFlow: View {
  let object: ScannedObject
  let onClose: () -> Void

  @State private var session: ObjectCaptureSession?
  @State private var state = "Starting…"
  @State private var captured = false
  @State private var passDone = false
  @State private var progress: Double?
  @State private var failure: String?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if let session, !captured {
        ObjectCaptureView(session: session).ignoresSafeArea()
      }
      VStack {
        HStack {
          Button("Close") { session?.cancel(); onClose() }.buttonStyle(.bordered).tint(.white)
          Spacer()
          Text(state).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
        }.padding()
        Spacer()
        if let failure {
          Text(failure).font(.callout).foregroundStyle(.white).padding().background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)).padding()
        }
        if let progress {
          VStack(spacing: 10) {
            ProgressView(value: progress).tint(Fieldwork.orange)
            Text("Building model on iPhone · \(Int(progress * 100))%").foregroundStyle(.white)
          }.padding(24)
        }
        controls.padding(.horizontal, 24).padding(.bottom, 20)
      }
    }
    .task { await start() }
  }

  @ViewBuilder private var controls: some View {
    if let session, !captured {
      switch session.state {
      case .ready:
        Button("Detect object") { _ = session.startDetecting() }.buttonStyle(FieldworkButtonStyle())
      case .detecting:
        HStack {
          Button("Reset") { _ = session.resetDetection() }.buttonStyle(.bordered).tint(.white)
          Button("Start capture") { session.startCapturing() }.buttonStyle(FieldworkButtonStyle())
        }
      case .capturing:
        if passDone {
          HStack {
            Button("Another pass") { passDone = false; session.beginNewScanPass() }.buttonStyle(.bordered).tint(.white)
            Button("Finish") { session.finish() }.buttonStyle(FieldworkButtonStyle())
          }
        } else {
          Button("Finish now") { session.finish() }.buttonStyle(.bordered).tint(.white)
        }
      default: EmptyView()
      }
    } else if captured && progress == nil && failure == nil {
      Button("Done") { onClose() }.buttonStyle(FieldworkButtonStyle())
    } else if failure != nil {
      Button("Close") { onClose() }.buttonStyle(FieldworkButtonStyle())
    }
  }

  private func start() async {
    let s = ObjectCaptureSession()
    var config = ObjectCaptureSession.Configuration()
    config.checkpointDirectory = object.checkpoint
    config.isOverCaptureEnabled = true
    s.start(imagesDirectory: object.images, configuration: config)
    session = s
    Task { @MainActor in
      for await _ in s.userCompletedScanPassUpdates { passDone = true }
    }
    for await update in s.stateUpdates {
      state = label(update)
      switch update {
      case .completed:
        captured = true
        await ObjectReconstruction.run(object) { progress = $0 } onError: { failure = $0 }
        progress = nil
        state = failure == nil ? "Model ready" : "Reconstruction failed"
        return
      case .failed(let e):
        failure = e.localizedDescription
        return
      default: break
      }
    }
  }

  private func label(_ s: ObjectCaptureSession.CaptureState) -> String {
    switch s {
    case .initializing: "Starting…"
    case .ready: "Aim at the object"
    case .detecting: "Adjust the box"
    case .capturing: "Circle slowly"
    case .finishing: "Saving photos…"
    case .completed: "Captured"
    case .failed: "Failed"
    @unknown default: "…"
    }
  }
}

enum ObjectReconstruction {
  /// iOS photogrammetry only produces `.reduced` detail; Mac can redo the Images/ folder at higher detail.
  @MainActor
  static func run(_ object: ScannedObject, progress: @escaping (Double) -> Void, onError: @escaping (String) -> Void) async {
    guard PhotogrammetrySession.isSupported else { onError("On-device reconstruction isn't supported on this device."); return }
    do {
      var config = PhotogrammetrySession.Configuration()
      config.checkpointDirectory = object.checkpoint
      let session = try PhotogrammetrySession(input: object.images, configuration: config)
      try session.process(requests: [.modelFile(url: object.model, detail: .reduced)])
      progress(0)
      for try await output in session.outputs {
        switch output {
        case .requestProgress(_, let fraction): progress(fraction)
        case .requestError(_, let e): onError(e.localizedDescription)
        case .processingCancelled: onError("Reconstruction cancelled.")
        case .processingComplete: return
        default: break
        }
      }
    } catch {
      onError(error.localizedDescription)
    }
  }
}

// MARK: detail

struct ObjectDetailScreen: View {
  let object: ScannedObject
  let onRescan: () -> Void
  @State private var previewing: URL?
  @State private var sharing: URL?
  @State private var progress: Double?
  @State private var error: String?
  @State private var tick = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text(object.name).font(.largeTitle.weight(.bold)).tracking(-1)
        Text("\(object.photoCount) photos · \(object.hasModel ? "model ready" : "no model yet")").foregroundStyle(Fieldwork.secondary).id(tick)
        FieldworkRule()
        if object.hasModel {
          Button { previewing = object.model } label: { Label("View in 3D / AR", systemImage: "arkit") }.buttonStyle(FieldworkButtonStyle())
          Button { sharing = object.model } label: { Label("Share model (.usdz)", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
        }
        if object.photoCount > 0 {
          Button { rebuild() } label: { Label(object.hasModel ? "Rebuild model" : "Build model", systemImage: "hammer") }.buttonStyle(.bordered)
          Button { share() } label: { Label("Share photos + model (.zip)", systemImage: "archivebox") }.buttonStyle(.bordered)
        }
        Button { onRescan() } label: { Label("Scan again", systemImage: "cube.transparent") }.buttonStyle(.bordered)
        if let progress {
          ProgressView(value: progress) { Text("Building · \(Int(progress * 100))%") }.tint(Fieldwork.orange)
        }
      }.padding(24)
    }
    .disabled(progress != nil)
    .background(Fieldwork.paper).foregroundStyle(Fieldwork.ink)
    .quickLookPreview($previewing)
    .sheet(item: $sharing) { url in ShareSheet(items: [url]) }
    .alert("Something went wrong", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") { error = nil }
    } message: { Text(error ?? "") }
  }

  private func rebuild() {
    try? FileManager.default.removeItem(at: object.model)
    Task {
      await ObjectReconstruction.run(object) { progress = $0 } onError: { error = $0 }
      progress = nil
      tick += 1
    }
  }

  private func share() {
    Task.detached {
      let result = Result { try FolderZipper.zip(object.url, name: object.name) }
      await MainActor.run {
        switch result {
        case .success(let url): sharing = url
        case .failure(let e): error = e.localizedDescription
        }
      }
    }
  }
}
