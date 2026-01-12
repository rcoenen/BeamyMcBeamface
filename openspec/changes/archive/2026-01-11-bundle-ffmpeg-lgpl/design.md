# Design: Bundle LGPL FFmpeg

## FFmpeg Build Configuration

```bash
./configure \
  --prefix=/tmp/ffmpeg-build \
  --enable-static \
  --disable-shared \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-network \
  --disable-autodetect \
  --enable-videotoolbox \
  --enable-audiotoolbox \
  --enable-encoder=h264_videotoolbox \
  --enable-encoder=hevc_videotoolbox \
  --enable-encoder=aac_at \
  --enable-decoder=h264 \
  --enable-decoder=hevc \
  --enable-decoder=aac \
  --enable-decoder=mp3 \
  --enable-decoder=vorbis \
  --enable-decoder=opus \
  --enable-decoder=flac \
  --enable-decoder=pcm_* \
  --enable-demuxer=mov \
  --enable-demuxer=matroska \
  --enable-demuxer=avi \
  --enable-demuxer=mp3 \
  --enable-demuxer=flac \
  --enable-demuxer=ogg \
  --enable-muxer=hls \
  --enable-muxer=mpegts \
  --enable-muxer=segment \
  --enable-protocol=file \
  --enable-filter=scale \
  --enable-filter=aresample \
  --extra-cflags="-mmacosx-version-min=13.0" \
  --extra-ldflags="-mmacosx-version-min=13.0"
```

## Binary Location

```
BeamyMcBeamface.app/
└── Contents/
    └── MacOS/
        ├── Beamy McBeamface  (main executable)
        ├── ffmpeg            (bundled)
        └── ffprobe           (bundled)
```

## Path Resolution Order

1. `Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffmpeg")`
2. `/opt/homebrew/bin/ffmpeg` (ARM Mac)
3. `/usr/local/bin/ffmpeg` (Intel Mac)
4. `which ffmpeg` fallback

## License Compliance

### Required Attribution (LGPL 2.1+)
- In-app: "This software uses FFmpeg (https://ffmpeg.org) under the LGPL v2.1"
- Bundle: Include `LICENSE-FFMPEG.txt` with full LGPL text
- README: Link to FFmpeg source

### What We Avoid (GPL)
- libx264, libx265 (use VideoToolbox instead)
- libfdk-aac (use AudioToolbox instead)
- Any `--enable-gpl` flag

## VideoToolbox vs libx264

| Aspect | VideoToolbox | libx264 |
|--------|--------------|---------|
| License | Apple (free) | GPL |
| Speed | Hardware accelerated | Software |
| Quality | Good (Apple Silicon) | Excellent |
| Size | 0 MB (system) | ~5 MB |
| Power | Low | High |

For streaming to Chromecast, VideoToolbox quality is more than sufficient.
