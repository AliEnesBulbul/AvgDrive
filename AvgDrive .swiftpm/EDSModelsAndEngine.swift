import Foundation
import CoreLocation
import Observation

// MARK: - Veri Modelleri

struct EDSZone: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let entryLatitude: Double
    let entryLongitude: Double
    let exitLatitude: Double
    let exitLongitude: Double
    let corridorDistanceMeters: Double
    let speedLimitKmh: Double
    let triggerRadiusMeters: Double
    
    init(
        id: UUID = UUID(),
        name: String,
        entryLatitude: Double,
        entryLongitude: Double,
        exitLatitude: Double,
        exitLongitude: Double,
        corridorDistanceMeters: Double,
        speedLimitKmh: Double,
        triggerRadiusMeters: Double = 60.0
    ) {
        self.id = id
        self.name = name
        self.entryLatitude = entryLatitude
        self.entryLongitude = entryLongitude
        self.exitLatitude = exitLatitude
        self.exitLongitude = exitLongitude
        self.corridorDistanceMeters = corridorDistanceMeters
        self.speedLimitKmh = speedLimitKmh
        self.triggerRadiusMeters = triggerRadiusMeters
    }
    
    var entryLocation: CLLocation {
        CLLocation(latitude: entryLatitude, longitude: entryLongitude)
    }
    
    var exitLocation: CLLocation {
        CLLocation(latitude: exitLatitude, longitude: exitLongitude)
    }
    
    var corridorDistanceKm: Double {
        corridorDistanceMeters / 1000.0
    }
    
    /// Koridoru hız sınırını aşmadan tamamlamak için gereken minimum süre (saniye)
    var minimumAllowedDurationSeconds: Double {
        let limitMps = speedLimitKmh / 3.6
        guard limitMps > 0 else { return 0 }
        return corridorDistanceMeters / limitMps
    }
}

enum SpeedGuidance: Equatable {
    case idle
    case maintain
    case slowDown(recommendedKmh: Double)
    case speedUp(recommendedKmh: Double)
}

struct CorridorSession: Equatable {
    let zone: EDSZone
    let startTime: Date
    var lastLocation: CLLocation
    var traveledDistanceMeters: Double = 0
    var elapsedTimeSeconds: Double = 0
    var averageSpeedKmh: Double = 0
    var recommendedSpeedKmh: Double
    var maxRecordedSpeedKmh: Double = 0
    
    var remainingDistanceMeters: Double {
        max(0, zone.corridorDistanceMeters - traveledDistanceMeters)
    }
    
    var progress: Double {
        guard zone.corridorDistanceMeters > 0 else { return 0 }
        return min(1.0, traveledDistanceMeters / zone.corridorDistanceMeters)
    }
}

struct CorridorSessionSummary: Identifiable, Equatable {
    let id = UUID()
    let zoneName: String
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let traveledDistanceMeters: Double
    let averageSpeedKmh: Double
    let speedLimitKmh: Double
    
    var isOverLimit: Bool {
        averageSpeedKmh > speedLimitKmh
    }
}

// MARK: - Hesaplama Motoru

@MainActor
@Observable
final class SpeedCorridorManager {
    // Kayıtlı koridorlar
    var zones: [EDSZone]
    // SpeedCorridorManager içine, "var zones: [EDSZone]" satırının altına ekle:
    var useTenPercentTolerance: Bool = false
    
    func effectiveSpeedLimitKmh(for zone: EDSZone) -> Double {
        useTenPercentTolerance ? zone.speedLimitKmh * 1.10 : zone.speedLimitKmh
    }

    
    // Anlık durumlar
    private(set) var activeSession: CorridorSession?
    private(set) var lastCompletedSummary: CorridorSessionSummary?
    private(set) var currentSpeedKmh: Double = 0
    private(set) var guidance: SpeedGuidance = .idle
    
    // Hesaplama eşikleri
    private let slowDownToleranceKmh: Double = 2.0
    private let speedUpThresholdBelowLimitKmh: Double = 10.0
    
    init(zones: [EDSZone] = SpeedCorridorManager.sampleZones) {
        self.zones = zones
    }
    
    /// Gerçek GPS veya simülatörden gelen CLLocation verisini işler.
    func processLocation(_ location: CLLocation) {
        // Geçersiz GPS verisini ele
        guard location.horizontalAccuracy >= 0 else { return }
        
        let speedKmh = Self.metersPerSecondToKmh(location.speed)
        currentSpeedKmh = speedKmh
        
        if activeSession == nil {
            checkZoneEntry(for: location, currentSpeedKmh: speedKmh)
        } else {
            updateActiveSession(with: location, currentSpeedKmh: speedKmh)
        }
    }
    
