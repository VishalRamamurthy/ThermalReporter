import Foundation
import SwiftData
import UIKit
import UserNotifications
import Observation

@MainActor
@Observable
class ThermalMonitor {
    var currentThermalText: String = "unknown"
    var isInBackground: Bool = false

    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let modelContext: ModelContext
    private let notificationCenter = UNUserNotificationCenter.current()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        UIDevice.current.isBatteryMonitoringEnabled = true

        _ = ProcessInfo.processInfo.thermalState
        updateThermalText()

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateThermalText()
                self?.captureSample()
                self?.sendNotificationIfNeeded()
            }
        }

        // Request permission first, then send test notification on first install
        Task { @MainActor in
            await requestNotificationPermission()
        }
    }

    // MARK: - Start / Stop

    func startMonitoring() {
        captureSample()
        timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureSample()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        endBackgroundTask()
    }

    // MARK: - Background Task Management

    func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ThermalCapture") {
            Task { @MainActor [weak self] in
                self?.captureSample()
                self?.endBackgroundTask()
            }
        }
        print("🟡 Background task started: \(backgroundTaskID.rawValue)")
    }

    func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        print("🔴 Background task ended")
    }

    // MARK: - Single Sample Capture (used by BGAppRefreshTask)

    func captureOneSample() {
        captureSample()
    }

    // MARK: - Data Capture

    private func captureSample() {
        let device = UIDevice.current
        let state = ProcessInfo.processInfo.thermalState

        // Only capture brightness when in foreground — returns stale/zero in background
        let brightness: Float
        if isInBackground {
            brightness = -1.0 // sentinel value indicating background sample
        } else {
            brightness = Float(
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first?.screen.brightness ?? 0.0
            )
        }

        let sample = ThermalSample(
            timestamp: Int(Date().timeIntervalSince1970),
            thermalState: thermalStateInt(state),
            batteryLevel: max(0, device.batteryLevel),
            isCharging: device.batteryState == .charging || device.batteryState == .full,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            brightness: brightness
        )

        modelContext.insert(sample)

        do {
            try modelContext.save()
            let bgLabel = isInBackground ? "background" : "foreground"
            print("✅ Saved [\(bgLabel)] — time: \(sample.timestamp), thermal: \(sample.thermalState)")
        } catch {
            print("❌ Save failed:", error)
        }

        updateThermalText()
    }

    // MARK: - Notification Permission

    private func requestNotificationPermission() async {
        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            if granted {
                print("✅ Notification permission granted")
                sendFirstInstallNotificationIfNeeded()
            } else {
                print("⚠️ Notification permission denied")
            }
        } catch {
            print("❌ Notification permission error:", error)
        }
    }

    // MARK: - First Install Test Notification

    private func sendFirstInstallNotificationIfNeeded() {
        let key = "hasShownWelcomeNotification"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "🌡️ Thermal Reporter is ready"
        content.body = "Notifications are working! You'll be alerted when your device heats up."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(
            identifier: "welcome-notification",
            content: content,
            trigger: trigger
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("❌ Welcome notification error:", error)
            } else {
                print("✅ Welcome notification scheduled")
            }
        }
    }

    // MARK: - Thermal Notifications

    private func sendNotificationIfNeeded() {
        let state = ProcessInfo.processInfo.thermalState

        let title: String
        let body: String

        switch state {
        case .fair:
            title = "🌡️ Thermal Notice"
            body = "Your iPhone is running a little warm. Consider reducing screen brightness or closing unused apps."
        case .serious:
            title = "⚠️ Thermal Warning"
            body = "Your iPhone is running \(currentThermalText). Consider closing background apps."
        case .critical:
            title = "🚨 Critical Thermal Alert"
            body = "Your iPhone is critically overheating! Close all apps and let it cool down immediately."
        default:
            return // nominal — no notification needed
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "thermal-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        notificationCenter.add(request) { error in
            if let error = error {
                print("❌ Notification error:", error)
            }
        }
    }

    // MARK: - Helpers

    private func updateThermalText() {
        currentThermalText = thermalLabel(thermalStateInt(ProcessInfo.processInfo.thermalState))
    }

    private func thermalStateInt(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return -1
        }
    }

    private func thermalLabel(_ value: Int) -> String {
        switch value {
        case 0:  return "nominal"
        case 1:  return "fair"
        case 2:  return "serious"
        case 3:  return "critical"
        default: return "unknown"
        }
    }
}
