#!/bin/bash
set -uo pipefail

SRC="/Users/aquarius/Desktop/Music/music"
DST="/Users/aquarius/Desktop/music-compressed"
TARGET_SIZE_MB=48  # target under 50MB with margin

echo "=== Copying music folder to Desktop ==="
echo "Source: $SRC"
echo "Destination: $DST"
echo ""

# Create destination directory
mkdir -p "$DST"

# Copy directory structure and all non-.mov, non-.git files
echo "--- Copying directory structure and non-.mov files ---"
rsync -av --exclude='.git' --exclude='*.mov' --exclude='.DS_Store' --exclude='copy_music.sh' "$SRC/" "$DST/"
echo ""

# Count .mov files
MOV_FILES=()
while IFS= read -r -d '' f; do
    MOV_FILES+=("$f")
done < <(find "$SRC" -name '*.mov' -not -path '*/.git/*' -print0 | sort -z)

MOV_COUNT=${#MOV_FILES[@]}
echo "--- Processing $MOV_COUNT .mov files ---"
echo ""

FAILED=0
SUCCEEDED=0

for i in "${!MOV_FILES[@]}"; do
    src_file="${MOV_FILES[$i]}"
    CURRENT=$((i + 1))

    # Compute relative path
    rel_path="${src_file#$SRC/}"
    dst_file="$DST/$rel_path"
    dst_dir="$(dirname "$dst_file")"
    base_name="$(basename "$dst_file" .mov)"

    mkdir -p "$dst_dir"

    echo "[$CURRENT/$MOV_COUNT] Processing: $rel_path"

    # --- Step 1: Extract cover image at mid-duration ---
    duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 "$src_file" 2>/dev/null)
    if [ -z "$duration" ] || [ "$duration" = "0" ] || [ "$duration" = "N/A" ]; then
        # Fallback: try stream duration
        duration=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 "$src_file" 2>/dev/null | head -1)
    fi
    if [ -z "$duration" ] || [ "$duration" = "0" ] || [ "$duration" = "N/A" ]; then
        echo "  WARNING: Could not determine duration, defaulting to 10s"
        duration="10"
    fi

    mid_time=$(python3 -c "print(float('$duration') / 2)")
    cover_file="$dst_dir/${base_name}_cover.jpg"

    echo "  Extracting cover at ${mid_time}s (duration: ${duration}s)"
    if ffmpeg -y -ss "$mid_time" -i "$src_file" -map 0:v:0 -frames:v 1 -q:v 2 "$cover_file" 2>/dev/null; then
        echo "  ✓ Cover saved: ${cover_file#$DST/}"
    else
        echo "  ✗ Cover extraction failed"
    fi

    # --- Step 2: Compress video to under 50MB ---
    src_size_bytes=$(stat -f%z "$src_file" 2>/dev/null || stat -c%s "$src_file" 2>/dev/null)
    src_size_mb=$((src_size_bytes / 1048576))

    if [ "$src_size_mb" -le "$TARGET_SIZE_MB" ]; then
        echo "  File already under ${TARGET_SIZE_MB}MB (${src_size_mb}MB), copying as-is"
        cp "$src_file" "$dst_file"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo "  Original size: ${src_size_mb}MB -> compressing to <50MB"

        # Calculate target bitrate
        audio_bitrate=128  # kbps
        video_bitrate_kbps=$(python3 -c "
dur = float('$duration')
target_bits = $TARGET_SIZE_MB * 8 * 1024 * 1024
audio_bits = $audio_bitrate * 1000 * dur
video_bits = target_bits - audio_bits
vbr = max(200, int(video_bits / dur / 1000))
print(vbr)
")

        echo "  Target video bitrate: ${video_bitrate_kbps}k, audio: ${audio_bitrate}k"

        # Single-pass encoding with explicit stream mapping
        # -map 0:v:0 selects only the first video stream (skips embedded MJPEG thumbnail)
        # -map 0:a:0 selects only the first audio stream
        if ffmpeg -y -i "$src_file" \
            -map 0:v:0 -map 0:a:0 \
            -c:v libx264 -b:v "${video_bitrate_kbps}k" -maxrate "$((video_bitrate_kbps * 2))k" -bufsize "$((video_bitrate_kbps * 4))k" \
            -preset medium -crf 28 \
            -c:a aac -b:a "${audio_bitrate}k" \
            -movflags +faststart \
            -pix_fmt yuv420p \
            "$dst_file" 2>/dev/null; then

            final_size_bytes=$(stat -f%z "$dst_file" 2>/dev/null || stat -c%s "$dst_file" 2>/dev/null)
            final_size_mb=$((final_size_bytes / 1048576))
            echo "  ✓ Compressed: ${src_size_mb}MB -> ${final_size_mb}MB"

            # If still over 50MB, re-encode with lower bitrate
            if [ "$final_size_mb" -gt 49 ]; then
                echo "  Still over 50MB, re-encoding with stricter bitrate..."
                lower_bitrate=$((video_bitrate_kbps * 45 / final_size_mb))
                if ffmpeg -y -i "$src_file" \
                    -map 0:v:0 -map 0:a:0 \
                    -c:v libx264 -b:v "${lower_bitrate}k" -maxrate "$((lower_bitrate * 2))k" -bufsize "$((lower_bitrate * 4))k" \
                    -preset medium -crf 32 \
                    -c:a aac -b:a "${audio_bitrate}k" \
                    -movflags +faststart \
                    -pix_fmt yuv420p \
                    "$dst_file" 2>/dev/null; then
                    final_size_bytes=$(stat -f%z "$dst_file" 2>/dev/null || stat -c%s "$dst_file" 2>/dev/null)
                    final_size_mb=$((final_size_bytes / 1048576))
                    echo "  ✓ Re-compressed: ${final_size_mb}MB"
                else
                    echo "  ✗ Re-compression failed"
                fi
            fi
            SUCCEEDED=$((SUCCEEDED + 1))
        else
            echo "  ✗ Compression FAILED"
            FAILED=$((FAILED + 1))
        fi
    fi

    echo ""
done

echo "=== Done! ==="
echo "Output: $DST"
echo "Succeeded: $SUCCEEDED / $MOV_COUNT"
if [ "$FAILED" -gt 0 ]; then
    echo "Failed: $FAILED"
fi
