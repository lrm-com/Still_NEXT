import 'package:flutter/material.dart';

import '../services/audio/replay_gain.dart';

class TagEditorDialog extends StatefulWidget {
  const TagEditorDialog(
      {super.key, required this.path, this.editor = const AudioTagEditor()});
  final String path;
  final AudioTagEditor editor;
  @override
  State<TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<TagEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  AudioTags _tags = const AudioTags();
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _tags = await widget.editor.read(widget.path);
      for (final entry in _values(_tags).entries) {
        _controllers[entry.key] = TextEditingController(text: entry.value);
      }
    } on Object catch (error) {
      _error = error.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.editor.write(
          widget.path,
          _tags.copyWith(
              title: _text('title'),
              artist: _text('artist'),
              album: _text('album'),
              albumArtist: _text('albumArtist'),
              year: int.tryParse(_text('year') ?? ''),
              genre: _text('genre'),
              trackNumber: int.tryParse(_text('trackNumber') ?? ''),
              discNumber: int.tryParse(_text('discNumber') ?? ''),
              comment: _text('comment')));
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
    if (mounted) setState(() => _saving = false);
  }

  String? _text(String key) => _controllers[key]?.text.trim().isEmpty == true
      ? null
      : _controllers[key]?.text.trim();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('编辑标签'),
        content: SizedBox(
            width: 500,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Form(
                    key: _formKey,
                    child: SingleChildScrollView(
                        child: Column(children: [
                      if (_error != null)
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      for (final field in _fields)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: TextFormField(
                                controller: _controllers[field.key],
                                decoration:
                                    InputDecoration(labelText: field.label),
                                keyboardType: field.numeric
                                    ? TextInputType.number
                                    : TextInputType.text,
                                validator: field.numeric
                                    ? (value) => value != null &&
                                            value.trim().isNotEmpty &&
                                            int.tryParse(value.trim()) == null
                                        ? '请输入数字'
                                        : null
                                    : null))
                    ])))),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存'))
        ],
      );

  static const _fields = [
    (key: 'title', label: '标题', numeric: false),
    (key: 'artist', label: '艺术家', numeric: false),
    (key: 'album', label: '专辑', numeric: false),
    (key: 'albumArtist', label: '专辑艺术家', numeric: false),
    (key: 'year', label: '年份', numeric: true),
    (key: 'genre', label: '流派', numeric: false),
    (key: 'trackNumber', label: '轨道号', numeric: true),
    (key: 'discNumber', label: '碟片号', numeric: true),
    (key: 'comment', label: '评论', numeric: false),
  ];

  static Map<String, String> _values(AudioTags tags) => {
        'title': tags.title ?? '',
        'artist': tags.artist ?? '',
        'album': tags.album ?? '',
        'albumArtist': tags.albumArtist ?? '',
        'year': tags.year?.toString() ?? '',
        'genre': tags.genre ?? '',
        'trackNumber': tags.trackNumber?.toString() ?? '',
        'discNumber': tags.discNumber?.toString() ?? '',
        'comment': tags.comment ?? ''
      };
}

class BatchTagEditorDialog extends StatefulWidget {
  const BatchTagEditorDialog(
      {super.key, required this.paths, this.editor = const BatchTagEditor()});
  final List<String> paths;
  final BatchTagEditor editor;
  @override
  State<BatchTagEditorDialog> createState() => _BatchTagEditorDialogState();
}

class _BatchTagEditorDialogState extends State<BatchTagEditorDialog> {
  final _artist = TextEditingController();
  final _album = TextEditingController();
  final _genre = TextEditingController();
  bool _saving = false;
  double _progress = 0;
  @override
  void dispose() {
    _artist.dispose();
    _album.dispose();
    _genre.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    setState(() {
      _saving = true;
      _progress = 0;
    });
    await widget.editor.update(
        widget.paths,
        (_, current) => current.copyWith(
            artist: _artist.text.trim().isEmpty ? null : _artist.text.trim(),
            album: _album.text.trim().isEmpty ? null : _album.text.trim(),
            genre: _genre.text.trim().isEmpty ? null : _genre.text.trim()),
        onProgress: (completed, total) {
      if (mounted) {
        setState(() => _progress = total == 0 ? 1 : completed / total);
      }
    });
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text('批量编辑（${widget.paths.length} 首）'),
          content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: _artist,
                    decoration: const InputDecoration(labelText: '艺术家（留空不修改）')),
                TextField(
                    controller: _album,
                    decoration: const InputDecoration(labelText: '专辑（留空不修改）')),
                TextField(
                    controller: _genre,
                    decoration: const InputDecoration(labelText: '流派（留空不修改）')),
                if (_saving)
                  Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator(value: _progress))
              ])),
          actions: [
            TextButton(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: _saving ? null : _apply, child: const Text('应用'))
          ]);
}
