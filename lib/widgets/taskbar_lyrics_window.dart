import 'package:flutter/material.dart';

import '../services/desktop/desktop_window_service.dart';

class TaskbarLyricsWindow extends StatelessWidget {
  const TaskbarLyricsWindow(
      {super.key, this.state = const LyricsWindowState()});
  final LyricsWindowState state;
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          color: Colors.transparent,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                    text: state.currentLine,
                    style: const TextStyle(
                        color: Color(0xff63d6c6), fontWeight: FontWeight.w600)),
                if (state.nextLine.isNotEmpty)
                  TextSpan(
                      text: '  ${state.nextLine}',
                      style: const TextStyle(color: Colors.white70)),
              ],
              style: const TextStyle(fontFamily: 'Segoe UI', fontSize: 13),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
}
