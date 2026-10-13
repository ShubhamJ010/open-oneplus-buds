import Foundation
import CoreAudio
import AudioToolbox

/// Lightweight system audio playback and MediaRemote monitor.
/// Reacts to MediaRemote system notifications + dynamic CoreAudio device status.
@MainActor
final class MediaPlaybackMonitor: ObservableObject {
    @Published private(set) var isPlaying: Bool = false

    private typealias MRRegister = @convention(c) (DispatchQueue) -> Void
    private typealias MRIsPlaying = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    private var mrRegisterFn: MRRegister?
    private var mrIsPlayingFn: MRIsPlaying?
    private var mediaRemoteHandle: UnsafeMutableRawPointer?
    private var notificationObservers: [NSObjectProtocol] = []

    private var pollTimer: Timer?

    init() {
        setupMediaRemote()
        setupNotificationObservers()
        checkPlayback()
        startPeriodicCheck()
    }

    isolated deinit {
        pollTimer?.invalidate()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let handle = mediaRemoteHandle {
            dlclose(handle)
        }
    }

    private func setupMediaRemote() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) {
            mediaRemoteHandle = handle
            if let regSym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
                mrRegisterFn = unsafeBitCast(regSym, to: MRRegister.self)
            }
            if let isPlayingSym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
                mrIsPlayingFn = unsafeBitCast(isPlayingSym, to: MRIsPlaying.self)
            }
            mrRegisterFn?(DispatchQueue.main)
        }
    }

    private func setupNotificationObservers() {
        let notificationNames = [
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
        ]

        for name in notificationNames {
            let obs = NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkPlayback()
                }
            }
            notificationObservers.append(obs)
        }
    }

    private func startPeriodicCheck() {
        // Lightweight 0.8s heartbeat for immediate feedback on play/pause
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPlayback()
            }
        }
    }

    func checkPlayback() {
        if let mrIsPlayingFn {
            mrIsPlayingFn(DispatchQueue.main) { [weak self] mrPlaying in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let audioRunning = self.checkCoreAudioIsRunning()
                    let active = mrPlaying || audioRunning
                    if self.isPlaying != active {
                        self.isPlaying = active
                    }
                }
            }
        } else {
            let audioRunning = checkCoreAudioIsRunning()
            if isPlaying != audioRunning {
                isPlaying = audioRunning
            }
        }
    }

    private func checkCoreAudioIsRunning() -> Bool {
        let devID = currentDefaultOutputDeviceID()
        guard devID != 0 else { return false }

        var isRunningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            devID,
            &isRunningAddr,
            0,
            nil,
            &isRunningSize,
            &isRunning
        )
        return status == noErr && isRunning != 0
    }

    private func currentDefaultOutputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &devID
        )
        return status == noErr ? devID : 0
    }
}
