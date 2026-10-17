import BackgroundTasks

class BackgroundWorkerApiImpl: BackgroundWorkerFgHostApi {

  func enable() throws {
    BackgroundWorkerApiImpl.scheduleRefreshWorker()
    BackgroundWorkerApiImpl.scheduleProcessingWorker()
    print("BackgroundWorkerApiImpl:enable Background worker scheduled")
  }
  
  func configure(settings: BackgroundWorkerSettings) throws {
    // Android only
  }
  
  func saveNotificationMessage(title: String, body: String) throws {
    // Android only
  }
  
  func disable() throws {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundWorkerApiImpl.refreshTaskID);
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundWorkerApiImpl.processingTaskID);
    print("BackgroundWorkerApiImpl:disableUploadWorker Disabled background workers")
  }
  
  // Same intent as upstream #30574 (derive the BGTaskScheduler ids from Info.plist rather than
  // hard-coding them), but keep the fork's non-crashing form from #627: upstream force-unwraps
  // both the plist lookup (`as!`) and the suffix match (`!`), which traps at launch if the key is
  // missing or carries no matching id. The fork ships branded identifiers, so it must degrade to
  // the literals instead of crashing.
  private static let permittedTaskIDs =
    Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
  private static let refreshTaskID =
    permittedTaskIDs.first { $0.hasSuffix(".refreshUpload") } ?? "app.alextran.immich.background.refreshUpload"
  private static let processingTaskID =
    permittedTaskIDs.first { $0.hasSuffix(".processingUpload") } ?? "app.alextran.immich.background.processingUpload"
  private static let taskLock = NSLock()
  private static var taskRunning = false

  private static func reserveTask() -> Bool {
    taskLock.lock()
    defer { taskLock.unlock() }
    guard !taskRunning else { return false }
    taskRunning = true
    return true
  }

  private static func releaseTask() {
    taskLock.lock()
    taskRunning = false
    taskLock.unlock()
  }

  public static func registerBackgroundWorkers() {
      BGTaskScheduler.shared.register(
          forTaskWithIdentifier: processingTaskID, using: nil) { task in
          if task is BGProcessingTask {
            handleBackgroundProcessing(task: task as! BGProcessingTask)
          }
      }

      BGTaskScheduler.shared.register(
          forTaskWithIdentifier: refreshTaskID, using: nil) { task in
          if task is BGAppRefreshTask {
            handleBackgroundRefresh(task: task as! BGAppRefreshTask)
          }
      }
  }
  
  private static func scheduleRefreshWorker() {
    let backgroundRefresh = BGAppRefreshTaskRequest(identifier: refreshTaskID)
      backgroundRefresh.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // 5 mins

      do {
          try BGTaskScheduler.shared.submit(backgroundRefresh)
      } catch {
          print("Could not schedule the refresh upload task \(error.localizedDescription)")
      }
  }

  private static func scheduleProcessingWorker() {
    let backgroundProcessing = BGProcessingTaskRequest(identifier: processingTaskID)
    
    backgroundProcessing.requiresNetworkConnectivity = true
    backgroundProcessing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 mins
    
    do {
        try BGTaskScheduler.shared.submit(backgroundProcessing)
    } catch {
        print("Could not schedule the processing upload task \(error.localizedDescription)")
    }
  }
  
  private static func handleBackgroundRefresh(task: BGAppRefreshTask) {
    scheduleRefreshWorker()
    // If another task is running, cede the background time back to the OS
    if reserveTask() {
      // Restrict the refresh task to run only for a maximum of (maxSeconds) seconds
      runBackgroundWorker(task: task, taskType: .refresh, maxSeconds: 20)
    } else {
      task.setTaskCompleted(success: false)
    }
  }
  
  private static func handleBackgroundProcessing(task: BGProcessingTask) {
    scheduleProcessingWorker()
    guard reserveTask() else {
      task.setTaskCompleted(success: false)
      return
    }
    // Processing tasks are still subject to expiration by the OS.
    runBackgroundWorker(task: task, taskType: .processing, maxSeconds: nil)
  }
  
  /**
   * Executes the background worker within the context of a background task.
   * This method creates a BackgroundWorker, sets up task expiration handling,
   * and manages the synchronization between the background task and the Flutter engine.
   *
   * - Parameters:
   *   - task: The iOS background task that provides the execution context
   *   - taskType: The type of background operation to perform (refresh or processing)
   *   - maxSeconds: Optional timeout for the operation in seconds
   */
  private static func runBackgroundWorker(task: BGTask, taskType: BackgroundTaskType, maxSeconds: Int?) {
    // No blocking semaphore or forced 2-second completion: the reservation
    // remains held until Dart acknowledged cancellation and drained.
    DispatchQueue.main.async {
      let worker = BackgroundWorker(taskType: taskType, maxSeconds: maxSeconds) { success in
        task.expirationHandler = nil
        releaseTask()
        task.setTaskCompleted(success: success)
        print("Background task completed with success: \(success)")
      }
      task.expirationHandler = {
        DispatchQueue.main.async { worker.requestCancellation() }
      }
      worker.run()
    }
  }
}
