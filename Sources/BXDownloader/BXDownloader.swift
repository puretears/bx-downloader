import Combine
import Foundation

struct CacheRecord {
  let filename: String
  let cacheUrl: URL
}

public enum DownloadStatus {
  case notStarted
  case downloading(progress: Double)
  case pause(progress: Double, filename: String, tmpUrl: URL)
  case failed
  case cancelled
  case finished
}

public class BXDownloader: NSObject {
  var statusSubject = CurrentValueSubject<DownloadStatus, Never>(.notStarted)
  public var statusPublisher: AnyPublisher<DownloadStatus, Never> {
    statusSubject.receive(on: RunLoop.main).eraseToAnyPublisher()
  }
  
  var progressSubject = CurrentValueSubject<Double, Never>(0)
  public var progressPub: AnyPublisher<Double, Never> {
    progressSubject.receive(on: RunLoop.main).eraseToAnyPublisher()
  }
  
  var downloadUrl: URL
  var savedUrl: URL? = nil // Cache to savedUrl if not nil
  var tmpUrl: URL? = nil   // Save resume data to recover download
  
  lazy var urlSession = URLSession(
    configuration: .default, delegate: self, delegateQueue: nil)
  var manager = FileManager.default
  
  var resumeData: Data? = nil
  var downloadTask: URLSessionDownloadTask? = nil
  
  public init(url: URL, cacheDir: String? = nil) {
    downloadUrl = url
    super.init()
    
    if let cacheDir = cacheDir {
      setUrls(cacheDir: cacheDir, filename: url.lastPathComponent)
    }
  }
  
  public func start() {
    let t = urlSession.downloadTask(with: downloadUrl)
    t.resume()
    
    statusSubject.send(.downloading(progress: progressSubject.value))
    downloadTask = t
  }
  
  public func cancel() {
    downloadTask?.cancel()
    
    clearCache()
    
    progressSubject.send(0)
    statusSubject.send(.cancelled)
  }
  
  public func pause() {
    downloadTask?.cancel(byProducingResumeData: { resumeDataOrNil in
      guard let rData = resumeDataOrNil, let tmpUrl = self.tmpUrl else {
        // No resumable data
        return
      }
      
      do {
        self.resumeData = rData
        try self.resumeData!.write(to: tmpUrl)
        
        self.statusSubject.send(
          .pause(progress: self.progressSubject.value,
                 filename: self.downloadUrl.lastPathComponent,
                 tmpUrl: tmpUrl)
        )
        
        #if DEBUG
        print("Downloading paused. Temporary file was saved to \(String(describing: tmpUrl))")
        #endif
      }
      catch {
        self.resumeData = nil
      }
    })
  }
  
  public func resume() {
    guard loadResumeFile(), let resumeData = resumeData else {
      // No resumable data
      return
    }
    
    let t = urlSession.downloadTask(withResumeData: resumeData)
    t.resume()
    self.downloadTask = t
    
    statusSubject.send(.downloading(progress: progressSubject.value))
  }
}

extension BXDownloader: URLSessionDelegate {
  /// 3. Handle client side error.
  /// If the download completes successfully, this method is called
  /// after `didFinishDownloadingTo` and the `error` is `nil`.
  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?) {
    guard let error = error else {
      statusSubject.send(.finished)
      return // Download finished successfully
    }
    
    let userInfo = (error as NSError).userInfo
    if let rData = userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
      resumeData = rData
      
      return
    }
      
    // TODO: Handle other errors.
    clearCache()
    statusSubject.send(.failed)
    return
  }
}

extension BXDownloader: URLSessionDownloadDelegate  {
  // 1. Receive update
  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64) {
    let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
#if DEBUG
print("Receive download progress update: \(p)")
#endif
      progressSubject.send(p)
  }
  
  // 2. Receive finish notification
  public func urlSession(_ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL) {
    if let resp = downloadTask.response as? HTTPURLResponse,
      !(200..<299).contains(resp.statusCode) {
      statusSubject.send(.failed)
    }
    
#if DEBUG
    print("\(location.lastPathComponent) download finished.")
#endif
    if let savedUrl = savedUrl {
      do {
        if manager.fileExists(atPath: savedUrl.relativePath) {
          try manager.removeItem(at: savedUrl)
        }
        
        try manager.moveItem(at: location, to: savedUrl)
#if DEBUG
        print("\(location.lastPathComponent) cached to \(savedUrl.relativePath).")
#endif
      }
      catch {
        // Cannot save filed to caching folder.
        #if DEBUG
        print(error)
        #endif
        statusSubject.send(.failed)
      }
    }
  }
}

extension BXDownloader {
  private func setUrls(cacheDir: String, filename: String) {
    // Create the cache directory automatically if it does not exist.
    do {
      let rootFolderURL = try manager.url(
        for: .documentDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
      )
      
      let cacheFolderURL = rootFolderURL.appendingPathComponent(cacheDir)
      if !manager.fileExists(atPath: cacheFolderURL.relativePath) {
        #if DEBUG
        print("\(cacheFolderURL.relativePath) doesn't exist. Create it for caching.")
        #endif
        try manager.createDirectory(
          at: cacheFolderURL, withIntermediateDirectories: false, attributes: nil
        )
      }
      
      let tmpFolderURL = rootFolderURL.appendingPathComponent("tmp")
      if !manager.fileExists(atPath: tmpFolderURL.relativePath) {
        #if DEBUG
        print("\(tmpFolderURL.relativePath) doesn't exist. Create it for storing resume files.")
        #endif
        try manager.createDirectory(
          at: tmpFolderURL, withIntermediateDirectories: false, attributes: nil
        )
      }
      
      if #available(iOS 16.0, macOS 13.0, *) {
        savedUrl = cacheFolderURL.appending(path: downloadUrl.lastPathComponent)
        tmpUrl = tmpFolderURL.appending(path: "\(downloadUrl.lastPathComponent).resume")
      } else {
        savedUrl = cacheFolderURL.appendingPathComponent(downloadUrl.lastPathComponent)
        tmpUrl = tmpFolderURL.appendingPathComponent("\(downloadUrl.lastPathComponent).resume")
      }
    }
    catch {
      // If we cannot create the cache directory, just ignore it and nothing will be cached.
      savedUrl = nil
      tmpUrl = nil
    }
  }
  
  private func loadResumeFile() -> Bool {
    if tmpUrl == nil { return false }
    if resumeData != nil { return true }
    
    do {
      let data = try Data(contentsOf: tmpUrl!)
      resumeData = data
      return true
    }
    catch {
      resumeData = nil
      return false
    }
  }
  
  private func clearCache() {
    // Delete the resume file if users cancel the download directly.
    resumeData = nil
    if let tmpUrl = tmpUrl, manager.fileExists(atPath: tmpUrl.relativePath) {
      try? manager.removeItem(at: tmpUrl)
    }
  }
}
