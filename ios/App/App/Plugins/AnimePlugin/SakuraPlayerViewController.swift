import UIKit
import AVFoundation
import AVKit

class SakuraPlayerViewController: UIViewController {

    // MARK: - Public Properties (set before presenting)

    var streamUrl: String = ""
    var referer: String?
    var episodeTitle: String = "Episode"
    var subtitles: [SubtitleTrack] = []
    var episodeId: String = ""
    var hasNext: Bool = false
    var nextEpisodeTitle: String = ""
    var introStart: Double?
    var introEnd: Double?
    var isLocal: Bool = false
    var onDismiss: ((Bool) -> Void)?

    // MARK: - Private Properties

    private var player: AVPlayer?
    private var playerViewController: AVPlayerViewController?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var resultSent = false
    private var positionRestored = false

    private var upNextContainer: UIView?
    private var countdownLabel: UILabel?
    private var upNextShown = false
    private var countdownValue = 5
    private var countdownTimer: Timer?
    private var skipIntroButton: UIButton?

    private static let prefsKey = "sakura_player_positions"
    private static let upNextThreshold: TimeInterval = 60

    // MARK: - Lifecycle

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupPlayer()
        setupUpNextOverlay()
        setupSkipIntroOverlay()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        savePosition()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cleanup()
        finishWithResult(completed: false)
    }

    // MARK: - Player Setup

    private func setupPlayer() {
        guard !streamUrl.isEmpty else {
            finishWithResult(completed: false)
            return
        }

        let asset: AVURLAsset
        if isLocal {
            let fileUrl: URL
            if streamUrl.hasPrefix("file://") {
                fileUrl = URL(string: streamUrl)!
            } else {
                fileUrl = URL(fileURLWithPath: streamUrl)
            }
            asset = AVURLAsset(url: fileUrl)
        } else {
            guard let url = URL(string: streamUrl) else {
                finishWithResult(completed: false)
                return
            }

            var headers: [String: String] = [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            ]
            if let referer = referer {
                headers["Referer"] = referer
                if let origin = URL(string: referer)?.deletingLastPathComponent().absoluteString {
                    headers["Origin"] = origin
                }
            }

            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }

        let playerItem = AVPlayerItem(asset: asset)

        if !subtitles.isEmpty && !isLocal {
            addExternalSubtitles(to: playerItem)
        }

        player = AVPlayer(playerItem: playerItem)

        let avPlayerVC = AVPlayerViewController()
        avPlayerVC.player = player
        avPlayerVC.showsPlaybackControls = true
        avPlayerVC.allowsPictureInPicturePlayback = true
        avPlayerVC.entersFullScreenWhenPlaybackBegins = false

        addChild(avPlayerVC)
        avPlayerVC.view.frame = view.bounds
        avPlayerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(avPlayerVC.view)
        avPlayerVC.didMove(toParent: self)
        self.playerViewController = avPlayerVC

        setupObservers()

        configureAudioSession()

        player?.play()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[SakuraPlayer] Audio session error: %@", error.localizedDescription)
        }
    }

    private func addExternalSubtitles(to playerItem: AVPlayerItem) {
        for sub in subtitles {
            guard let subUrl = URL(string: sub.url) else { continue }

            let mimeType: String
            let lowered = sub.url.lowercased()
            if lowered.hasSuffix(".srt") {
                mimeType = "application/x-subrip"
            } else if lowered.hasSuffix(".ass") || lowered.hasSuffix(".ssa") {
                mimeType = "text/x-ssa"
            } else {
                mimeType = "text/vtt"
            }

            let asset = AVURLAsset(url: subUrl)
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = sub.label as NSString
            playerItem.externalMetadata.append(item)

            NSLog("[SakuraPlayer] Added subtitle track: %@ (%@)", sub.label, sub.url)
        }
    }

    // MARK: - Observers

    private func setupObservers() {
        guard let player = player else { return }

        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            switch item.status {
            case .readyToPlay:
                self.restorePosition()
            case .failed:
                NSLog("[SakuraPlayer] Playback failed: %@", item.error?.localizedDescription ?? "unknown")
            default:
                break
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            self?.handleTimeUpdate(time: time)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        clearSavedPosition()
        if hasNext {
            showUpNext()
            startCountdown()
        } else {
            finishWithResult(completed: true)
        }
    }

    @objc private func appWillResignActive() {
        savePosition()
    }

    private func handleTimeUpdate(time: CMTime) {
        guard let player = player,
              let duration = player.currentItem?.duration,
              duration.isNumeric && !duration.isIndefinite else { return }

        let durationSec = CMTimeGetSeconds(duration)
        let currentSec = CMTimeGetSeconds(time)

        if durationSec > 0 && hasNext && !upNextShown {
            if durationSec - currentSec <= Self.upNextThreshold {
                showUpNext()
            }
        }

        updateSkipIntroVisibility(currentSec: currentSec)
    }

    // MARK: - Position Persistence

    private func getPositions() -> [String: Double] {
        return UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: Double] ?? [:]
    }

    private func savePosition() {
        guard let player = player, !episodeId.isEmpty else { return }
        let position = CMTimeGetSeconds(player.currentTime())
        guard position > 0 else { return }

        var positions = getPositions()
        positions["anime_pos_\(episodeId)"] = position
        UserDefaults.standard.set(positions, forKey: Self.prefsKey)
    }

    private func restorePosition() {
        guard !positionRestored, !episodeId.isEmpty else { return }
        positionRestored = true

        let positions = getPositions()
        if let savedPos = positions["anime_pos_\(episodeId)"], savedPos > 0 {
            let time = CMTime(seconds: savedPos, preferredTimescale: 1)
            player?.seek(to: time)
            NSLog("[SakuraPlayer] Restored position to %.1fs for %@", savedPos, episodeId)
        }
    }

    private func clearSavedPosition() {
        guard !episodeId.isEmpty else { return }
        var positions = getPositions()
        positions.removeValue(forKey: "anime_pos_\(episodeId)")
        UserDefaults.standard.set(positions, forKey: Self.prefsKey)
    }

    // MARK: - Skip Intro Overlay

    private func hasValidIntroWindow() -> Bool {
        guard let start = introStart, let end = introEnd else { return false }
        return end > start && start >= 0
    }

    private func setupSkipIntroOverlay() {
        guard hasValidIntroWindow() else { return }

        let button = UIButton(type: .system)
        button.setTitle("Skip Intro", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        button.backgroundColor = UIColor(red: 233/255, green: 30/255, blue: 123/255, alpha: 0.92)
        button.layer.cornerRadius = 14
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.28
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        button.layer.shadowRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        button.isHidden = true
        button.alpha = 0
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(skipIntroTapped), for: .touchUpInside)

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        skipIntroButton = button
    }

    private func updateSkipIntroVisibility(currentSec: TimeInterval) {
        guard hasValidIntroWindow(),
              let start = introStart,
              let end = introEnd,
              let button = skipIntroButton else { return }

        let shouldShow = currentSec >= start && currentSec < end
        if shouldShow && button.isHidden {
            button.isHidden = false
            UIView.animate(withDuration: 0.2) {
                button.alpha = 1
            }
        } else if !shouldShow && !button.isHidden {
            UIView.animate(withDuration: 0.2, animations: {
                button.alpha = 0
            }, completion: { _ in
                button.isHidden = true
            })
        }
    }

    @objc private func skipIntroTapped() {
        guard let end = introEnd else { return }
        let time = CMTime(seconds: end, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        skipIntroButton?.isHidden = true
        skipIntroButton?.alpha = 0
    }

    // MARK: - Up Next Overlay

    private func setupUpNextOverlay() {
        let container = UIView()
        container.backgroundColor = .clear
        container.isHidden = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let gradient = CAGradientLayer()
        gradient.colors = [
            UIColor(red: 233/255, green: 30/255, blue: 123/255, alpha: 1).cgColor,
            UIColor(red: 194/255, green: 24/255, blue: 91/255, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.cornerRadius = 16
        container.layer.insertSublayer(gradient, at: 0)

        container.layer.cornerRadius = 16
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.3
        container.layer.shadowOffset = CGSize(width: 0, height: 4)
        container.layer.shadowRadius = 8

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headerLabel = UILabel()
        headerLabel.text = "🌸 Up Next"
        headerLabel.textColor = .white
        headerLabel.font = .systemFont(ofSize: 13, weight: .medium)
        headerLabel.alpha = 0.9
        stack.addArrangedSubview(headerLabel)

        let titleLabel = UILabel()
        titleLabel.text = nextEpisodeTitle.isEmpty ? "Next Episode" : nextEpisodeTitle
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(titleLabel)

        let countdown = UILabel()
        countdown.textColor = UIColor(red: 1, green: 0.88, blue: 0.94, alpha: 1)
        countdown.font = .systemFont(ofSize: 12, weight: .regular)
        countdown.isHidden = true
        stack.addArrangedSubview(countdown)
        self.countdownLabel = countdown

        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])

        container.layoutIfNeeded()
        gradient.frame = container.bounds

        let tap = UITapGestureRecognizer(target: self, action: #selector(upNextTapped))
        container.addGestureRecognizer(tap)
        container.isUserInteractionEnabled = true

        self.upNextContainer = container

        container.addObserver(self, forKeyPath: "bounds", options: .new, context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "bounds", let container = object as? UIView {
            if let gradient = container.layer.sublayers?.first as? CAGradientLayer {
                gradient.frame = container.bounds
            }
        }
    }

    private func showUpNext() {
        guard !upNextShown else { return }
        upNextShown = true

        upNextContainer?.isHidden = false
        upNextContainer?.alpha = 0
        UIView.animate(withDuration: 0.5) {
            self.upNextContainer?.alpha = 1
        }
    }

    private func startCountdown() {
        countdownValue = 5
        countdownLabel?.text = "Starting in \(countdownValue)s…"
        countdownLabel?.isHidden = false

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.countdownValue -= 1
            if self.countdownValue <= 0 {
                self.countdownTimer?.invalidate()
                self.countdownTimer = nil
                self.finishWithResult(completed: true)
            } else {
                self.countdownLabel?.text = "Starting in \(self.countdownValue)s…"
            }
        }
    }

    @objc private func upNextTapped() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        finishWithResult(completed: true)
    }

    // MARK: - Cleanup & Result

    private func finishWithResult(completed: Bool) {
        guard !resultSent else { return }
        resultSent = true

        if completed && !episodeId.isEmpty {
            clearSavedPosition()
        }

        cleanup()

        dismiss(animated: true) {
            self.onDismiss?(completed)
        }
    }

    private func cleanup() {
        countdownTimer?.invalidate()
        countdownTimer = nil

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil

        NotificationCenter.default.removeObserver(self)

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    deinit {
        cleanup()
    }
}
