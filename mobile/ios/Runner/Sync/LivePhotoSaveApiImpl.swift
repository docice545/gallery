import Photos

/// Owns no media files: callers retain both originals until the final result/cancel drain.
class LivePhotoSaveApiImpl: ImmichPlugin, LivePhotoSaveApi, FlutterPlugin {
  static let name = "LivePhotoSaveApi"

  private class Save {
    let completion: (Result<LivePhotoSaveResult, Error>) -> Void
    var cancelValidation: (() -> Void)?
    var cancelWaiters: [(Result<Void, Error>) -> Void] = []
    var cancelled = false
    var committed = false
    var validating = false
    var finished = false

    init(completion: @escaping (Result<LivePhotoSaveResult, Error>) -> Void) {
      self.completion = completion
    }
  }

  private var saves: [String: Save] = [:]

  static func register(with registrar: any FlutterPluginRegistrar) {
    let instance = LivePhotoSaveApiImpl()
    LivePhotoSaveApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    registrar.publish(instance)
  }

  func detachFromEngine(for registrar: any FlutterPluginRegistrar) {
    detachFromEngine()
  }

  override func detachFromEngine() {
    super.detachFromEngine()
    for save in saves.values {
      save.cancelled = true
      save.cancelValidation?()
    }
  }

  func saveLivePhoto(
    requestId: String,
    imagePath: String,
    videoPath: String,
    title: String,
    allowImageOnlyFallback: Bool,
    completion: @escaping (Result<LivePhotoSaveResult, Error>) -> Void
  ) {
    guard !detached else { return }
    guard saves[requestId] == nil else {
      completion(.success(LivePhotoSaveResult(outcome: .failed, errorCode: "REQUEST_ACTIVE")))
      return
    }
    let save = Save(completion: completion)
    saves[requestId] = save
    let imageURL = URL(fileURLWithPath: imagePath)
    let videoURL = URL(fileURLWithPath: videoPath)
    let begin: (PHAuthorizationStatus) -> Void = { [weak self] authorization in
      DispatchQueue.main.async {
        guard let self, !save.finished,
              let current = self.saves[requestId], current === save else { return }
        if save.cancelled {
          self.finish(requestId, save, outcome: .cancelled, errorCode: "CANCELLED")
        } else if authorization == .authorized || authorization == .limited {
          self.validatePair(requestId, save, imageURL: imageURL, videoURL: videoURL,
                            title: title, allowImageOnlyFallback: allowImageOnlyFallback)
        } else {
          self.finish(requestId, save, outcome: .failed, errorCode: "PERMISSION_DENIED")
        }
      }
    }
    let authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if authorization == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: begin)
    } else {
      begin(authorization)
    }
  }

  private func validatePair(
    _ requestId: String,
    _ save: Save,
    imageURL: URL,
    videoURL: URL,
    title: String,
    allowImageOnlyFallback: Bool
  ) {
    save.validating = true
    // Validation needs a tiny render only. PhotoKit imports the unmodified original file URLs.
    save.cancelValidation = AppleLivePhotoPairValidator.livePhoto(
      imageURL: imageURL, videoURL: videoURL, targetSize: CGSize(width: 128, height: 128)
    ) { [weak self] livePhoto in
      DispatchQueue.main.async {
        guard let self, !save.finished else { return }
        save.cancelValidation = nil
        if save.cancelled {
          self.finish(requestId, save, outcome: .cancelled, errorCode: "CANCELLED")
        } else if livePhoto != nil {
          self.importResources(requestId, save, imageURL: imageURL, videoURL: videoURL, title: title,
                               allowFallback: allowImageOnlyFallback)
        } else if allowImageOnlyFallback {
          self.importResources(requestId, save, imageURL: imageURL, videoURL: nil, title: title,
                               allowFallback: false)
        } else {
          self.finish(requestId, save, outcome: .failed, errorCode: "INVALID_PAIR")
        }
      }
    }
  }

  func cancelSave(requestId: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let save = saves[requestId], !save.finished else {
      completeWhenActive(for: completion, with: .success(()))
      return
    }
    save.cancelWaiters.append(completion)
    save.cancelled = true
    // A PhotoKit transaction is atomic and cannot be aborted. Await its real result.
    if !save.committed {
      if !save.validating {
        // Authorization is pending; no media reader has started yet.
        finish(requestId, save, outcome: .cancelled, errorCode: "CANCELLED")
      } else {
        // The validator's final PhotoKit callback acknowledges/drains resource reads.
        save.cancelValidation?()
      }
    }
  }

  private func importResources(
    _ requestId: String,
    _ save: Save,
    imageURL: URL,
    videoURL: URL?,
    title: String,
    allowFallback: Bool
  ) {
    if save.cancelled {
      finish(requestId, save, outcome: .cancelled, errorCode: "CANCELLED")
      return
    }
    save.committed = true
    var identifier: String?
    PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCreationRequest.forAsset()
      let imageOptions = PHAssetResourceCreationOptions()
      imageOptions.originalFilename = title
      imageOptions.shouldMoveFile = false
      request.addResource(with: .photo, fileURL: imageURL, options: imageOptions)
      if let videoURL {
        let videoOptions = PHAssetResourceCreationOptions()
        videoOptions.originalFilename = videoURL.lastPathComponent
        videoOptions.shouldMoveFile = false
        request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
      }
      // Works with add-only authorization, without querying the user's library.
      identifier = request.placeholderForCreatedAsset?.localIdentifier
    } completionHandler: { [weak self] success, _ in
      DispatchQueue.main.async {
        guard let self, !save.finished else { return }
        if success {
          guard let identifier else {
            // The write committed. Never retry/fallback and accidentally create a second asset.
            self.finish(requestId, save, outcome: .failed, errorCode: "COMMITTED_WITHOUT_IDENTIFIER")
            return
          }
          self.finish(requestId, save, outcome: videoURL == nil ? .imageOnly : .livePhoto,
                      identifier: identifier, errorCode: videoURL == nil ? "IMAGE_ONLY" : nil)
        } else if save.cancelled {
          self.finish(requestId, save, outcome: .cancelled, errorCode: "CANCELLED")
        } else if videoURL != nil && allowFallback {
          // PhotoKit failed atomically: fallback creates one still, never a second asset after success.
          save.committed = false
          self.importResources(requestId, save, imageURL: imageURL, videoURL: nil, title: title, allowFallback: false)
        } else {
          self.finish(requestId, save, outcome: .failed, errorCode: "PHOTOKIT_SAVE_FAILED")
        }
      }
    }
  }

  private func finish(
    _ requestId: String,
    _ save: Save,
    outcome: LivePhotoSaveOutcome,
    identifier: String? = nil,
    errorCode: String? = nil
  ) {
    guard !save.finished else { return }
    save.finished = true
    saves.removeValue(forKey: requestId)
    completeWhenActive(for: save.completion, with: .success(
      LivePhotoSaveResult(outcome: outcome, localIdentifier: identifier, errorCode: errorCode)
    ))
    for waiter in save.cancelWaiters {
      completeWhenActive(for: waiter, with: .success(()))
    }
    save.cancelWaiters.removeAll()
  }
}
