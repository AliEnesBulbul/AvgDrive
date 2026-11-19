import SwiftUI
import CoreLocation
import UIKit

struct CorridorManagementView: View {
    @Environment(\.dismiss) private var dismiss
    
    var store: CorridorStore
    var recorder: CorridorRecorder
    var locationService: LocationService
    var voiceCoach: VoiceCoach
    var latestLocation: CLLocation?
    
    @State private var corridorName: String = ""
    @State private var speedLimitKmh: Double = 82
    @State private var createReverse: Bool = true
    @State private var showFullScreenRecorder: Bool = false
    @State private var showSimulationLab: Bool = false
    
    var body: some View {
        NavigationStack {
            List {
                recordingSection
                if let draft = recorder.completedDraft {
                    saveDraftSection(draft: draft)
                }
                savedCorridorsSection
                Section {
                    Text("AvgDrive Alpha v0.1")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 5) {
                            showSimulationLab = true
                        }
                }
                .listRowBackground(Color.clear)

            }
            .navigationTitle("Koridorlarım")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Kapat") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showFullScreenRecorder) {
                FullScreenCorridorRecorderView(
                    recorder: recorder,
                    voiceCoach: voiceCoach,
                    latestLocation: latestLocation
                )
            }
            .sheet(isPresented: $showSimulationLab) {
                SimulationLabView(savedZones: store.zones, voiceCoach: voiceCoach)
            }
        }
    }
   

    
    // MARK: - Güzergah Kayıt Bölümü
    
    private var recordingSection: some View {
        Section {
            if !locationService.isTracking {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Güzergah kaydetmek için GPS takibi açık olmalıdır.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        locationService.startTracking()
                    } label: {
                        Label("GPS Takibini Başlat", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(latestLocation == nil ? "GPS sinyali bekleniyor..." : "Sürüş sırasında kolay basım için tam ekran kayıt modunu aç.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        showFullScreenRecorder = true
                    } label: {
                        Label(
                            recorder.isRecording ? "Tam Ekran Kayda Dön (\(Int(recorder.measuredDistanceMeters)) m)" : "Tam Ekran Kayıt Modunu Aç",
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.isRecording ? .red : .blue)
                    .disabled(latestLocation == nil)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Yeni Koridor Kaydet")
        } footer: {
            Text("Giriş işaretlendikten sonra yanlış dokunmayı önlemek için buton 5 saniye kilitlenir.")
        }
    }
    
    // MARK: - Kaydedilen Taslağı Onaylama Bölümü
    
    private func saveDraftSection(draft: RecordedCorridorDraft) -> some View {
        Section("Kaydedilecek Koridor") {
            HStack {
                Text("Ölçülen Mesafe")
                Spacer()
                Text(String(format: "%.2f km (%d m)", draft.measuredDistanceMeters / 1000.0, Int(draft.measuredDistanceMeters)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            
            TextField("Koridor Adı (Örn: Çevre Yolu)", text: $corridorName)
            
            Stepper(value: $speedLimitKmh, in: 30...140, step: 2) {
                HStack {
                    Text("Hız Sınırı")
                    Spacer()
                    Text("\(Int(speedLimitKmh)) km/sa")
                        .bold()
                        .monospacedDigit()
                }
            }
            
            Toggle("Ters yönü de oluştur (Dönüş)", isOn: $createReverse)
            
            Button {
                let finalName = corridorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Koridor \(store.zones.count + 1)"
                : corridorName.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let newZone = EDSZone(
                    name: finalName,
                    entryLatitude: draft.entryLatitude,
                    entryLongitude: draft.entryLongitude,
                    exitLatitude: draft.exitLatitude,
                    exitLongitude: draft.exitLongitude,
                    corridorDistanceMeters: max(100, draft.measuredDistanceMeters),
                    speedLimitKmh: speedLimitKmh
                )
                
                store.addZone(newZone, createReverse: createReverse)
                corridorName = ""
                recorder.reset()
            } label: {
                Label("Koridoru Kaydet", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    // MARK: - Kayıtlı Koridorlar Listesi
    
    private var savedCorridorsSection: some View {
        Section("Kayıtlı Koridorlar (\(store.zones.count))") {
            if store.zones.isEmpty {
                Text("Henüz kayıtlı koridor yok.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.zones) { zone in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(zone.name)
                            .font(.headline)
                        HStack {
                            Text(String(format: "%.2f km", zone.corridorDistanceKm))
                            Text("•")
                            Text("Sınır: \(Int(zone.speedLimitKmh)) km/sa")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    store.deleteZones(at: offsets)
                }
            }
        }
    }
}

// MARK: - Tam Ekran Sürüş Kayıt Ekranı

struct FullScreenCorridorRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    
    var recorder: CorridorRecorder
    var voiceCoach: VoiceCoach
    var latestLocation: CLLocation?
    
    @State private var lockRemainingSeconds: Int = 0
    @State private var lockTask: Task<Void, Never>?
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                handleMainButtonTap()
            } label: {
                VStack(spacing: 20) {
                    Image(systemName: recorder.isRecording ? "flag.checkered" : "flag.fill")
                        .font(.system(size: 72, weight: .bold))
                    
                    Text(recorder.isRecording ? "ÇIKIŞ İŞARETLE" : "GİRİŞ İŞARETLE")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                    
                    if recorder.isRecording {
                        Text("\(Int(recorder.measuredDistanceMeters)) metre")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        
                        if lockRemainingSeconds > 0 {
                            Text("Yanlış dokunma kilidi: \(lockRemainingSeconds) sn")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.black.opacity(0.3), in: Capsule())
                        }
                    } else {
                        Text("Koridor girişine geldiğinde ekranın herhangi bir yerine dokun")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                            .opacity(0.9)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(backgroundColor.gradient)
            }
            .buttonStyle(.plain)
            .disabled(latestLocation == nil || (recorder.isRecording && lockRemainingSeconds > 0))
            .ignoresSafeArea()
            
            HStack(spacing: 12) {
                if recorder.isRecording {
                    Button("İptal") {
                        lockTask?.cancel()
                        recorder.reset()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.45))
                }
                
                Button {
                    lockTask?.cancel()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                        .foregroundStyle(.white)
                }
            }
            .padding()
        }
        .onDisappear {
            lockTask?.cancel()
        }
    }
    
    private var backgroundColor: Color {
        if !recorder.isRecording {
            return .green
        }
        return lockRemainingSeconds > 0 ? .orange : .red
    }
    
    private func handleMainButtonTap() {
        guard let loc = latestLocation else { return }
        
        let feedback = UIImpactFeedbackGenerator(style: .heavy)
        feedback.impactOccurred()
        
        if !recorder.isRecording {
            recorder.startRecording(at: loc)
            voiceCoach.announceRecordingEvent("Giriş işaretlendi.")
            startLockCountdown()
        } else {
            recorder.finishRecording(at: loc)
            voiceCoach.announceRecordingEvent("Çıkış işaretlendi.")
            dismiss()
        }
    }
    
    private func startLockCountdown() {
        lockTask?.cancel()
        lockRemainingSeconds = 5
        
        lockTask = Task { @MainActor in
            while lockRemainingSeconds > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled {
                    lockRemainingSeconds -= 1
                }
            }
        }
    }
}

