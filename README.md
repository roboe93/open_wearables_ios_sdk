# OpenWearablesHealthSDK

Native iOS SDK for secure background health data synchronization from Apple HealthKit to the Open Wearables platform.

## Features

- Streaming sync with memory-efficient processing
- Resumable sync sessions (survives app restarts)
- Dual authentication: token-based (with auto-refresh) or API key
- Background execution via HealthKit observer queries and BGTaskScheduler
- Automatic retry with persistent outbox
- Per-user state isolation
- Network and device lock monitoring

## Requirements

- iOS 14.0+
- Swift 5.0+
- HealthKit entitlement

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/the-momentum/OpenWearablesHealthSDK.git", from: "0.1.0")
]
```

Or in Xcode: File > Add Package Dependencies > paste the repository URL.

### CocoaPods

```ruby
pod 'OpenWearablesHealthSDK', '~> 0.1.0'
```

## Usage

```swift
import OpenWearablesHealthSDK

let sdk = OpenWearablesHealthSDK.shared

// Logging
sdk.onLog = { message in
    print("[Health] \(message)")
}

// Auth error handling
sdk.onAuthError = { statusCode, message in
    print("Auth error: \(statusCode) - \(message)")
}

// Configure
sdk.configure(host: "https://api.example.com")

// Sign in (token-based)
sdk.signIn(
    userId: "user123",
    accessToken: "access_token",
    refreshToken: "refresh_token",
    apiKey: nil
)

// Or sign in (API key)
sdk.signIn(
    userId: "user123",
    accessToken: nil,
    refreshToken: nil,
    apiKey: "your_api_key"
)

// Request HealthKit authorization
sdk.requestAuthorization(types: [.steps, .heartRate, .sleep]) { granted in
    if granted {
        // Start background sync
        sdk.startBackgroundSync { started in
            print("Sync started: \(started)")
        }
    }
}

// Stop sync
sdk.stopBackgroundSync()

// Sign out. Reports the disconnect to the backend, then clears all local state.
// The report is best effort and never blocks or fails the sign out.
sdk.signOut()
```

## AppDelegate Setup

Only needed when upgrading from a version before 0.14, so outbox items left on disk
by the old upload path can finish draining on the background session. Sync uploads
run on the foreground session and an interrupted round is rebuilt from HealthKit, so
a fresh install never reaches this callback. Harmless to keep either way:

```swift
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    OpenWearablesHealthSDK.setBackgroundCompletionHandler(completionHandler)
}
```

## Info.plist

Add required background modes and HealthKit usage descriptions:

```xml
<key>NSHealthShareUsageDescription</key>
<string>We need access to your health data to sync it with the platform.</string>
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.openwearables.healthsdk.task.refresh</string>
    <string>com.openwearables.healthsdk.task.process</string>
</array>
```

## License

MIT
