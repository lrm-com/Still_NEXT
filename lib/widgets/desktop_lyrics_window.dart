import 'dart:async';

import 'package:flutter/material.dart';

import '../services/desktop/desktop_window_service.dart';
import 'karaoke_line.dart';
import 'lyrics_effects.dart';

class DesktopLyricsWindow extends StatefulWidget {
  const DesktopLyricsWindow(
      {super.key,
      this.windowService,
      this.initialState = const LyricsWindowState()});
  final DesktopWindowService? windowService;
  final LyricsWindowState initialState;
  @override
  State<DesktopLyricsWindow> createState() => _DesktopLyricsWindowState();
}

class _DesktopLyricsWindowState extends State<DesktopLyricsWindow> {
  late LyricsWindowState _state = widget.initialState;
  StreamSubscription<LyricsWindowState>? _subscription;
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    _subscription = (widget.windowService ?? DesktopWindowService())
        .lyricUpdates
        .listen((state) {
      if (mounted) setState(() => _state = state);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: _locked,
        child: Opacity(
          opacity: _state.opacity,
          child: LyricsEffectsStack(
            settings:
                const LyricsBackgroundSettings(mode: LyricsBackgroundMode.none),
            child: Material(
              color: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_state.currentLine,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 8)
                              ])),
                      if (_state.translation != null)
                        Text(_state.translation!,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 17)),
                      if (_state.nextLine.isNotEmpty)
                        Text(_state.nextLine,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 19)),
                      if (!_locked)
                        Align(
                            alignment: Alignment.bottomRight,
                            child: IconButton(
                                onPressed: () {
                                  setState(() => _locked = true);
                                },
                                icon: const Icon(Icons.lock_open,
                                    color: Colors.white70))),
                    ]),
              ),
            ),
          ),
        ),
      );
}

class KaraokeLyricsWindow extends StatelessWidget {
  const KaraokeLyricsWindow(
      {super.key, required this.line, required this.position});
  final KaraokeLine line;
  final Duration position;
  @override
  Widget build(BuildContext context) => Material(
      color: Colors.transparent,
      child: Center(child: KaraokeLineView(line: line, position: position)));
}
