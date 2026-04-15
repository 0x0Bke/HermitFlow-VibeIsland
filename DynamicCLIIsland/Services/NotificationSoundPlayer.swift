import AppKit
import AVFoundation
import Foundation

enum NotificationSoundKind: CaseIterable {
    case approval
    case completion

    var customSoundPathDefaultsKey: String {
        switch self {
        case .approval:
            return "HermitFlow.customApprovalNotificationSoundPath"
        case .completion:
            return "HermitFlow.customCompletionNotificationSoundPath"
        }
    }

    var customSoundBookmarkDefaultsKey: String {
        switch self {
        case .approval:
            return "HermitFlow.customApprovalNotificationSoundBookmark"
        case .completion:
            return "HermitFlow.customCompletionNotificationSoundBookmark"
        }
    }

    var bundledResourceName: String {
        switch self {
        case .approval:
            return "notification-ping"
        case .completion:
            return "success"
        }
    }

    var bundledFallbackResourceName: String? {
        switch self {
        case .approval:
            return nil
        case .completion:
            return "notification-ping"
        }
    }

    var customFileURL: URL {
        switch self {
        case .approval:
            return FilePaths.customApprovalNotificationSound
        case .completion:
            return FilePaths.customCompletionNotificationSound
        }
    }
}

final class NotificationSoundPlayer {
    private var bundledPlayers: [NotificationSoundKind: AVAudioPlayer] = [:]
    private var customSounds: [NotificationSoundKind: NSSound] = [:]

    func playApprovalSound() {
        playSound(for: .approval)
    }

    func playCompletionSound() {
        playSound(for: .completion)
    }

    private func playSound(for kind: NotificationSoundKind) {
        for candidate in notificationSoundCandidates(for: kind) {
            if play(candidate, for: kind) {
                return
            }
        }
    }

    private func play(_ resolvedSound: ResolvedNotificationSound, for kind: NotificationSoundKind) -> Bool {
        let stopAccessing = resolvedSound.startAccessingSecurityScopedResourceIfNeeded()
        defer { stopAccessing() }

        if resolvedSound.isCustom {
            return playCustomSound(resolvedSound, for: kind)
        }

        return playBundledSound(resolvedSound, for: kind)
    }

    private func playCustomSound(_ resolvedSound: ResolvedNotificationSound, for kind: NotificationSoundKind) -> Bool {
        let sound = NSSound(contentsOf: resolvedSound.url, byReference: false)
        guard let sound else {
            clearCustomSoundDefaults(for: kind)
            return false
        }

        customSounds[kind]?.stop()
        customSounds[kind] = sound
        return sound.play()
    }

    private func playBundledSound(_ resolvedSound: ResolvedNotificationSound, for kind: NotificationSoundKind) -> Bool {
        do {
            if bundledPlayers[kind]?.url != resolvedSound.url {
                bundledPlayers[kind] = try AVAudioPlayer(contentsOf: resolvedSound.url)
                bundledPlayers[kind]?.prepareToPlay()
            }

            bundledPlayers[kind]?.currentTime = 0
            return bundledPlayers[kind]?.play() == true
        } catch {
            bundledPlayers[kind] = nil
            handlePlaybackFailure(for: resolvedSound, kind: kind, error: error)
            return false
        }
    }

    private func notificationSoundCandidates(for kind: NotificationSoundKind) -> [ResolvedNotificationSound] {
        let customSound = resolveCustomNotificationSound(for: kind)
        let bundledSound = resolveBundledNotificationSound(for: kind)

        switch (customSound, bundledSound) {
        case let (.some(customSound), .some(bundledSound)):
            return [customSound, bundledSound]
        case let (.some(customSound), .none):
            return [customSound]
        case let (.none, .some(bundledSound)):
            return [bundledSound]
        case (.none, .none):
            return []
        }
    }

    private func handlePlaybackFailure(for resolvedSound: ResolvedNotificationSound, kind: NotificationSoundKind, error: Error) {
        if resolvedSound.isCustom {
            clearCustomSoundDefaults(for: kind)
        }

        #if DEBUG
        print("Notification sound playback failed for \(resolvedSound.url.path): \(error)")
        #endif
    }

    private func clearCustomSoundDefaults(for kind: NotificationSoundKind) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: kind.customSoundPathDefaultsKey)
        defaults.removeObject(forKey: kind.customSoundBookmarkDefaultsKey)
    }

    private func resolveBundledNotificationSound(for kind: NotificationSoundKind) -> ResolvedNotificationSound? {
        if let bundledURL = Bundle.main.url(forResource: kind.bundledResourceName, withExtension: "mp3") {
            return ResolvedNotificationSound(url: bundledURL, needsSecurityScopedAccess: false, isCustom: false)
        }

        guard let fallbackName = kind.bundledFallbackResourceName,
              let bundledURL = Bundle.main.url(forResource: fallbackName, withExtension: "mp3") else {
            return nil
        }

        return ResolvedNotificationSound(url: bundledURL, needsSecurityScopedAccess: false, isCustom: false)
    }

    private func resolveCustomNotificationSound(for kind: NotificationSoundKind) -> ResolvedNotificationSound? {
        let defaults = UserDefaults.standard

        if FileManager.default.fileExists(atPath: kind.customFileURL.path) {
            persistPath(kind.customFileURL.path, for: kind)
            return ResolvedNotificationSound(
                url: kind.customFileURL,
                needsSecurityScopedAccess: false,
                isCustom: true
            )
        }

        if let bookmarkData = defaults.data(forKey: kind.customSoundBookmarkDefaultsKey) {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if FileManager.default.fileExists(atPath: url.path) {
                    if isStale {
                        persistBookmark(for: url, kind: kind)
                    }
                    persistPath(url.path, for: kind)
                    return ResolvedNotificationSound(url: url, needsSecurityScopedAccess: true, isCustom: true)
                }
            } catch {
                #if DEBUG
                print("Notification sound bookmark resolution failed: \(error)")
                #endif
            }
        }

        if let customPath = defaults.string(forKey: kind.customSoundPathDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty {
            let customURL = URL(fileURLWithPath: customPath)
            if FileManager.default.fileExists(atPath: customURL.path) {
                return ResolvedNotificationSound(url: customURL, needsSecurityScopedAccess: false, isCustom: true)
            }
        }

        return nil
    }

    private func persistBookmark(for url: URL, kind: NotificationSoundKind) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: kind.customSoundBookmarkDefaultsKey)
        } catch {
            #if DEBUG
            print("Notification sound bookmark save failed: \(error)")
            #endif
        }
    }

    private func persistPath(_ path: String, for kind: NotificationSoundKind) {
        UserDefaults.standard.set(path, forKey: kind.customSoundPathDefaultsKey)
    }
}

private struct ResolvedNotificationSound {
    let url: URL
    let needsSecurityScopedAccess: Bool
    let isCustom: Bool

    func startAccessingSecurityScopedResourceIfNeeded() -> () -> Void {
        guard needsSecurityScopedAccess, url.startAccessingSecurityScopedResource() else {
            return {}
        }

        return {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
