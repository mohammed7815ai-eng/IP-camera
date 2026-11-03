import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ai/enhance.dart';

/// Before/after enhancement of a saved picture. The original is never
/// changed; the result is saved as a new file marked "ENHANCED".
class EnhancePage extends StatefulWidget {
  const EnhancePage({super.key, required this.file});
  final File file;

  @override
  State<EnhancePage> createState() => _EnhancePageState();
}

class _EnhancePageState extends State<EnhancePage> {
  Uint8List? _original;
  Uint8List? _result;
  bool _busy = false;
  double _split = 0.5;
  bool _levels = true, _lowLight = true, _denoise = true, _sharpen = true, _upscale = false;

  @override
  void initState() {
    super.initState();
    widget.file.readAsBytes().then((b) {
      if (mounted) setState(() => _original = b);
      _run();
    });
  }

  Future<void> _run() async {
    final src = _original;
    if (src == null) return;
    setState(() => _busy = true);
    try {
      final out = await enhanceJpeg(
        src,
        EnhanceOptions(autoLevels: _levels, lowLight: _lowLight, denoise: _denoise, sharpen: _sharpen, upscale2x: _upscale),
      );
      if (mounted) setState(() => _result = out);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not enhance: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final r = _result;
    if (r == null) return;
    final p = widget.file.path;
    final dot = p.lastIndexOf('.');
    final out = File('${dot > 0 ? p.substring(0, dot) : p}_enhanced.jpg');
    await out.writeAsBytes(r, flush: true);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${out.path}')));
  }

  Widget _toggle(String label, bool v, ValueChanged<bool> on) => FilterChip(
        label: Text(label),
        selected: v,
        onSelected: _busy
            ? null
            : (x) {
                on(x);
                _run();
              },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Enhance'),
        actions: [IconButton(tooltip: 'Save copy', icon: const Icon(Icons.save_alt), onPressed: _result == null || _busy ? null : _save)],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            _toggle('Low light', _lowLight, (v) => _lowLight = v),
            _toggle('Denoise', _denoise, (v) => _denoise = v),
            _toggle('Auto contrast', _levels, (v) => _levels = v),
            _toggle('Sharpen', _sharpen, (v) => _sharpen = v),
            _toggle('Upscale 2x', _upscale, (v) => _upscale = v),
          ]),
        ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: _original == null
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(builder: (context, box) {
                  final after = _result ?? _original!;
                  return GestureDetector(
                    onHorizontalDragUpdate: (d) => setState(() => _split = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
                    onTapDown: (d) => setState(() => _split = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0)),
                    child: Stack(fit: StackFit.expand, children: [
                      Image.memory(after, fit: BoxFit.contain, gaplessPlayback: true),
                      ClipRect(
                        clipper: _LeftClip(_split),
                        child: Image.memory(_original!, fit: BoxFit.contain, gaplessPlayback: true),
                      ),
                      Positioned(left: box.maxWidth * _split - 1, top: 0, bottom: 0, child: Container(width: 2, color: Colors.white70)),
                      const Positioned(left: 8, bottom: 8, child: _Tag('Before')),
                      const Positioned(right: 8, bottom: 8, child: _Tag('After')),
                    ]),
                  );
                }),
        ),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'Drag to compare. Enhancement makes pictures easier to see but cannot recover detail the camera never captured; '
            'the original is kept unchanged.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
        ),
      ]),
    );
  }
}

class _LeftClip extends CustomClipper<Rect> {
  _LeftClip(this.f);
  final double f;
  @override
  Rect getClip(Size s) => Rect.fromLTWH(0, 0, s.width * f, s.height);
  @override
  bool shouldReclip(_LeftClip o) => o.f != f;
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
      );
}
