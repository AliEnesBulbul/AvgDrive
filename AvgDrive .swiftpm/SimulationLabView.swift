import SwiftUI
import CoreLocation
import Observation

@MainActor
@Observable
final class DeskLocationSimulator {
    private(set) var isRunning: Bool = false
    var simulatedSpeedKmh: Double = 85
    
    private var simulationTask: Task<Void, Never>?
    private var traveledMeters: Double = 0
    
    func start(zone: EDSZone, onTick: @escaping (CLLocation) -> Void) {
        stop()
        isRunning = true
        traveledMeters = 0
        
        simulationTask = Task { @MainActor in
            while isRunning && !Task.isCancelled {
                let speedMps = max(0, simulatedSpeedKmh / 3.6)
                let progress = min(1.0, traveledMeters / max(1.0, zone.corridorDistanceMeters))
                
                let lat = zone.entryLatitude + (zone.exitLatitude - zone.entryLatitude) * progress
                let lon = zone.entryLongitude + (zone.exitLongitude - zone.entryLongitude) * progress
                
                let simulatedLocation = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: 1050,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5,
                    course: 0,
                    speed: speedMps,
                    timestamp: Date()
                )
                
                onTick(simulatedLocation)
                traveledMeters += speedMps
                
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    
    func stop() {
        isRunning = false
        simulationTask?.cancel()
        simulationTask = nil
    }
}

struct SimulationLabView: View {
    @Environment(\.dismiss) private var dismiss
    
    var savedZones: [EDSZone]
    var voiceCoach: VoiceCoach
    
    @State private var simulator = DeskLocationSimulator()
    @State private var testManager = SpeedCorridorManager()
    
    private var activeTestZone: EDSZone {
        savedZones.first ?? EDSZone(
            name: "Test Koridoru (1 km)",
            entryLatitude: 38.7312,
            entryLongitude: 35.4787,
            exitLatitude: 38.7402,
            exitLongitude: 35.4787,
            corridorDistanceMeters: 1000,
            speedLimitKmh: 82
        )
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("Test Koridoru") {
                    Text(activeTestZone.name)
                        .font(.headline)
                    HStack {
                        Text("Mesafe: \(Int(activeTestZone.corridorDistanceMeters)) m")
                        Spacer()
                        Text("Sınır: \(Int(activeTestZone.speedLimitKmh)) km/sa")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    
                    Toggle("%10 Tolerans", isOn: $testManager.useTenPercentTolerance)
                }
                
                Section("Canlı Simülasyon Verisi") {
                    HStack {
                        Text("Durum")
                        Spacer()
                        Text(guidanceText)
                            .bold()
                    }
                    HStack {
                        Text("Anlık Hız")
                        Spacer()
                        Text("\(Int(testManager.currentSpeedKmh.rounded())) km/sa")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Ortalama Hız")
                        Spacer()
                        Text(testManager.activeSession != nil ? "\(Int((testManager.activeSession?.averageSpeedKmh ?? 0).rounded())) km/sa" : "--")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Hedef Hız")
                        Spacer()
                        Text(testManager.activeSession != nil ? "\(Int((testManager.activeSession?.recommendedSpeedKmh ?? 0).rounded())) km/sa" : "--")
                            .monospacedDigit()
                    }
                    if let session = testManager.activeSession {
                        ProgressView(value: session.progress)
                        Text("Katedilen: \(Int(session.traveledDistanceMeters)) m / Kalan: \(Int(session.remainingDistanceMeters)) m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Hız Kontrolü") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Simüle Hız")
                            Spacer()
                            Text("\(Int(simulator.simulatedSpeedKmh)) km/sa")
                                .bold()
                                .monospacedDigit()
                        }
                        Slider(value: $simulator.simulatedSpeedKmh, in: 30...150, step: 1)
                    }
                    
                    HStack(spacing: 12) {
                        if !simulator.isRunning {
                            Button {
                                startSimulation()
                            } label: {
                                Label("Simülasyonu Başlat", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(role: .destructive) {
                                stopSimulation()
                            } label: {
                                Label("Durdur", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Masa Başı Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") {
                        stopSimulation()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                stopSimulation()
            }
            .onChange(of: testManager.activeSession?.zone.id) { oldID, newID in
                if oldID == nil, let zone = testManager.activeSession?.zone {
                    voiceCoach.announceZoneEntry(zone: zone)
                }
            }
            .onChange(of: testManager.guidance) { _, newGuidance in
                voiceCoach.handleGuidance(newGuidance)
            }
            .onChange(of: testManager.lastCompletedSummary?.id) { _, _ in
                if let summary = testManager.lastCompletedSummary {
                    voiceCoach.announceZoneExit(summary: summary)
                    simulator.stop()
                }
            }
        }
    }
    
    private var guidanceText: String {
        switch testManager.guidance {
        case .idle: return "Beklemede"
        case .maintain: return "Hızın Uygun"
        case .slowDown(let target): return "Yavaşla (\(Int(target.rounded())))"
        case .speedUp(let target): return "Hızlan (\(Int(target.rounded())))"
        }
    }
    
    private func startSimulation() {
        let zone = activeTestZone
        testManager.resetSession()
        testManager.zones = [zone]
        voiceCoach.reset()
        
        simulator.start(zone: zone) { location in
            testManager.processLocation(location)
        }
    }
    
    private func stopSimulation() {
        simulator.stop()
        testManager.resetSession()
        voiceCoach.stopSpeaking()
        voiceCoach.reset()
    }
}

