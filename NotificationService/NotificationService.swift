//
// NotificationService.swift: shows PusherHub notification images on iOS.
//
// iOS never downloads a notification's picture by itself. An app has to ship a
// Notification Service Extension that fetches it before the notification is
// shown, and this file is that extension, ready to use. The campaign's Image
// URL (or its Icon URL, when there's no image) appears as a thumbnail on the
// notification, full size when the user long-presses it.
//
// Setup, once per app:
//   1. Xcode > File > New > Target... > Notification Service Extension.
//      Name it NotificationService, click Finish, then "Don't Activate".
//   2. Replace everything in the NotificationService.swift Xcode created with
//      this file.
//   3. Select the NotificationService target > General > Minimum Deployments
//      and set it to the same iOS version as your app. Xcode defaults new
//      targets to the newest iOS, and an iPhone running anything older
//      silently skips the extension.
//
// Flutter apps: do this in ios/Runner.xcworkspace, then drag the Runner
// target's "Embed Foundation Extensions" build phase above "Thin Binary",
// or the build fails with "Cycle inside Runner".
//
// Nothing else: no Firebase package, App Group or keys. PusherHub marks every
// push that has an image so iOS hands it here; pushes without one, or whose
// image can't be downloaded in time, show their text as usual.
//

import UniformTypeIdentifiers
import UserNotifications

nonisolated class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    // The download finishes on a URLSession queue while iOS may call
    // serviceExtensionTimeWillExpire() on another, so everything below is
    // only touched under the lock, and the notification is delivered once.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var download: URLSessionDownloadTask?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let imageURL = Self.imageURL(in: request.content.userInfo)
        else {
            contentHandler(request.content)
            return
        }

        let task = URLSession.shared.downloadTask(with: imageURL) { [self] file, response, _ in
            finish(attaching: file.flatMap { Self.attachment(from: $0, response: response, imageURL: imageURL) })
        }

        lock.lock()
        self.contentHandler = contentHandler
        self.content = content
        download = task
        lock.unlock()

        task.resume()
    }

    /// iOS gives the extension about 30 seconds. Past that, show the text
    /// without the image rather than risk iOS showing the bare push.
    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let task = download
        lock.unlock()

        task?.cancel()
        finish(attaching: nil)
    }

    private func finish(attaching attachment: UNNotificationAttachment?) {
        lock.lock()
        guard let contentHandler, let content else {
            lock.unlock()
            return
        }
        self.contentHandler = nil
        if let attachment {
            content.attachments = [attachment]
        }
        lock.unlock()

        contentHandler(content)
    }

    /// The image PusherHub sent: FCM delivers it to iOS as fcm_options.image.
    private static func imageURL(in userInfo: [AnyHashable: Any]) -> URL? {
        guard let options = userInfo["fcm_options"] as? [String: Any],
              let string = options["image"] as? String,
              let url = URL(string: string),
              url.scheme == "https" || url.scheme == "http"
        else {
            return nil
        }
        return url
    }

    /// iOS only accepts a file whose name says what kind it is, and deletes
    /// the downloaded one as soon as the download's handler returns, so the
    /// image is moved to a name of its own first. Anything iOS can't show
    /// (an error page, a file over 10 MB) comes back nil: text only.
    private static func attachment(from file: URL, response: URLResponse?, imageURL: URL) -> UNNotificationAttachment? {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }

        let fileExtension = response?.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? (imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        do {
            try FileManager.default.moveItem(at: file, to: destination)
            return try UNNotificationAttachment(identifier: "image", url: destination)
        } catch {
            return nil
        }
    }
}
