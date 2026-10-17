import Photos
import UIKit
import UniformTypeIdentifiers
import share_handler_ios_models

/// Retain one logical attachment for a Live Photo. Existing plugin notification
/// format stays unchanged; an owned sidecar carries the paired resource path.
final class ShareViewController: UIViewController {
  private var completed = false
  private var staging: [URL] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    Task { await prepare() }
  }

  private func prepare() async {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
          let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
          let defaults = UserDefaults(suiteName: group) else { finish(); return }
    var attachments: [SharedAttachment] = []
    do {
      for item in extensionContext?.inputItems.compactMap({ $0 as? NSExtensionItem }) ?? [] {
        for provider in item.attachments ?? [] {
          if provider.canLoadObject(ofClass: PHLivePhoto.self) {
            let photo: PHLivePhoto = try await withCheckedThrowingContinuation { continuation in
              provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                if let photo = object as? PHLivePhoto { continuation.resume(returning: photo) }
                else { continuation.resume(throwing: error ?? Self.invalidResource()) }
              }
            }
            attachments.append(try await stage(photo, root: root))
          } else if provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
            // A native pair must never silently become its still fallback.
            throw Self.invalidResource()
          } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            attachments.append(try await stage(provider, type: .image, identifier: UTType.image.identifier, root: root))
          } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            attachments.append(try await stage(provider, type: .video, identifier: UTType.movie.identifier, root: root))
          }
        }
      }
      guard !attachments.isEmpty else { throw Self.invalidResource() }
      let media = SharedMedia(attachments: attachments, conversationIdentifier: nil, content: nil,
        speakableGroupName: nil, serviceName: nil, senderIdentifier: nil, imageFilePath: nil)
      defaults.set(media.toJson(), forKey: "ShareKey")
      staging.removeAll()
      redirectToHost()
      finish()
    } catch {
      staging.forEach { try? FileManager.default.removeItem(at: $0) }
      finish(error: Self.invalidResource())
    }
  }

  private func directory(_ root: URL, live: Bool) throws -> URL {
    let result = root.appendingPathComponent(live ? "live_photo_imports" : "gallery_share_imports", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    staging.append(result)
    return result
  }

  private func stage(_ photo: PHLivePhoto, root: URL) async throws -> SharedAttachment {
    let resources = PHAssetResource.assetResources(for: photo)
    guard let image = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
          let video = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) else {
      throw Self.invalidResource()
    }
    let target = try directory(root, live: true)
    let originalImageName = (image.originalFilename as NSString).lastPathComponent
    let originalVideoName = (video.originalFilename as NSString).lastPathComponent
    let imageName = originalImageName.isEmpty ? "still." + (UTType(image.uniformTypeIdentifier)?.preferredFilenameExtension ?? "jpg") : originalImageName
    let videoName = originalVideoName.isEmpty || originalVideoName == imageName ? "motion.mov" : originalVideoName
    let imageURL = target.appendingPathComponent(imageName)
    let videoURL = target.appendingPathComponent(videoName)
    try await write(image, to: imageURL)
    try await write(video, to: videoURL)
    let manifest: [String: Any] = ["version": 1, "image": imageURL.lastPathComponent, "video": videoURL.lastPathComponent]
    try JSONSerialization.data(withJSONObject: manifest).write(to: target.appendingPathComponent(".live-photo.json"), options: .atomic)
    try Data("{}".utf8).write(to: target.appendingPathComponent(".complete"), options: .atomic)
    return SharedAttachment(path: imageURL.absoluteString, type: .image)
  }

  private func write(_ resource: PHAssetResource, to url: URL) async throws {
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func stage(_ provider: NSItemProvider, type: SharedAttachmentType, identifier: String, root: URL) async throws -> SharedAttachment {
    let target = try directory(root, live: false)
    return try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
        if url == nil && type == .image {
          // UIImage-only providers (clipboard/screenshot apps) have no original
          // file representation. Preserve the pre-existing explicit image path.
          provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
            do {
              let output: URL
              if let source = item as? URL {
                output = target.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: output)
              } else if let data = item as? Data {
                output = target.appendingPathComponent("image")
                try data.write(to: output, options: .atomic)
              } else if let image = item as? UIImage, let data = image.pngData() {
                output = target.appendingPathComponent("image.png")
                try data.write(to: output, options: .atomic)
              } else { throw error ?? Self.invalidResource() }
              try Data("{}".utf8).write(to: target.appendingPathComponent(".complete"), options: .atomic)
              continuation.resume(returning: SharedAttachment(path: output.absoluteString, type: type))
            } catch { continuation.resume(throwing: error) }
          }
          return
        }
        do {
          guard let url else { throw error ?? Self.invalidResource() }
          // Provider URLs expire when their callback returns.
          let output = target.appendingPathComponent(url.lastPathComponent)
          try FileManager.default.copyItem(at: url, to: output)
          try Data("{}".utf8).write(to: target.appendingPathComponent(".complete"), options: .atomic)
          continuation.resume(returning: SharedAttachment(path: output.absoluteString, type: type))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  private func redirectToHost() {
    guard let bundle = Bundle.main.bundleIdentifier,
          let dot = bundle.lastIndex(of: ".") else { return }
    let host = String(bundle[..<dot])
    guard let url = URL(string: "ShareMedia-\(host)://\(host)?key=ShareKey") else { return }
    // Preserve share_handler's existing responder redirect; the host-launch
    // behaviour must be accepted on real iOS versions, including a cold launch.
    var responder: UIResponder? = self
    let selector = NSSelectorFromString("openURL:")
    while let current = responder {
      if current.responds(to: selector) { _ = current.perform(selector, with: url); return }
      responder = current.next
    }
  }

  private func finish(error: Error? = nil) {
    guard !completed else { return }
    completed = true
    if let error { extensionContext?.cancelRequest(withError: error) }
    else { extensionContext?.completeRequest(returningItems: nil) }
  }

  private static func invalidResource() -> Error { NSError(domain: "GalleryShare", code: 1) }
}
