import Foundation
import CoreLocation
import Observation

// MARK: - Gerçek GPS Konum Sağlayıcı

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var isTracking: Bool = false
    private(set) var lastErrorMessage: String?
    
    var onLocationUpdate: ((CLLocation) -> Void)?
    
    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
    }
    
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }
    
    func startTracking() {
        lastErrorMessage = nil
        if authorizationStatus == .notDetermined {
            requestPermission()
        }
        manager.startUpdatingLocation()
        isTracking = true
    }
    
    func stopTracking() {
        manager.stopUpdatingLocation()
        isTracking = false
    }
    
    // MARK: - CLLocationManagerDelegate (Swift 6 Uyumlu)
    
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last else { return }
        Task { @MainActor in
            self.onLocationUpdate?(latestLocation)
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.lastErrorMessage = message
        }
    }
}

// MARK: - Masa Başı Simülasyon Motoru

@MainActor
@Observable
final class LocationSimulator {
    private(set) var isRunning: Bool = false
    var simulatedSpeedKmh: Double = 80.0
    private(set) var simulatedDistanceMeters: Double = 0
    
    private var simulationTask: Task<Void, Never>?
    
    /// Seçilen koridor boyunca saniyede 1 kez sanal konum ve hız üretir.
    func start(
        zone: EDSZone,
        onTick: @escaping @MainActor (Double, Double, Double, Date) -> Void
    ) {
        stop()
        
        isRunning = true
        simulatedDistanceMeters = 0
        
        simulationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            
            // 1. Adım: Giriş noktasından başlat (oturumun tetiklenmesi için)
            onTick(zone.entryLatitude, zone.entryLongitude, self.simulatedSpeedKmh, Date())
            
            while !Task.isCancelled && self.isRunning {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                
                guard !Task.isCancelled && self.isRunning else { break }
                
                // 1 saniyede katedilen mesafe (metre)
                let stepMeters = max(0, self.simulatedSpeedKmh) / 3.6
                self.simulatedDistanceMeters += stepMeters
                
                let totalDistance = max(1.0, zone.corridorDistanceMeters)
                let ratio = min(1.0, self.simulatedDistanceMeters / totalDistance)
                
                // Giriş ve çıkış arasında doğrusal koordinat interpolasyonu
                let currentLat = zone.entryLatitude + (zone.exitLatitude - zone.entryLatitude) * ratio
                let currentLon = zone.entryLongitude + (zone.exitLongitude - zone.entryLongitude) * ratio
                
                onTick(currentLat, currentLon, self.simulatedSpeedKmh, Date())
                
                // Koridor mesafesi tamamlandıysa simülasyonu bitir
                if self.simulatedDistanceMeters >= zone.corridorDistanceMeters {
                    self.isRunning = false
                    break
                }
            }
        }
    }
    
    func stop() {
        simulationTask?.cancel()
        simulationTask = nil
        isRunning = false
    }
}

