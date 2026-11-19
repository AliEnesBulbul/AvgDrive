import Foundation
import CoreLocation
import Observation

// MARK: - Kalıcı Koridor Deposu

@MainActor
@Observable
final class CorridorStore {
    private(set) var zones: [EDSZone] = []
    private let storageKey = "saved_eds_zones_v1"
    
    init() {
        load()
    }
    
    func addZone(_ zone: EDSZone, createReverse: Bool = false) {
        zones.append(zone)
        
        if createReverse {
            let reverseZone = EDSZone(
                name: "\(zone.name) (Dönüş)",
                entryLatitude: zone.exitLatitude,
                entryLongitude: zone.exitLongitude,
                exitLatitude: zone.entryLatitude,
                exitLongitude: zone.entryLongitude,
                corridorDistanceMeters: zone.corridorDistanceMeters,
                speedLimitKmh: zone.speedLimitKmh,
                triggerRadiusMeters: zone.triggerRadiusMeters
            )
            zones.append(reverseZone)
        }
        
        save()
    }
    
    func deleteZone(id: UUID) {
        zones.removeAll { $0.id == id }
        save()
    }
    
    func deleteZones(at offsets: IndexSet) {
        zones.remove(atOffsets: offsets)
        save()
    }
    
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([EDSZone].self, from: data),
              !decoded.isEmpty else {
            zones = SpeedCorridorManager.sampleZones
            return
        }
        zones = decoded
    }
    
    private func save() {
        guard let encoded = try? JSONEncoder().encode(zones) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }
}

// MARK: - Kaydedilen Güzergah Taslağı

struct RecordedCorridorDraft: Equatable {
    let entryLatitude: Double
    let entryLongitude: Double
    let exitLatitude: Double
    let exitLongitude: Double
    let measuredDistanceMeters: Double
}

// MARK: - Güzergah Kayıt Motoru

@MainActor
@Observable
final class CorridorRecorder {
    private(set) var isRecording: Bool = false
    private(set) var measuredDistanceMeters: Double = 0
    private(set) var completedDraft: RecordedCorridorDraft?
    
    private var entryLocation: CLLocation?
    private var lastLocation: CLLocation?
    
    /// Giriş noktası işaretlendiğinde çağrılır.
    func startRecording(at location: CLLocation) {
        entryLocation = location
        lastLocation = location
        measuredDistanceMeters = 0
        completedDraft = nil
        isRecording = true
    }
    
    /// Kayıt aktifken gelen her GPS konumunda gerçek yol mesafesini biriktirir.
    func appendLocation(_ location: CLLocation) {
        guard isRecording,
              location.horizontalAccuracy >= 0,
              let previous = lastLocation else { return }
        
        let delta = location.distance(from: previous)
        // Duran araçta GPS sapmalarını mesafeye eklememek için 1 metre eşiği
        if delta >= 1.0 {
            measuredDistanceMeters += delta
            lastLocation = location
        }
    }
    
    /// Çıkış noktası işaretlendiğinde kaydı tamamlar ve taslak üretir.
    func finishRecording(at location: CLLocation) {
        guard isRecording, let entry = entryLocation else { return }
        
        appendLocation(location)
        
        // Eğer araç hiç hareket etmediyse en azından kuş uçuşu mesafeyi baz al
        let finalDistance = max(measuredDistanceMeters, entry.distance(from: location))
        
        completedDraft = RecordedCorridorDraft(
            entryLatitude: entry.coordinate.latitude,
            entryLongitude: entry.coordinate.longitude,
            exitLatitude: location.coordinate.latitude,
            exitLongitude: location.coordinate.longitude,
            measuredDistanceMeters: finalDistance
        )
        
        isRecording = false
    }
    
    func reset() {
        isRecording = false
        entryLocation = nil
        lastLocation = nil
        measuredDistanceMeters = 0
        completedDraft = nil
    }
}

