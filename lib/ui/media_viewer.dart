import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/media_kind.dart';

/// Fullscreen image / gif viewer: pinch or scroll to zoom, drag to pan.
class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.path, required this.title, this.onMenu});
  final String path;
  final String title;
  final void Function(Offset globalPosition)? onMenu;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
      ),
      body: GestureDetector(
        onSecondaryTapUp: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
        onLongPressStart: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
        child: Center(
          child: InteractiveViewer(
            maxScale: 8,
            child: Image.file(File(path),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Text('Cannot show this image',
                    style: TextStyle(color: Colors.white))),
          ),
        ),
      ),
    );
  }
}

/// Fullscreen video page (mp4, mkv, webm) with the player's own controls.
class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.path, required this.title, this.onMenu});
  final String path;
  final String title;
  final void Function(Offset globalPosition)? onMenu;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.path));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
      ),
      body: GestureDetector(
        onSecondaryTapUp: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
        onLongPressStart: widget.onMenu == null ? null : (d) => widget.onMenu!(d.globalPosition),
        child: Center(child: Video(controller: _video)),
      ),
    );
  }
}

/// Only one audio player plays at a time.
_AudioInlineState? _activeAudio;

/// Small inline player for mp3 / m4a: play or pause, seek bar, time.
class AudioInline extends StatefulWidget {
  const AudioInline({super.key, required this.path});
  final String path;

  @override
  State<AudioInline> createState() => _AudioInlineState();
}

class _AudioInlineState extends State<AudioInline> {
  Player? _player;
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  final _subs = <dynamic>[];

  Future<void> _toggle() async {
    if (_player == null) {
      final pl = Player();
      _player = pl;
      _subs
        ..add(pl.stream.playing.listen((v) => mounted ? setState(() => _playing = v) : null))
        ..add(pl.stream.position.listen((v) => mounted ? setState(() => _pos = v) : null))
        ..add(pl.stream.duration.listen((v) => mounted ? setState(() => _dur = v) : null))
        ..add(pl.stream.completed.listen((done) async {
          if (done && mounted) {
            await pl.pause();
            await pl.seek(Duration.zero);
          }
        }));
      await pl.open(Media(widget.path), play: false);
    }
    if (_playing) {
      await _player!.pause();
    } else {
      if (_activeAudio != this) _activeAudio?._player?.pause();
      _activeAudio = this;
      await _player!.play();
    }
  }

  @override
  void dispose() {
    if (_activeAudio == this) _activeAudio = null;
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _dur.inMilliseconds;
    final value = total <= 0 ? 0.0 : (_pos.inMilliseconds / total).clamp(0.0, 1.0);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Row(children: [
        IconButton(
          tooltip: _playing ? 'Pause' : 'Play',
          onPressed: _toggle,
          icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle, size: 36),
        ),
        Expanded(
          child: Slider(
            value: value,
            onChanged: _player == null || total <= 0
                ? null
                : (v) => _player!.seek(Duration(milliseconds: (v * total).round())),
          ),
        ),
        Text('${formatDuration(_pos)} / ${formatDuration(_dur)}',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
