import Flutter
import Photos
import UIKit
import UniformTypeIdentifiers

/// Export original PhotoKit resources and hand a native Live Photo to compatible
/// activities. Never flatten a requested pair or rewrite its pairing metadata.
final class LivePhotoApiImpl: ImmichPlugin, FlutterPlugin, LivePhotoApi {
  private final class Export {
    let directory: URL
    var requests: [PHAssetResourceDataRequestID] = []
    var cancelled = false
    init(directory: URL) { self.directory = directory }
  }
  private var exports: [String: Export] = [:]
  private final class Share {
    let completion: (Result<Bool, Error>) -> Void
    var cancelValidation: (() -> Void)?
    var cancelled = false
    var finished = false
    weak var controller: UIActivityViewController?
    init(completion: @escaping (Result<Bool, Error>) -> Void) { self.completion = completion }
  }
  private var share: Share?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LivePhotoApiImpl()
    LivePhotoApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    registrar.publish(instance)
  }

  func detachFromEngine(for registrar: any FlutterPluginRegistrar) {
    detachFromEngine()
  }

  override func detachFromEngine() {
    super.detachFromEngine()
    share?.cancelled = true
    share?.cancelValidation?()
    for operation in exports.values {
      operation.cancelled = true
      operation.requests.forEach { PHAssetResourceManager.default().cancelDataRequest($0) }
    }
  }

  func cancelLivePhotoShare() throws {
    guard let operation = share else { return }
    operation.cancelled = true
    operation.controller?.dismiss(animated: false)
    if let cancel = operation.cancelValidation {
      // Await the validator's terminal PhotoKit callback before releasing this
      // operation. Old callbacks cannot affect a subsequent share.
      cancel()
    } else { finishShare(operation, false) }
  }

  private func finishShare(_ operation: Share, _ result: Bool) {
    guard !operation.finished else { return }
    operation.finished = true
    if share === operation { share = nil }
    completeWhenActive(for: operation.completion, with: .success(result))
  }

  func cancelLivePhotoExport(localId: String) throws {
    guard let operation = exports[localId] else { return }
    operation.cancelled = true
    operation.requests.forEach { PHAssetResourceManager.default().cancelDataRequest($0) }
  }

  func exportLivePhoto(localId: String, completion: @escaping (Result<LivePhotoResourcePair?, Error>) -> Void) {
    guard !detached else { return }
    guard exports[localId] == nil,
          let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject,
          asset.mediaSubtypes.contains(.photoLive) else {
      completion(.success(nil)); return
    }
    let resources = PHAssetResource.assetResources(for: asset)
    guard let image = resources.first(where: { $0.type == .photo }),
          let video = resources.first(where: { $0.type == .pairedVideo }) else {
      completion(.success(nil)); return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outgoing_share", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    catch { completion(.success(nil)); return }
    let operation = Export(directory: directory)
    exports[localId] = operation
    // Original extensions and bytes are retained. Separate names avoid an exotic
    // identical resource filename overwriting the other member of the pair.
    let originalImageName = (image.originalFilename as NSString).lastPathComponent
    let originalVideoName = (video.originalFilename as NSString).lastPathComponent
    let imageName = originalImageName.isEmpty ? "still." + (UTType(image.uniformTypeIdentifier)?.preferredFilenameExtension ?? "jpg") : originalImageName
    let videoName = originalVideoName.isEmpty || originalVideoName == imageName ? "motion.mov" : originalVideoName
    let imageURL = directory.appendingPathComponent(imageName)
    let videoURL = directory.appendingPathComponent(videoName)
    write(resource: image, to: imageURL, operation: operation) { [weak self] error in
      guard let self else { return }
      if error != nil || operation.cancelled {
        self.finishExport(localId, operation, pair: nil, completion: completion); return
      }
      self.write(resource: video, to: videoURL, operation: operation) { [weak self] error in
        guard let self else { return }
        if error != nil || operation.cancelled {
          self.finishExport(localId, operation, pair: nil, completion: completion); return
        }
        self.finishExport(localId, operation,
          pair: LivePhotoResourcePair(imagePath: imageURL.path, videoPath: videoURL.path), completion: completion)
      }
    }
  }

  private func write(resource: PHAssetResource, to url: URL, operation: Export, completion: @escaping (Error?) -> Void) {
    let manager = PHAssetResourceManager.default()
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    guard FileManager.default.createFile(atPath: url.path, contents: nil),
          let handle = try? FileHandle(forWritingTo: url) else {
      completion(NSError(domain: "GalleryLivePhoto", code: 1)); return
    }
    let lock = NSLock()
    var writeError: Error?
    let request = manager.requestData(for: resource, options: options, dataReceivedHandler: { data in
      lock.lock(); defer { lock.unlock() }
      guard writeError == nil else { return }
      do { try handle.write(contentsOf: data) } catch { writeError = error }
    }, completionHandler: { error in
      lock.lock()
      try? handle.close()
      let failure = error ?? writeError
      lock.unlock()
      DispatchQueue.main.async { completion(failure) }
    })
    operation.requests.append(request)
    if operation.cancelled { manager.cancelDataRequest(request) }
  }

  private func finishExport(_ localId: String, _ operation: Export, pair: LivePhotoResourcePair?,
                            completion: @escaping (Result<LivePhotoResourcePair?, Error>) -> Void) {
    exports.removeValue(forKey: localId)
    if let pair, !operation.cancelled {
      do {
        try Data("{}".utf8).write(to: operation.directory.appendingPathComponent(".complete"), options: .atomic)
        completeWhenActive(for: completion, with: .success(pair))
      } catch {
        try? FileManager.default.removeItem(at: operation.directory)
        completeWhenActive(for: completion, with: .success(nil))
      }
    } else {
      // Resource callbacks have drained and handles are closed before deletion.
      try? FileManager.default.removeItem(at: operation.directory)
      completeWhenActive(for: completion, with: .success(nil))
    }
  }

  func shareLivePhotos(items: [LivePhotoShareItem], x: Double, y: Double, width: Double, height: Double,
                       completion: @escaping (Result<Bool, Error>) -> Void) {
    guard !detached else { return }
    guard !items.isEmpty, share == nil else { completion(.success(false)); return }
    let operation = Share(completion: completion)
    share = operation
    var providers: [NSItemProvider] = []
    func prepare(_ index: Int) {
      guard self.share === operation else { return }
      guard !self.detached, !operation.cancelled else { self.finishShare(operation, false); return }
      guard index < items.count else {
        guard let presenter = Self.presenter() else { self.finishShare(operation, false); return }
        let configuration = UIActivityItemsConfiguration(itemProviders: providers)
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        operation.controller = controller
        if let popover = controller.popoverPresentationController {
          popover.sourceView = presenter.view
          popover.sourceRect = CGRect(x: x, y: y, width: max(1, width), height: max(1, height))
        }
        presenter.present(controller, animated: true) { self.finishShare(operation, !operation.cancelled) }
        return
      }
      let item = items[index]
      let imageURL = URL(fileURLWithPath: item.imagePath)
      if let videoPath = item.videoPath {
        operation.cancelValidation = AppleLivePhotoPairValidator.livePhoto(imageURL: imageURL, videoURL: URL(fileURLWithPath: videoPath)) { photo in
          DispatchQueue.main.async {
            guard self.share === operation else { return }
            operation.cancelValidation = nil
            guard !self.detached, !operation.cancelled, let photo else { self.finishShare(operation, false); return }
            // PHLivePhoto is NSSecureCoding and NSItemProviderReading, but NOT
            // NSItemProviderWriting. Use the public secure-coding initializer.
            let provider = NSItemProvider(item: photo, typeIdentifier: UTType.livePhoto.identifier)
            provider.suggestedName = imageURL.lastPathComponent
            providers.append(provider)
            prepare(index + 1)
          }
        }
      } else if let provider = NSItemProvider(contentsOf: imageURL) {
        providers.append(provider)
        prepare(index + 1)
      } else { self.finishShare(operation, false) }
    }
    prepare(0)
  }

  private static func presenter() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })
    var controller = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }
}
