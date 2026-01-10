#!/bin/bash
set -e

# Build minimal LGPL FFmpeg with VideoToolbox for macOS
# Output: bin/ffmpeg and bin/ffprobe

FFMPEG_VERSION="7.1"
BUILD_DIR="/tmp/ffmpeg-build-$$"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"

echo "=== Building FFmpeg $FFMPEG_VERSION (LGPL + VideoToolbox) ==="
echo "Output directory: $OUTPUT_DIR"

# Create build directory
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Download FFmpeg source
echo "==> Downloading FFmpeg source..."
curl -L "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" -o ffmpeg.tar.xz
tar xf ffmpeg.tar.xz
cd "ffmpeg-${FFMPEG_VERSION}"

# Configure for minimal LGPL build with VideoToolbox
echo "==> Configuring FFmpeg..."
./configure \
  --prefix="$BUILD_DIR/install" \
  --enable-static \
  --disable-shared \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-autodetect \
  --disable-network \
  --enable-videotoolbox \
  --enable-audiotoolbox \
  --enable-encoder=h264_videotoolbox \
  --enable-encoder=hevc_videotoolbox \
  --enable-encoder=aac_at \
  --enable-decoder=h264 \
  --enable-decoder=hevc \
  --enable-decoder=aac \
  --enable-decoder=ac3 \
  --enable-decoder=mp3 \
  --enable-decoder=vorbis \
  --enable-decoder=opus \
  --enable-decoder=flac \
  --enable-decoder=pcm_s16le \
  --enable-decoder=pcm_s24le \
  --enable-decoder=pcm_s32le \
  --enable-decoder=pcm_f32le \
  --enable-demuxer=mov \
  --enable-demuxer=matroska \
  --enable-demuxer=avi \
  --enable-demuxer=mp3 \
  --enable-demuxer=flac \
  --enable-demuxer=ogg \
  --enable-demuxer=wav \
  --enable-muxer=hls \
  --enable-muxer=mpegts \
  --enable-muxer=segment \
  --enable-muxer=null \
  --enable-protocol=file \
  --enable-protocol=pipe \
  --enable-filter=scale \
  --enable-filter=aresample \
  --enable-filter=null \
  --enable-filter=anull \
  --enable-bsf=h264_mp4toannexb \
  --enable-bsf=hevc_mp4toannexb \
  --extra-cflags="-mmacosx-version-min=13.0 -O3" \
  --extra-ldflags="-mmacosx-version-min=13.0" \
  --cc=clang

# Build
echo "==> Building FFmpeg (this may take a few minutes)..."
make -j$(sysctl -n hw.ncpu)
make install

# Copy binaries to output
echo "==> Copying binaries to $OUTPUT_DIR..."
mkdir -p "$OUTPUT_DIR"
cp "$BUILD_DIR/install/bin/ffmpeg" "$OUTPUT_DIR/"
cp "$BUILD_DIR/install/bin/ffprobe" "$OUTPUT_DIR/"

# Strip binaries to reduce size
strip "$OUTPUT_DIR/ffmpeg"
strip "$OUTPUT_DIR/ffprobe"

# Show results
echo ""
echo "=== Build complete ==="
ls -lh "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"
echo ""
echo "Verifying VideoToolbox encoder:"
"$OUTPUT_DIR/ffmpeg" -hide_banner -encoders 2>/dev/null | grep videotoolbox || echo "WARNING: VideoToolbox not found!"
echo ""
echo "License check (should say LGPL):"
"$OUTPUT_DIR/ffmpeg" -hide_banner -version 2>/dev/null | head -5

# Cleanup
echo ""
echo "==> Cleaning up build directory..."
rm -rf "$BUILD_DIR"

echo ""
echo "Done! Binaries are in: $OUTPUT_DIR"
