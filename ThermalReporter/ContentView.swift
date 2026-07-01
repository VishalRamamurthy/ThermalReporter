import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ThermalSample.timestamp, order: .forward)
    private var samples: [ThermalSample]

    @State private var monitor: ThermalMonitor?
    @State private var isMonitoring = false
    @State private var showDocumentPicker = false
    @State private var csvURL: URL?
    @State private var shareURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // MARK: Current Status Card
                    statusCard

                    // MARK: Control Buttons
                    controlButtons

                    // MARK: Charts (only shown once data exists)
                    if !samples.isEmpty {
                        chartSection("Brightness Over Time", color: .blue) { sample in
                            // Don't plot background samples (brightness == -1)
                            sample.brightness >= 0 ? Double(sample.brightness) : nil
                        }

                        thermalStateChart

                        chartSection("Battery Level Over Time", color: .green) { sample in
                            Double(sample.batteryLevel)
                        }
                    } else {
                        Text("No data yet. Tap Start Monitoring to begin.")
                            .foregroundColor(.secondary)
                            .padding()
                    }

                    // MARK: Export CSV Button
                    if !samples.isEmpty {
                        Button {
                            let csv = generateCSV(from: samples)
                            if let url = saveCSVToTemp(csvString: csv) {
                                csvURL = url
                                showDocumentPicker = true
                            }
                        } label: {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }

                    // MARK: Recent Samples List
                    recentSamplesList

                }
                .padding()
            }
            .navigationTitle("Thermal Reporter")
            .sheet(isPresented: $showShareSheet) {
                if let url = shareURL {
                    ShareSheet(url: url)
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                if let url = csvURL {
                    DocumentPicker(url: url)
                }
            }
            // MARK: Foreground / Background observers
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                monitor?.isInBackground = true
                monitor?.beginBackgroundTask()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                monitor?.isInBackground = false
                monitor?.endBackgroundTask()
                monitor?.captureOneSample() // capture immediately on return to foreground
            }
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(spacing: 6) {
            Text("Current Thermal State")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(monitor?.currentThermalText ?? "Not monitoring")
                .font(.system(size: 36, weight: .bold))
                .foregroundColor(thermalColor(monitor?.currentThermalText ?? ""))
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: - Control Buttons

    private var controlButtons: some View {
        HStack(spacing: 16) {
            Button {
                if monitor == nil {
                    monitor = ThermalMonitor(modelContext: modelContext)
                }
                monitor?.startMonitoring()
                isMonitoring = true
                scheduleBackgroundRefresh()
            } label: {
                Label(isMonitoring ? "Monitoring…" : "Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isMonitoring)

            Button {
                monitor?.stopMonitoring()
                isMonitoring = false
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!isMonitoring)
        }
    }

    // MARK: - Generic Line Chart

    private func chartSection(
        _ title: String,
        color: Color,
        value: @escaping (ThermalSample) -> Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Chart(samples) { sample in
                if let v = value(sample) {
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: TimeInterval(sample.timestamp))),
                        y: .value("Value", v)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 0...1)
            .frame(height: 200)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: - Thermal State Chart

    private var thermalStateChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thermal State Over Time").font(.headline)
            Chart(samples) { sample in
                LineMark(
                    x: .value("Time", Date(timeIntervalSince1970: TimeInterval(sample.timestamp))),
                    y: .value("Thermal", sample.thermalState)
                )
                .foregroundStyle(.orange)
                .interpolationMethod(.stepStart)
            }
            .chartYScale(domain: 0...3)
            .chartYAxis {
                AxisMarks(values: [0, 1, 2, 3]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            Text(thermalLabel(intVal))
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: - Recent Samples List

    private var recentSamplesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Samples (\(samples.count) total)")
                .font(.headline)

            ForEach(Array(samples.suffix(15).reversed())) { sample in
                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedDate(from: sample.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Label(thermalLabel(sample.thermalState), systemImage: "thermometer")
                            .foregroundColor(thermalColor(thermalLabel(sample.thermalState)))
                        Spacer()
                        Label(
                            batteryText(sample),
                            systemImage: sample.isCharging ? "battery.100.bolt" : "battery.75"
                        )
                    }
                    .font(.subheadline)

                    HStack {
                        if sample.brightness >= 0 {
                            Label(String(format: "Brightness %.0f%%", sample.brightness * 100),
                                  systemImage: "sun.max")
                        } else {
                            Label("Brightness N/A (background)", systemImage: "sun.max")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if sample.lowPowerMode {
                            Label("Low Power", systemImage: "tortoise.fill")
                                .foregroundColor(.yellow)
                        }
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(10)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: - CSV Export

    private func generateCSV(from samples: [ThermalSample]) -> String {
        var csv = "timestamp,thermalState,batteryLevel,isCharging,lowPowerMode,brightness\n"
        for s in samples {
            // -1 brightness exported as empty string to indicate background sample
            let brightnessStr = s.brightness >= 0 ? String(format: "%.4f", s.brightness) : ""
            csv += "\(s.timestamp),\(s.thermalState),\(String(format: "%.4f", s.batteryLevel)),"
            csv += "\(s.isCharging),\(s.lowPowerMode),\(brightnessStr)\n"
        }
        return csv
    }

    private func saveCSVToTemp(csvString: String) -> URL? {
        let name = "thermal_\(Int(Date().timeIntervalSince1970)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try csvString.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("❌ CSV temp write error:", error)
            return nil
        }
    }

    // MARK: - Helpers

    private func thermalColor(_ label: String) -> Color {
        switch label {
        case "nominal":  return .green
        case "fair":     return .yellow
        case "serious":  return .orange
        case "critical": return .red
        default:         return .secondary
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

    private func batteryText(_ sample: ThermalSample) -> String {
        let level = sample.batteryLevel
        guard level >= 0 else { return "N/A" }
        return String(format: "%.0f%%", level * 100) + (sample.isCharging ? " ⚡" : "")
    }

    private func formattedDate(from timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
