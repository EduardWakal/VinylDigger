import Combine
import SwiftUI
import WebKit
import VinylDiggerKit

/// Drives a hidden WKWebView running the YouTube IFrame Player API.
///
/// Position and duration are pushed out of the page — the controller never polls
/// and never counts time itself. A release plays through its videos in order and
/// stops at the end, leaving the card waiting for a decision.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentVideoID: String?
    @Published private(set) var currentIndex = 0
    @Published private(set) var videoUnavailable = false

    /// While the user drags the slider, incoming positions are dropped so the
    /// knob does not fight the updates still arriving from the page.
    var isScrubbing = false

    private var cursor = PlaylistCursor(videoIDs: [])

    /// The page needs a real origin of its own. Hosting it on `https://www.youtube.com`
    /// makes every embed fail with YouTube error 152 — the API refuses to serve an
    /// embed whose embedder claims to be YouTube itself.
    private static let embedOrigin = "https://vinyldigger.local"

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
        webView.configuration.userContentController.add(self, name: "player")
        webView.loadHTMLString(Self.playerHTML, baseURL: URL(string: Self.embedOrigin))
    }

    func load(videoIDs: [String]) {
        cursor = PlaylistCursor(videoIDs: videoIDs)
        videoUnavailable = videoIDs.isEmpty
        position = 0
        duration = 0
        currentIndex = 0
        playCurrent()
    }

    func togglePlayPause() {
        isPlaying ? evaluate("player.pauseVideo()") : evaluate("player.playVideo()")
    }

    func seek(to target: TimeInterval) {
        guard currentVideoID != nil else { return }
        let clamped = min(max(0, target), duration > 0 ? duration : target)
        position = clamped
        evaluate("player.seekTo(\(clamped), true)")
    }

    func seek(by delta: TimeInterval) {
        seek(to: position + delta)
    }

    func restart() {
        seek(to: 0)
    }

    func play(index: Int) {
        guard let id = cursor.select(index) else { return }
        startVideo(id)
    }

    func nextVideo() {
        guard let id = cursor.advance() else { return }
        startVideo(id)
    }

    // MARK: - Private

    private func playCurrent() {
        guard let id = cursor.current else {
            videoUnavailable = true
            currentVideoID = nil
            return
        }
        startVideo(id)
    }

    private func startVideo(_ id: String) {
        currentVideoID = id
        currentIndex = cursor.index
        videoUnavailable = false
        position = 0
        duration = 0
        evaluate("loadVideo('\(id)')")
    }

    private func handleState(_ state: Int, time: TimeInterval, length: TimeInterval) {
        if !isScrubbing { position = time }
        if length > 0 { duration = length }
        isPlaying = state == 1
        // 0 is ENDED — move on to the next side of the record.
        if state == 0 { advanceAfterEnd() }
    }

    private func advanceAfterEnd() {
        guard let id = cursor.advance() else {
            isPlaying = false
            return
        }
        startVideo(id)
    }

    private func handleError() {
        // A blocked or removed video is not an error to show — just move on.
        guard let id = cursor.advance() else {
            videoUnavailable = true
            isPlaying = false
            return
        }
        startVideo(id)
    }

    private func evaluate(_ script: String) {
        // The trailing `null` keeps WebKit from rejecting the undefined return
        // value of every YT API call with WKErrorJavaScriptResultTypeIsUnsupported.
        webView.evaluateJavaScript(script + ";null") { _, error in
            if let error {
                NSLog("player script failed: \(error.localizedDescription)")
            }
        }
    }

    /// Loaded once; `loadVideo` is then called per release.
    private static var playerHTML: String {
        """
        <!doctype html>
        <html><body style="margin:0;background:#000">
        <div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
          let player;
          let pending = null;
          let timer = null;

          function post(payload) {
            window.webkit.messageHandlers.player.postMessage(JSON.stringify(payload));
          }

          function pushState() {
            if (!player || !player.getPlayerState) { return; }
            post({
              kind: 'state',
              state: player.getPlayerState(),
              t: player.getCurrentTime() || 0,
              d: player.getDuration() || 0
            });
          }

          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              height: '1', width: '1',
              playerVars: {
                controls: 0, disablekb: 1, playsinline: 1,
                enablejsapi: 1, origin: '\(embedOrigin)'
              },
              events: {
                onReady: () => { if (pending) { player.loadVideoById(pending); pending = null; } },
                onStateChange: () => {
                  pushState();
                  if (timer) { clearInterval(timer); timer = null; }
                  if (player.getPlayerState() === 1) { timer = setInterval(pushState, 250); }
                },
                onError: (e) => { post({ kind: 'error', code: e.data }); }
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
}

extension PlayerController: WKNavigationDelegate {}

extension PlayerController: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            let raw = message.body as? String,
            let data = raw.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = payload["kind"] as? String
        else { return }

        Task { @MainActor in
            switch kind {
            case "state":
                self.handleState(
                    payload["state"] as? Int ?? -1,
                    time: payload["t"] as? Double ?? 0,
                    length: payload["d"] as? Double ?? 0
                )
            case "error":
                self.handleError()
            default:
                break
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
