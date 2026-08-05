import Combine
import SwiftUI
import WebKit

/// Drives a hidden WKWebView running the YouTube IFrame Player API.
///
/// SwiftUI owns the transport; the web view is only an audio engine. Playback
/// pauses at the end of the listening window instead of advancing on its own,
/// so no card is ever passed without a decision.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentVideoID: String?
    @Published private(set) var videoUnavailable = false
    @Published var windowLength: TimeInterval = 60

    private var videoIDs: [String] = []
    private var index = 0
    private var ticker: AnyCancellable?

    let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isHidden = true
        return view
    }()

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "playerError")
        webView.loadHTMLString(Self.playerHTML, baseURL: URL(string: "https://www.youtube.com"))
    }

    func load(videoIDs: [String]) {
        self.videoIDs = videoIDs
        index = 0
        videoUnavailable = videoIDs.isEmpty
        elapsed = 0
        stopTicker()
        playCurrent()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func extendWindow() {
        windowLength += 60
        resume()
    }

    func nextVideo() {
        guard index + 1 < videoIDs.count else { return }
        index += 1
        elapsed = 0
        playCurrent()
    }

    /// Returns false when no playable video is left for this release.
    @discardableResult
    func advanceAfterFailure() -> Bool {
        guard index + 1 < videoIDs.count else { return false }
        index += 1
        elapsed = 0
        playCurrent()
        return true
    }

    // MARK: - Private

    private func playCurrent() {
        guard index < videoIDs.count else {
            videoUnavailable = true
            currentVideoID = nil
            return
        }
        let id = videoIDs[index]
        currentVideoID = id
        videoUnavailable = false
        evaluate("loadVideo('\(id)')")
        startTicker()
        isPlaying = true
    }

    private func resume() {
        guard currentVideoID != nil else { return }
        evaluate("player.playVideo()")
        startTicker()
        isPlaying = true
    }

    private func pause() {
        evaluate("player.pauseVideo()")
        stopTicker()
        isPlaying = false
    }

    private func startTicker() {
        ticker = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.elapsed += 0.25
                if self.elapsed >= self.windowLength {
                    self.pause()
                }
            }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                NSLog("player script failed: \(error.localizedDescription)")
            }
        }
    }

    /// Loaded once; `loadVideo` is then called per release.
    private static let playerHTML = """
    <!doctype html>
    <html><body style="margin:0;background:#000">
    <div id="player"></div>
    <script src="https://www.youtube.com/iframe_api"></script>
    <script>
      let player;
      let pending = null;
      function onYouTubeIframeAPIReady() {
        player = new YT.Player('player', {
          height: '1', width: '1',
          playerVars: { controls: 0, disablekb: 1, playsinline: 1 },
          events: {
            onReady: () => { if (pending) { player.loadVideoById(pending); pending = null; } },
            onError: () => { window.webkit.messageHandlers.playerError.postMessage('error'); }
          }
        });
      }
      function loadVideo(id) {
        if (player && player.loadVideoById) { player.loadVideoById(id); }
        else { pending = id; }
      }
    </script>
    </body></html>
    """
}

extension PlayerController: WKNavigationDelegate {}

extension PlayerController: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            // A blocked or removed video is not an error to show — just move on.
            if !self.advanceAfterFailure() {
                self.videoUnavailable = true
            }
        }
    }
}

/// Hosts the hidden web view so it stays in the view hierarchy and keeps playing.
struct PlayerHost: NSViewRepresentable {
    let controller: PlayerController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
