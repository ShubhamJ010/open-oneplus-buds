import Foundation
import CoreAudio
import AudioToolbox

/// Lightweight system audio playback and MediaRemote monitor.
/// Reacts to MediaRemote system notifications + dynamic CoreAudio device status.
/// Fully push-driven: zero polling timers.
@MainActor
final class MediaPlaybackMonitor: ObservableObject {
    @Published private(set) var isPlaying: Bool = false

    private typealias MRRegister = @convention(c) (DispatchQueue) -> Void
    private typealias MRIsPlaying = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    private var mrRegisterFn: MRRegister?
    private var mrIsPlayingFn: MRIsPlaying?
    private var mediaRemoteHandle: UnsafeMutableRawPointer?
    private var notificationObservers: [NSObjectProtocol] = []

    private var listenedDeviceID: AudioDeviceID = 0
    private var isSystemListenerRegistered = false

    init() {
        setupMediaRemote()
        setupNotificationObservers()
        setupSystemOutputDeviceListener()
        setupDeviceRunningListener()
        checkPlayback()
    }

    isolated deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        removeDeviceRunningListener()
        removeSystemOutputDeviceListener()
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

    // MARK: - CoreAudio Property Listeners (Push-driven, Zero Polling)

    /// Registers a hardware listener on the system audio object to detect default output device changes.
    /// When the user switches audio output (e.g. built-in speakers to AirPods or OnePlus Buds),
    /// the listener updates the monitored device and re-checks playback status.
    private func setupSystemOutputDeviceListener() {
        var defaultDeviceAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddr,
            audioDefaultDevicePropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if status == noErr {
            isSystemListenerRegistered = true
        }
    }

    /// Unregisters the system default output device property listener during cleanup.
    private func removeSystemOutputDeviceListener() {
        guard isSystemListenerRegistered else { return }
        var defaultDeviceAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddr,
            audioDefaultDevicePropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        isSystemListenerRegistered = false
    }

    /// Subscribes to the `kAudioDevicePropertyDeviceIsRunningSomewhere` property on the current default output device.
    /// Fired instantly when any audio client starts or stops rendering audio through CoreAudio on that device.
    fileprivate func setupDeviceRunningListener() {
        removeDeviceRunningListener()
        let devID = currentDefaultOutputDeviceID()
        guard devID != 0 else { return }
        listenedDeviceID = devID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(
            devID,
            &addr,
            audioDeviceRunningPropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Unregisters the running status property listener from the currently monitored CoreAudio output device.
    private func removeDeviceRunningListener() {
        guard listenedDeviceID != 0 else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            listenedDeviceID,
            &addr,
            audioDeviceRunningPropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        listenedDeviceID = 0
    }

    /// Checks the overall playback state by querying MediaRemote (for media app playback)
    /// and CoreAudio hardware state (for active audio streams like YouTube in browsers or system alerts).
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

    /// Checks whether the current default output audio device is currently running (actively playing audio).
    ///
    /// - Returns: `true` if CoreAudio reports that the device is running somewhere, otherwise `false`.
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

    /// Retrieves the `AudioDeviceID` of macOS's current default system output audio device.
    ///
    /// - Returns: The device ID, or 0 if retrieval fails.
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

// MARK: - CoreAudio C Callbacks

/// C-style CoreAudio property listener callback triggered when the monitored device's running state changes.
/// Bridges the raw client data back to `MediaPlaybackMonitor` and hops to `@MainActor` to update state.
private func audioDeviceRunningPropertyListener(
    _ inObjectID: AudioObjectID,
    _ inNumberAddresses: UInt32,
    _ inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let monitor = Unmanaged<MediaPlaybackMonitor>.fromOpaque(inClientData).takeUnretainedValue()
    Task { @MainActor in
        monitor.checkPlayback()
    }
    return noErr
}

/// C-style CoreAudio property listener callback triggered when the system default output device changes.
/// Re-attaches running state listeners to the new default device and refreshes playback status.
private func audioDefaultDevicePropertyListener(
    _ inObjectID: AudioObjectID,
    _ inNumberAddresses: UInt32,
    _ inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let monitor = Unmanaged<MediaPlaybackMonitor>.fromOpaque(inClientData).takeUnretainedValue()
    Task { @MainActor in
        monitor.setupDeviceRunningListener()
        monitor.checkPlayback()
    }
    return noErr
}
