# PusherHub iOS SDK (Swift)

Push notifications and in-app messages for your iPhone app, sent through your own Firebase project with [PusherHub](https://pusherhub.com).

[Website](https://pusherhub.com) · [Guides](https://pusherhub.com/docs) · [Pricing](https://pusherhub.com/pricing)

## What it does

- Registers each iPhone with PusherHub, asks for the notification permission, and keeps its token up to date
- Links a phone to your own user id with `login(externalId:)` — remembered across restarts until `logout()`
- Reports notification opens and clicks
- Hands your app each tapped notification's Custom Data, so you can open the right screen
- Shows in-app messages in SwiftUI with `.pusherHubMessageHost()`
- Images in notifications, with the included Notification Service Extension
- Optional device details, and GPS-accurate state and city if you turn location on

| File | What it's for |
|---|---|
| [`PusherHub.swift`](PusherHub.swift) | The SDK — add it to your app target |
| [`NotificationService/NotificationService.swift`](NotificationService/NotificationService.swift) | Optional — shows images in notifications |

## Before you start

1. A PusherHub account with your app added — it's free to start at [pusherhub.com](https://pusherhub.com).
2. Your app added to a Firebase project (`GoogleService-Info.plist` in your app target), your APNs key (.p8) uploaded to Firebase, and the Firebase service account key uploaded to your app in PusherHub. See the [Apple push guide](https://pusherhub.com/docs/ios-apns) and the [getting-started guide](https://pusherhub.com/docs/getting-started).
3. Your **app key** and **public key** — on your app's **SDK Integration** tab in PusherHub, which also shows every step below with your keys filled in.

## Install

1. **Firebase:** in Xcode, *File › Add Package Dependencies…*
   `https://github.com/firebase/firebase-ios-sdk` — *Up to Next Major Version* from `12.0.0`.
   Add **FirebaseCore** and **FirebaseMessaging** to your app target.
2. **Push:** your app target › *Signing & Capabilities* › *+ Capability* › **Push Notifications** (needs a paid Apple Developer team).
3. Add [`PusherHub.swift`](PusherHub.swift) to your app target.

## Quick start

`AppDelegate.swift`:

```swift
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PusherHub.initialize(
            appKey: "YOUR_APP_KEY",
            publicKey: "YOUR_PUBLIC_KEY",
            baseUrl: "https://pusherhub.com/api"
        )

        // Required: registers this iPhone. Optional details once that's done.
        PusherHub.registerDevice {
            PusherHub.collectDeviceMetadata()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PusherHub.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PusherHub.didFailToRegisterForRemoteNotifications(error: error)
    }
}
```

Your SwiftUI app:

```swift
import SwiftUI

@main
struct YourApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Optional: shows in-app messages.
                .pusherHubMessageHost()
        }
    }
}
```

## Images in notifications (recommended)

1. Xcode › *File › New › Target…* › **Notification Service Extension**, named `NotificationService`.
2. Set its minimum iOS version to match your app.
3. Replace the generated `NotificationService.swift` with [this one](NotificationService/NotificationService.swift).

## Opening a screen when a notification is tapped

Put your own data in **Custom Data** when you create a notification — say `{"campaign_id": "232"}` — and get it back on every tap, whether the app was open, in the background or closed.

```swift
@MainActor final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()
    @Published var campaignId: String?   // open the campaign from your views when this changes
}

PusherHub.initialize(
    appKey: "YOUR_APP_KEY",
    publicKey: "YOUR_PUBLIC_KEY",
    baseUrl: "https://pusherhub.com/api",
    onNotificationOpened: { data in
        NotificationRouter.shared.campaignId = data["campaign_id"]
    }
)
```

Every value arrives as text (`"232"`). A tap that opened a closed app can arrive before your first view is up, so set something your views watch rather than presenting a screen here.

## Signed-in users

```swift
PusherHub.login(externalId: currentUserId)   // when someone signs in
PusherHub.logout()                           // when they sign out
```

## Keys

The **public key** is meant to be built into your app. Never put your **secret key** in an app — it's only for your own server, with PusherHub's REST API.

## Help

- Step-by-step guides: [pusherhub.com/docs](https://pusherhub.com/docs)
- Your app's **SDK Integration** tab in PusherHub has every step with your keys filled in.

## License

[MIT](LICENSE)
