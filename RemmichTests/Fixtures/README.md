# Video loader fixtures

These generated test patterns contain no user media. Both are two-second H.264 videos; one stores the MP4 `moov` atom after the media data and the other moves it before the media data. The loader tests serve them through a local URLProtocol with bounded byte-range responses.

Recreate from the repository root with FFmpeg:

```sh
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=30 -t 2 -c:v libx264 -preset ultrafast -crf 24 -threads 2 -filter_threads 2 -an -y RemmichTests/Fixtures/video-tail-moov.mp4
ffmpeg -i RemmichTests/Fixtures/video-tail-moov.mp4 -c copy -movflags +faststart -threads 2 -y RemmichTests/Fixtures/video-fast-start.mp4
```
