import BackgroundTasks
import Flutter

enum BackgroundTaskType { case refresh, processing }

/*
 * DEBUG: Testing Background Tasks in Xcode
 * 
 * To test background task functionality during development:
 * 1. Pause the application in Xcode debugger
 * 2. In the debugger console, enter one of the following commands:
 
 ## For background refresh (short-running sync):
 
 e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.alextran.immich.background.refreshUpload"]
 
 ## For background processing (long-running upload):
 
 e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.alextran.immich.background.processingUpload"]

 * To simulate task expiration (useful for testing expiration handlers):
 
 e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"app.alextran.immich.background.refreshUpload"]
 
 e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"app.alextran.immich.background.processingUpload"]
 
 * 3. Resume the application to see the background code execute
 * 
 * NOTE: This must be tested on a physical device, not in the simulator.
 * In testing, only the background processing task can be reliably simulated.
 * These commands submit the respective task to BGTaskScheduler for immediate processing.
 * Use the expiration commands to test how the app handles iOS terminating background tasks.
 */


/// The background worker which creates a new Flutter VM, communicates with it
/// to run the backup job, and then finishes execution and calls back to its callback handler.
/// This class manages a separate Flutter engine instance for background execution,
/// independent of the main UI Flutter engine.
class BackgroundWorker: BackgroundWorkerBgHostApi {
  private let taskType: BackgroundTaskType
  private let maxSeconds: Int?
  private let completionHandler: (_ success: Bool) -> Void
  private let engine = FlutterEngine(name: "BackgroundImmich")
  private var flutterApi: BackgroundWorkerFlutterApi?
  private var timeoutTimer: Timer?
  private var isComplete = false
  private var isInitialized = false
  private var cancellationRequested = false
  private var cancellationSent = false
  private var pendingReplies = 0
  private var drained = false
  private var succeeded = false

  init(taskType: BackgroundTaskType, maxSeconds: Int?, completionHandler: @escaping (_ success: Bool) -> Void) {
    self.taskType = taskType
    self.maxSeconds = maxSeconds
    self.completionHandler = completionHandler
  }

  func run() {
    guard !isComplete else { return }
    let isRunning = engine.run(
      withEntrypoint: "backgroundSyncNativeEntrypoint",
      libraryURI: "package:immich_mobile/domain/services/background_worker.service.dart"
    )
    guard isRunning else {
      complete(success: false)
      return
    }
    GeneratedPluginRegistrant.register(with: engine)
    AppDelegate.registerPlugins(with: engine, messenger: engine.binaryMessenger)
    flutterApi = BackgroundWorkerFlutterApi(binaryMessenger: engine.binaryMessenger)
    BackgroundWorkerBgHostApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: self)
    if let maxSeconds {
      timeoutTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(maxSeconds), repeats: false) { [weak self] _ in
        self?.requestCancellation()
      }
    }
  }

  func onInitialized() throws {
    guard !isComplete, !isInitialized else { return }
    isInitialized = true
    if cancellationRequested {
      sendCancellation()
      return
    }
    guard let flutterApi else { return }
    pendingReplies += 1
    flutterApi.onIosUpload(isRefresh: taskType == .refresh, maxSeconds: maxSeconds.map { Int64($0) }) { [weak self] result in
      guard let self, !self.isComplete else { return }
      self.pendingReplies -= 1
      switch result {
      case .success(let success):
        // Dart replies only after sync/hash/queuing/callback owners and DB drain.
        self.drained = true
        self.succeeded = success
      case .failure:
        self.succeeded = false
        self.cancellationRequested = true
        self.sendCancellation()
      }
      self.completeIfDrained()
    }
  }

  /// Host close acknowledges failed bootstrap/initialization has already
  /// drained. It is distinct from an OS expiration request during bootstrap.
  func close() {
    guard !isComplete else { return }
    cancellationRequested = true
    drained = true
    // Let Pigeon's host reply leave the messenger before destroying context.
    DispatchQueue.main.async { [weak self] in self?.completeIfDrained() }
  }

  /// Expiration/timeout requests cancellation, including while Dart initializes.
  /// Never destroy the engine just because a grace timer elapsed.
  func requestCancellation() {
    guard !isComplete else { return }
    cancellationRequested = true
    timeoutTimer?.invalidate()
    timeoutTimer = nil
    if isInitialized {
      sendCancellation()
    }
  }

  private func sendCancellation() {
    guard !isComplete, !cancellationSent, let flutterApi else { return }
    cancellationSent = true
    pendingReplies += 1
    flutterApi.cancel { [weak self] result in
      guard let self, !self.isComplete else { return }
      self.pendingReplies -= 1
      if case .success = result {
        self.drained = true
      }
      // A failed channel does not prove a running Dart owner has drained.
      self.completeIfDrained()
    }
  }

  private func completeIfDrained() {
    guard drained, pendingReplies == 0 else { return }
    complete(success: succeeded && !cancellationRequested)
  }

  private func complete(success: Bool) {
    guard !isComplete else { return }
    isComplete = true
    timeoutTimer?.invalidate()
    timeoutTimer = nil
    BackgroundWorkerBgHostApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: nil)
    AppDelegate.cancelPlugins(with: engine)
    flutterApi = nil
    engine.destroyContext()
    completionHandler(success)
  }
}
