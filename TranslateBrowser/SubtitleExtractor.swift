import Foundation

enum SubtitleExtractor {
    // window.ytInitialPlayerResponse only reflects the video that was present in the initial
    // HTML payload; YouTube is a single-page app, so navigating to another video in-page does
    // not refresh that global. The in-page player instance's own getPlayerResponse() always
    // reflects whatever is currently loaded, so prefer it and fall back for the very first load.
    static let captionTracksJS = """
    (function() {
      function liveResponse() {
        try {
          var player = document.getElementById('movie_player');
          if (player && typeof player.getPlayerResponse === 'function') {
            var r = player.getPlayerResponse();
            if (r && r.captions) return r;
          }
        } catch (e) {}
        return null;
      }
      var pr = liveResponse();
      if (!pr) {
        pr = window.ytInitialPlayerResponse;
        if ((!pr || !pr.captions) && window.ytplayer && ytplayer.config && ytplayer.config.args && ytplayer.config.args.player_response) {
          try { pr = JSON.parse(ytplayer.config.args.player_response); } catch (e) {}
        }
      }
      var tracks = pr && pr.captions && pr.captions.playerCaptionsTracklistRenderer && pr.captions.playerCaptionsTracklistRenderer.captionTracks;
      return tracks ? JSON.stringify(tracks) : "[]";
    })()
    """

    static let currentTimeJS = "(document.querySelector('video') ? document.querySelector('video').currentTime : -1)"

    static func fetchSubtitles(from track: CaptionTrack) async throws -> [Subtitle] {
        let urlString = track.baseUrl.replacingOccurrences(of: "\\u0026", with: "&")
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return TimedTextParser().parse(data)
    }
}

final class TimedTextParser: NSObject, XMLParserDelegate {
    private var subtitles: [Subtitle] = []
    private var currentText = ""
    private var currentStart: Double = 0
    private var currentDur: Double = 0
    private var inText = false

    func parse(_ data: Data) -> [Subtitle] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return subtitles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "text" {
            inText = true
            currentText = ""
            currentStart = Double(attributeDict["start"] ?? "") ?? 0
            currentDur = Double(attributeDict["dur"] ?? "") ?? 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "text" {
            inText = false
            let cleaned = currentText
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                subtitles.append(Subtitle(start: currentStart, duration: currentDur, text: cleaned))
            }
        }
    }
}
