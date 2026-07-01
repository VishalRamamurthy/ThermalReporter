import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct ThermalReporterApp: App {
    init() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.thermalreporter.refresh",
            using: nil
        ) { task in
            handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: ThermalSample.self)
    }
}

func handleBackgroundRefresh(task: BGAppRefreshTask) {
    // Immediately reschedule for next opportunity
    scheduleBackgroundRefresh()

    let container = try! ModelContainer(for: ThermalSample.self)
    let context = ModelContext(container)

    Task { @MainActor in
        let monitor = ThermalMonitor(modelContext: context)
        monitor.isInBackground = true

        // Capture one sample immediately
        monitor.captureOneSample()

        // Give iOS a few seconds to settle, then capture one more and finish
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        monitor.captureOneSample()
        monitor.stopMonitoring()

        task.setTaskCompleted(success: true)
    }

    // Safety expiration handler in case iOS cuts us short
    task.expirationHandler = {
        task.setTaskCompleted(success: false)
    }
}

func scheduleBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: "com.thermalreporter.refresh")
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // iOS minimum is ~15 min
    try? BGTaskScheduler.shared.submit(request)
}
