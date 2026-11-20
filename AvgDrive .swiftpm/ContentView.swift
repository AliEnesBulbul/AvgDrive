import SwiftUI
import CoreLocation
import UIKit

struct ContentView: View {
    @StateObject private var store = CorridorStore()
    @StateObject private var recorder = CorridorRecorder()
    @StateObject private var corridorManager = SpeedCorridorManager()
    @StateObject private var locationService = LocationService()
    @StateObject private var voiceCoach = VoiceCoach()
    
    @State private var latestLocation: CLLocation?
    @State private var showCorridorSheet: Bool = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    guidanceBanner
                    speedMetricsGrid
                    
                    if let session = corridorManager.activeSession {
                        activeCorridorCard(session: session)
                    }
                    
                    gpsControlsCard
                    
                    if let summary = corridorManager.lastCompletedSummary {
                        lastSummaryCard(summary: summary)
                    }
                }
                .padding()
            }
            .navigationTitle("AvgDrive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        voiceCoach.isEnabled.toggle()
                        if !voiceCoach.isEnabled {
                            voiceCoach.stopSpeaking()
                        }
                    } label: {
                        Image(systemName: voiceCoach.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .tint(voiceCoach.isEnabled ? .blue : .secondary)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCorridorSheet = true
                    } label: {
                        Label("Koridorlarım", systemImage: "map")
                    }
                }
            }
            .sheet(isPresented: $showCorridorSheet) {
                CorridorManagementView(
                    store: store,
                    recorder: recorder,
                    locationService: locationService,
                    voiceCoach: voiceCoach,
                    latestLocation: latestLocation
                )
            }
        }
        .onAppear {
            corridorManager.zones = store.zones
            
            locationService.onLocationUpdate = { location in
                latestLocation = location
                if recorder.isRecording {
                    recorder.appendLocation(location)
                }
                corridorManager.processLocation(location)
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: locationService.isTracking) { isTracking in
            UIApplication.shared.isIdleTimerDisabled = isTracking
        }
        .onChange(of: store.zones) { updatedZones in
            corridorManager.zones = updatedZones
        }
        .onChange(of: corridorManager.activeSession?.zone.id) { newID in
            if newID != nil, let zone = corridorManager.activeSession?.zone {
                voiceCoach.announceZoneEntry(zone: zone)
            }
        }
        .onChange(of: corridorManager.guidance) { newGuidance in
            voiceCoach.handleGuidance(newGuidance)
        }
        .onChange(of: corridorManager.lastCompletedSummary?.id) { _ in
            if let summary = corridorManager.lastCompletedSummary {
                voiceCoach.announceZoneExit(summary: summary)
            }
        }
    }
    
    // MARK: - Yönlendirme Bandı
    
    private var guidanceBanner: some View {
        let info = guidanceDisplayInfo
        
        return HStack(spacing: 12) {
            Image(systemName: info.icon)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.headline)
                Text(info.subtitle)
                    .font(.subheadline)
                    .opacity(0.9)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding()
        .background(info.color.gradient, in: RoundedRectangle(cornerRadius: 14))
    }
    
    private var guidanceDisplayInfo: (title: String, subtitle: String, color: Color, icon: String) {
        switch corridorManager.guidance {
        case .idle:
            return ("Koridor Bekleniyor", "Kayıtlı bir EDS girişine yaklaşınca başlar", .gray, "road.lanes")
        case .maintain:
            return ("Hızın Uygun", "Mevcut hızını koru", .green, "checkmark.circle.fill")
        case .slowDown(let target):
            return ("Yavaşla", "Hedef hız: \(Int(target.rounded())) km/sa", .red, "exclamationmark.triangle.fill")
        case .speedUp(let target):
            return ("Hızlanabilirsin", "Hedef hız: \(Int(target.rounded())) km/sa", .blue, "speedometer")
        }
    }
    
    // MARK: - Hız Kartları
    
    private var speedMetricsGrid: some View {
        let avgSpeed = corridorManager.activeSession?.averageSpeedKmh ?? 0
        let targetSpeed = corridorManager.activeSession?.recommendedSpeedKmh ?? 0
        let limitSpeed: Double = {
            guard let zone = corridorManager.activeSession?.zone else { return 0 }
            return corridorManager.effectiveSpeedLimitKmh(for: zone)
        }()
        
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricBox(
                title: "Anlık Hız",
                value: "\(Int(corridorManager.currentSpeedKmh.rounded()))",
                unit: "km/sa",
                tint: .primary
            )
            metricBox(
                title: "Ortalama Hız",
                value: corridorManager.activeSession != nil ? "\(Int(avgSpeed.rounded()))" : "--",
                unit: "km/sa",
                tint: avgSpeed > limitSpeed && limitSpeed > 0 ? .red : .primary
            )
            metricBox(
                title: "Hedef Hız",
                value: targetSpeed > 0 ? "\(Int(targetSpeed.rounded()))" : "--",
                unit: "km/sa",
                tint: .blue
            )
            metricBox(
                title: corridorManager.useTenPercentTolerance ? "Hız Sınırı (+%10)" : "Hız Sınırı",
                value: limitSpeed > 0 ? "\(Int(limitSpeed.rounded()))" : "--",
                unit: "km/sa",
                tint: .orange
            )
        }
    }
    
    private func metricBox(title: String, value: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    
    // MARK: - Aktif Koridor İlerleme Kartı
    
    private func activeCorridorCard(session: CorridorSession) -> some View {
        let effectiveLimit = corridorManager.effectiveSpeedLimitKmh(for: session.zone)
        
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(session.zone.name)
                    .font(.headline)
                Spacer()
                Text("\(Int(session.elapsedTimeSeconds)) sn")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            ProgressView(value: session.progress)
                .tint(session.averageSpeedKmh > effectiveLimit ? .red : .green)
            
            HStack {
                Text("Katedilen: \(Int(session.traveledDistanceMeters)) m")
                Spacer()
                Text("Kalan: \(Int(session.remainingDistanceMeters)) m")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    
    // MARK: - Gerçek GPS Kontrol Paneli
    
    private var gpsControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GPS Takibi")
                    .font(.headline)
                Spacer()
                gpsAccuracyBadge
            }
            
            Text("İzin Durumu: \(authorizationText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text("Kayıtlı Koridor Sayısı: \(store.zones.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Toggle("%10 Yasal Tolerans Uygula", isOn: $corridorManager.useTenPercentTolerance)
                .font(.subheadline)
            
            if let error = locationService.lastErrorMessage {
                Text("Hata: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            HStack(spacing: 12) {
                if !locationService.isTracking {
                    Button {
                        locationService.startTracking()
                    } label: {
                        Label("GPS Takibini Başlat", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(role: .destructive) {
                        stopAll()
                    } label: {
                        Label("Takibi Durdur", systemImage: "location.slash.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    
    @ViewBuilder
    private var gpsAccuracyBadge: some View {
        if let accuracy = latestLocation?.horizontalAccuracy, accuracy >= 0 {
            let color: Color = accuracy <= 10 ? .green : (accuracy <= 25 ? .orange : .red)
            Label("±\(Int(accuracy.rounded())) m", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption.bold().monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        } else if locationService.isTracking {
            Text("Sinyal aranıyor...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private var authorizationText: String {
        switch locationService.authorizationStatus {
        case .notDetermined: return "Henüz sorulmadı"
        case .restricted: return "Kısıtlı"
        case .denied: return "Reddedildi (Ayarlardan açılmalı)"
        case .authorizedWhenInUse: return "Uygulama Kullanılırken"
        case .authorizedAlways: return "Her Zaman"
        @unknown default: return "Bilinmiyor"
        }
    }
    
    // MARK: - Son Oturum Özeti
    
    private func lastSummaryCard(summary: CorridorSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Son Koridor Özeti")
                    .font(.headline)
                Spacer()
                Text(summary.isOverLimit ? "Sınır Aşıldı" : "Sınır İçinde")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(summary.isOverLimit ? Color.red.opacity(0.2) : Color.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(summary.isOverLimit ? .red : .green)
            }
            
            Text(summary.zoneName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack {
                Text("Ortalama: \(String(format: "%.1f", summary.averageSpeedKmh)) km/sa")
                Spacer()
                Text("Süre: \(Int(summary.durationSeconds)) sn")
            }
            .font(.subheadline.monospacedDigit())
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
    
    // MARK: - Aksiyonlar
    
    private func stopAll() {
        locationService.stopTracking()
        corridorManager.resetSession()
        voiceCoach.stopSpeaking()
        voiceCoach.reset()
    }
}
