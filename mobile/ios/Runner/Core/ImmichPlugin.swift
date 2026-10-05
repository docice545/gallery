import Foundation

class ImmichPlugin: NSObject {
  var detached: Bool
  
  override init() {
    detached = false
    super.init()
  }
  
  func detachFromEngine() {
    // Engine teardown and result delivery share the main queue. Invalidate
    // delivery before a caller proceeds to destroy the Flutter context.
    if Thread.isMainThread {
      detached = true
    } else {
      DispatchQueue.main.sync { self.detached = true }
    }
  }
  
  func completeWhenActive<T>(for completion: @escaping (T) -> Void, with value: T) {
    let deliver = { [weak self] in
      // Check at delivery time, not on a background task before it queues a
      // callback that might otherwise outlive engine destruction.
      guard let self, !self.detached else { return }
      completion(value)
    }
    if Thread.isMainThread {
      deliver()
    } else {
      DispatchQueue.main.async(execute: deliver)
    }
  }
}
