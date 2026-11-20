import Foundation
import CoreLocation
import Combine

// MARK: - Kalıcı Koridor Deposu

@MainActor
final class CorridorStore: ObservableObject {
    @Published private(set) var zones: [EDSZone] = []
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