    /// Masa başı test ve simülasyon için sanal konum/hız enjekte eder.
    func processSimulatedPoint(
        latitude: Double,
        longitude: Double,
        speedKmh: Double,
        timestamp: Date = Date()
    ) {
        let speedMps = max(0, speedKmh) / 3.6
        let simulatedLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 5.0,
            verticalAccuracy: 5.0,
            course: 0,
            speed: speedMps,
            timestamp: timestamp
        )
        processLocation(simulatedLocation)
    }
    
    func resetSession() {
        activeSession = nil
        guidance = .idle
    }
    
    // MARK: - Dahili Hesaplama Mantığı
    
    private func checkZoneEntry(for location: CLLocation, currentSpeedKmh: Double) {
        for zone in zones {
            let distanceToEntry = location.distance(from: zone.entryLocation)
            if distanceToEntry <= zone.triggerRadiusMeters {
                let effectiveLimit = effectiveSpeedLimitKmh(for: zone)
                activeSession = CorridorSession(
                    zone: zone,
                    startTime: location.timestamp,
                    lastLocation: location,
                    traveledDistanceMeters: 0,
                    elapsedTimeSeconds: 0,
                    averageSpeedKmh: currentSpeedKmh,
                    recommendedSpeedKmh: effectiveLimit,
                    maxRecordedSpeedKmh: currentSpeedKmh
                )
                guidance = evaluateGuidance(
                    currentSpeedKmh: currentSpeedKmh,
                    averageSpeedKmh: currentSpeedKmh,
                    recommendedSpeedKmh: effectiveLimit,
                    speedLimitKmh: effectiveLimit
                )
                break
            }
        }
    }
    
    private func updateActiveSession(with location: CLLocation, currentSpeedKmh: Double) {
        guard var session = activeSession else { return }
        
        let deltaDistance = location.distance(from: session.lastLocation)
        if deltaDistance >= 0.5 {
            session.traveledDistanceMeters += deltaDistance
            session.lastLocation = location
        }
        
        let elapsed = max(0, location.timestamp.timeIntervalSince(session.startTime))
        session.elapsedTimeSeconds = elapsed
        session.maxRecordedSpeedKmh = max(session.maxRecordedSpeedKmh, currentSpeedKmh)
        
        if elapsed >= 1.0 && session.traveledDistanceMeters > 0 {
            let avgMps = session.traveledDistanceMeters / elapsed
            session.averageSpeedKmh = avgMps * 3.6
        } else {
            session.averageSpeedKmh = currentSpeedKmh
        }
        
        let effectiveLimit = effectiveSpeedLimitKmh(for: session.zone)
        let recommended = calculateRecommendedSpeedKmh(for: session, effectiveLimitKmh: effectiveLimit)
        session.recommendedSpeedKmh = recommended
        
        let distanceToExit = location.distance(from: session.zone.exitLocation)
        let reachedExitPoint = distanceToExit <= session.zone.triggerRadiusMeters && session.traveledDistanceMeters > session.zone.triggerRadiusMeters
        let completedDistance = session.traveledDistanceMeters >= session.zone.corridorDistanceMeters
        
        if reachedExitPoint || completedDistance {
            finishSession(session, endTime: location.timestamp, effectiveLimitKmh: effectiveLimit)
        } else {
            activeSession = session
            guidance = evaluateGuidance(
                currentSpeedKmh: currentSpeedKmh,
                averageSpeedKmh: session.averageSpeedKmh,
                recommendedSpeedKmh: recommended,
                speedLimitKmh: effectiveLimit
            )
        }
    }
    
    private func calculateRecommendedSpeedKmh(for session: CorridorSession, effectiveLimitKmh: Double) -> Double {
        let remainingMeters = session.remainingDistanceMeters
        guard remainingMeters > 0 else { return effectiveLimitKmh }
        
        let limitMps = effectiveLimitKmh / 3.6
        guard limitMps > 0 else { return effectiveLimitKmh }
        
        let minAllowedSeconds = session.zone.corridorDistanceMeters / limitMps
        let remainingAllowedSeconds = minAllowedSeconds - session.elapsedTimeSeconds
        
        guard remainingAllowedSeconds > 0 else {
            return effectiveLimitKmh
        }
        
        let rawTargetKmh = (remainingMeters / remainingAllowedSeconds) * 3.6
        return max(0, min(rawTargetKmh, effectiveLimitKmh))
    }
    private func evaluateGuidance(
        currentSpeedKmh: Double,
        averageSpeedKmh: Double,
        recommendedSpeedKmh: Double,
        speedLimitKmh: Double
    ) -> SpeedGuidance {
        if averageSpeedKmh > speedLimitKmh || currentSpeedKmh > (recommendedSpeedKmh + slowDownToleranceKmh) {
            return .slowDown(recommendedKmh: recommendedSpeedKmh)
        }
        
        let lowerBound = max(0, speedLimitKmh - speedUpThresholdBelowLimitKmh)
        if averageSpeedKmh < lowerBound && currentSpeedKmh < lowerBound && recommendedSpeedKmh > currentSpeedKmh + 5.0 {
            return .speedUp(recommendedKmh: recommendedSpeedKmh)
        }
        
        return .maintain
    }

    
    private func finishSession(_ session: CorridorSession, endTime: Date, effectiveLimitKmh: Double) {
        let duration = max(1.0, endTime.timeIntervalSince(session.startTime))
        let effectiveDistance = min(session.traveledDistanceMeters, session.zone.corridorDistanceMeters)
        let finalAverageKmh = (effectiveDistance / duration) * 3.6
        
        lastCompletedSummary = CorridorSessionSummary(
            zoneName: session.zone.name,
            startTime: session.startTime,
            endTime: endTime,
            durationSeconds: duration,
            traveledDistanceMeters: effectiveDistance,
            averageSpeedKmh: finalAverageKmh,
            speedLimitKmh: effectiveLimitKmh
        )
        
        activeSession = nil
        guidance = .idle
    }

    
    nonisolated static func metersPerSecondToKmh(_ mps: Double) -> Double {
        guard mps > 0 else { return 0 }
        return mps * 3.6
    }
    
    // Masa başı test için örnek koridor (1 km, 82 km/sa sınır)
    nonisolated static let sampleZones: [EDSZone] = [
        EDSZone(
            name: "Örnek Test Koridoru (1 km)",
            entryLatitude: 38.7205,
            entryLongitude: 35.4826,
            exitLatitude: 38.7295,
            exitLongitude: 35.4826,
            corridorDistanceMeters: 1000,
            speedLimitKmh: 82,
            triggerRadiusMeters: 60
        )
    ]
}

