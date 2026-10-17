import AVFoundation
import ImageIO
import Photos

/// Verifies native Apple pairing metadata; never manufactures a pair or modifies originals.
enum AppleLivePhotoPairValidator {
  private final class Request {
    private let lock = NSLock()
    private var requestId: PHLivePhotoRequestID?
    private var finished = false
    private var cancelled = false
    private let completion: (PHLivePhoto?) -> Void

    init(_ completion: @escaping (PHLivePhoto?) -> Void) {
      self.completion = completion
    }

    func register(_ requestId: PHLivePhotoRequestID) {
      lock.lock()
      self.requestId = requestId
      let shouldCancel = cancelled
      lock.unlock()
      if shouldCancel { PHLivePhoto.cancelRequest(withRequestID: requestId) }
    }

    func finish(_ livePhoto: PHLivePhoto?) {
      lock.lock()
      guard !finished else { lock.unlock(); return }
      finished = true
      let result = cancelled ? nil : livePhoto
      lock.unlock()
      completion(result)
    }

    func cancel() {
      lock.lock()
      guard !finished, !cancelled else { lock.unlock(); return }
      cancelled = true
      let requestId = requestId
      lock.unlock()
      if let requestId { PHLivePhoto.cancelRequest(withRequestID: requestId) }
      // PHLivePhoto guarantees a result-handler callback after cancellation. Wait for
      // that acknowledgement before allowing the caller to remove either resource.
      // register() cancels requests when cancellation won the ID-registration race.
    }
  }

  @discardableResult
  static func livePhoto(
    imageURL: URL,
    videoURL: URL,
    targetSize: CGSize = .zero,
    completion: @escaping (PHLivePhoto?) -> Void
  ) -> () -> Void {
    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
          let imageIdentity = maker["17"] as? String,
          !imageIdentity.isEmpty else {
      completion(nil)
      return {}
    }
    let video = AVURLAsset(url: videoURL)
    let videoIdentity = video.metadata(forFormat: .quickTimeMetadata).first {
      $0.identifier == .quickTimeMetadataContentIdentifier
    }?.stringValue
    guard videoIdentity == imageIdentity else {
      completion(nil)
      return {}
    }

    // PhotoKit also validates the paired-video still-image-time/resource representation.
    let state = Request(completion)
    let request = PHLivePhoto.request(
      withResourceFileURLs: [imageURL, videoURL],
      placeholderImage: nil,
      targetSize: targetSize,
      contentMode: .aspectFit
    ) { livePhoto, info in
      let cancelled = info[PHLivePhotoInfoCancelledKey] as? Bool == true
      let failed = info[PHLivePhotoInfoErrorKey] != nil
      // A cancellation/error callback is terminal even if its image is degraded.
      if !cancelled && !failed && info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
      state.finish(cancelled || failed ? nil : livePhoto)
    }
    state.register(request)
    return { state.cancel() }
  }
}
