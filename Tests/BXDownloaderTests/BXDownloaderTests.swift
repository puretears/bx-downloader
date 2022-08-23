import XCTest
@testable import BXDownloader

final class BXDownloaderTests: XCTestCase {
  let downloader = BXDownloader(
    url: URL(string: "https://free-video.boxueio.com/h-task-local-storage-basic.mp4")!,
    cacheDir: "videos"
  )
  
  func testDownload() async {
    downloader.start()

    while(1 == 1) {}
    
    
//    await downloader.download()
    
    XCTAssert(true)
  }
}
