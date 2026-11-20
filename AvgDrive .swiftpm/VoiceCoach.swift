import Foundation
import AVFoundation
import Combine

@MainActor
final class VoiceCoach: ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    
    @Published var isEnabled: Bool = true
    @Published var cooldownSeconds: TimeInterval = 12.0
    
    private enum GuidanceCategory: Equatable {
        case idle
        case maintain
        case slowDown
        case speedUp
    }
    
    private var lastCategory: GuidanceCategory = .idle
    private var lastSpokenDate: Date?
    
    init() {
        configureAudioSession()
    }
    
    /// Motorun ürettiği yönlendirmeyi değerlendirir ve gerekirse seslendirir.
    func handleGuidance(_ guidance: SpeedGuidance) {
        guard isEnabled else { return }
        
        let newCategory = category(for: guidance)
        
        // Boşta veya hızı koruma durumuna geçişte sadece durumu güncelle, gereksiz konuşma yapma
        if newCategory == .idle {
            lastCategory = .idle
            return
        }
        
        let now = Date()
        let isStateChanged = (newCategory != lastCategory)
        let isCooldownExpired: Bool = {
            guard let lastDate = lastSpokenDate else { return true }
            return now.timeIntervalSince(lastDate) >= cooldownSeconds
        }()
        
        // Yalnızca durum değiştiğinde VEYA aynı uyarı için soğuma süresi dolduğunda konuş
        guard isStateChanged || isCooldownExpired else { return }
        
        switch guidance {
        case .slowDown(let recommendedKmh):
            let target = Int(recommendedKmh.rounded())
            speak("Yavaşla. Hedef hız \(target).", interruptCurrent: isStateChanged)
            lastCategory = .slowDown
            lastSpokenDate = now
            
        case .speedUp(let recommendedKmh):
            let target = Int(recommendedKmh.rounded())
            speak("Hızlanabilirsin. Hedef hız \(target).", interruptCurrent: isStateChanged)
            lastCategory = .speedUp
            lastSpokenDate = now
            
        case .maintain:
            // Yalnızca yavaşla/hızlan durumundan normale dönüldüğünde kısa onay ver
            if lastCategory == .slowDown || lastCategory == .speedUp {
                speak("Hızın uygun.", interruptCurrent: false)
                lastSpokenDate = now
            }
            lastCategory = .maintain
            
        case .idle:
            lastCategory = .idle
        }
    }
    
    func announceZoneEntry(zone: EDSZone) {
        guard isEnabled else { return }
        let limit = Int(zone.speedLimitKmh.rounded())
        speak("Ortalama hız koridoruna girildi. Hız sınırı \(limit).", interruptCurrent: true)
        lastCategory = .maintain
        lastSpokenDate = Date()
    }
    
    func announceZoneExit(summary: CorridorSessionSummary) {
        guard isEnabled else { return }
        let avg = Int(summary.averageSpeedKmh.rounded())
        let statusText = summary.isOverLimit ? "Hız sınırı aşıldı." : "Sınır içinde tamamlandı."
        speak("Koridor tamamlandı. Ortalama hızın \(avg). \(statusText)", interruptCurrent: true)
        reset()
    }
    
    func reset() {
        lastCategory = .idle
        lastSpokenDate = nil
    }
    
    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
    
    // MARK: - Dahili Yardımcılar
    
    private func category(for guidance: SpeedGuidance) -> GuidanceCategory {
        switch guidance {
        case .idle: return .idle
        case .maintain: return .maintain
        case .slowDown: return .slowDown
        case .speedUp: return .speedUp
        }
    }
    
    private func speak(_ text: String, interruptCurrent: Bool) {
        if interruptCurrent && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "tr-TR")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        
        synthesizer.speak(utterance)
    }
    
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory
