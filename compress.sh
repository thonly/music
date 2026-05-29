```bash id="4x8nke"
find . -type f \( -iname "*.mov" \) | while IFS= read -r f; do
  dir="$(dirname "$f")"
  filename="$(basename "$f")"
  base="${filename%.*}"

  echo "Processing: $f"

  # Get duration in seconds
  duration=$(ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$f")

  # Skip invalid files
  [ -z "$duration" ] && continue

  # Midpoint timestamp
  midpoint=$(awk "BEGIN {print $duration / 2}")

  # Capture cover image
  ffmpeg -y -ss "$midpoint" -i "$f" \
    -frames:v 1 \
    "$dir/${base}.jpg"

  # Extract MP3
  ffmpeg -y -i "$f" \
    -vn \
    -acodec libmp3lame \
    -q:a 2 \
    "$dir/${base}.mp3"

  # Compress video to target < 40MB
  target_size_mb=40
  audio_bitrate_k=128

  video_bitrate_k=$(awk \
    -v size="$target_size_mb" \
    -v duration="$duration" \
    -v audio="$audio_bitrate_k" \
    'BEGIN {
      total_kbits = size * 8192
      video_kbits = (total_kbits / duration) - audio
      if (video_kbits < 300) video_kbits = 300
      print int(video_kbits)
    }')

  output="$dir/${base}.mp4"

  ffmpeg -y -i "$f" \
    -c:v libx264 \
    -b:v "${video_bitrate_k}k" \
    -preset medium \
    -movflags +faststart \
    -c:a aac \
    -b:a "${audio_bitrate_k}k" \
    "$output"

  actual_size_mb=$(awk "BEGIN {print $(stat -f%z "$output" 2>/dev/null || stat -c%s "$output") / 1024 / 1024}")

  echo "Created: $output (${actual_size_mb} MB)"
  echo
done
```
