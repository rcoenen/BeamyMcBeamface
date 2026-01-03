import Foundation

public struct MediaInfo {
    public let duration: Double
    public let videoCodec: String?
    public let audioCodec: String?
    public let width: Int?
    public let height: Int?

    public var durationFormatted: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    public var needsTranscoding: Bool {
        // Chromecast supports H.264, VP8, VP9 for video
        // and AAC, MP3, Vorbis, Opus for audio
        let supportedVideoCodecs = ["h264", "vp8", "vp9"]
        let supportedAudioCodecs = ["aac", "mp3", "vorbis", "opus"]

        let videoOk = videoCodec.map { supportedVideoCodecs.contains($0.lowercased()) } ?? true
        let audioOk = audioCodec.map { supportedAudioCodecs.contains($0.lowercased()) } ?? true

        return !videoOk || !audioOk
    }
}

public enum FFmpeg {
    private static var config: Config.FFmpegConfig {
        (try? Config.load().ffmpeg) ?? .default
    }

    public static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: config.ffmpegPath)
    }

    private static func getFFmpegPath() -> String {
        config.ffmpegPath
    }

    private static func getFFprobePath() -> String {
        config.ffprobePath
    }

    public static func getMediaInfo(file: URL) throws -> MediaInfo {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: getFFprobePath())
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            file.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FFmpegError.invalidOutput
        }

        let format = json["format"] as? [String: Any]
        let streams = json["streams"] as? [[String: Any]] ?? []

        let duration = (format?["duration"] as? String).flatMap { Double($0) } ?? 0

        var videoCodec: String?
        var audioCodec: String?
        var width: Int?
        var height: Int?

        for stream in streams {
            let codecType = stream["codec_type"] as? String
            let codecName = stream["codec_name"] as? String

            if codecType == "video" && videoCodec == nil {
                videoCodec = codecName
                width = stream["width"] as? Int
                height = stream["height"] as? Int
            } else if codecType == "audio" && audioCodec == nil {
                audioCodec = codecName
            }
        }

        return MediaInfo(
            duration: duration,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            width: width,
            height: height
        )
    }

    public static func transcode(
        input: URL,
        output: URL,
        onProgress: ((Double) -> Void)? = nil
    ) throws {
        let cfg = config
        let process = Process()
        process.executableURL = URL(fileURLWithPath: getFFmpegPath())
        process.arguments = [
            "-i", input.path,
            "-c:v", "libx264",
            "-preset", cfg.preset,
            "-crf", "\(cfg.crf)",
            "-c:a", "aac",
            "-b:a", cfg.audioBitrate,
            "-movflags", "+faststart",
            "-y",
            output.path
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw FFmpegError.transcodingFailed(errorMessage)
        }
    }

    /// Start an HTTP server that streams transcoded content on-the-fly
    public static func startStreamingTranscode(
        input: URL,
        port: Int,
        mediaInfo: MediaInfo
    ) throws -> TranscodeServer {
        try TranscodeServer(input: input, port: port, mediaInfo: mediaInfo)
    }
}

public enum FFmpegError: Error, CustomStringConvertible {
    case notFound
    case invalidOutput
    case transcodingFailed(String)

    public var description: String {
        switch self {
        case .notFound:
            return "FFmpeg not found"
        case .invalidOutput:
            return "Failed to parse FFmpeg output"
        case .transcodingFailed(let message):
            return "Transcoding failed: \(message)"
        }
    }
}
