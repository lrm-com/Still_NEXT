import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'spectrum_painter.dart';

enum LyricsBackgroundMode { coverBlur, extractedColor, fluid, solid, none }

class LyricsBackgroundSettings {
  const LyricsBackgroundSettings({
    this.mode = LyricsBackgroundMode.coverBlur,
    this.snowEnabled = false,
    this.fogEnabled = false,
    this.raindropsEnabled = false,
    this.blurSigma = 15,
    this.particleDensity = .35,
    this.particleSpeed = .25,
    this.opacity = .75,
    this.parallax = true,
  });

  final LyricsBackgroundMode mode;
  final bool snowEnabled;
  final bool fogEnabled;
  final bool raindropsEnabled;
  final double blurSigma;
  final double particleDensity;
  final double particleSpeed;
  final double opacity;
  final bool parallax;
}

class LyricsEffectsStack extends StatefulWidget {
  const LyricsEffectsStack(
      {super.key,
      required this.settings,
      required this.child,
      this.cover,
      this.baseColor = const Color(0xff15191d),
      this.energy = 0,
      this.spectrum});

  final LyricsBackgroundSettings settings;
  final Widget child;
  final ImageProvider<Object>? cover;
  final Color baseColor;
  final double energy;
  final Float32List? spectrum;

  @override
  State<LyricsEffectsStack> createState() => _LyricsEffectsStackState();
}

class _LyricsEffectsStackState extends State<LyricsEffectsStack>
    with SingleTickerProviderStateMixin {
  double _time = 0;
  Ticker? _ticker;
  int _lastFrameTime = 0;

  ui.FragmentProgram? _snowProgram;
  ui.FragmentProgram? _fogProgram;
  ui.FragmentProgram? _rainProgram;
  ui.FragmentProgram? _fluidProgram;

  ui.ImageFilter? _cachedBlurFilter;
  double _cachedBlurSigma = 0;

  @override
  void initState() {
    super.initState();
    _loadShaders();
    _ticker = createTicker(_onTick)..start();
  }

  Future<void> _loadShaders() async {
    final results = await Future.wait([
      ui.FragmentProgram.fromAsset('assets/shaders/snow.frag'),
      ui.FragmentProgram.fromAsset('assets/shaders/fog.frag'),
      ui.FragmentProgram.fromAsset('assets/shaders/raindrop.frag'),
      ui.FragmentProgram.fromAsset('assets/shaders/fluid_background.frag'),
    ]);
    if (!mounted) return;
    setState(() {
      _snowProgram = results[0];
      _fogProgram = results[1];
      _rainProgram = results[2];
      _fluidProgram = results[3];
    });
  }

  void _onTick(Duration elapsed) {
    final now = elapsed.inMilliseconds;
    if (now - _lastFrameTime < 33) return;
    _lastFrameTime = now;
    if (mounted) {
      setState(() {
        _time = (_time + 0.033) % 16.0;
      });
    }
  }

  ui.ImageFilter _getBlurFilter(double sigma) {
    if (_cachedBlurFilter == null || (sigma - _cachedBlurSigma).abs() > 0.5) {
      _cachedBlurFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
      _cachedBlurSigma = sigma;
    }
    return _cachedBlurFilter!;
  }

  @override
  void dispose() {
    _ticker?.stop();
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _BackgroundLayer(
            settings: widget.settings,
            cover: widget.cover,
            baseColor: widget.baseColor,
            blurFilter: widget.settings.mode == LyricsBackgroundMode.coverBlur
                ? _getBlurFilter(widget.settings.blurSigma)
                : null,
            snowProgram: _snowProgram,
            fogProgram: _fogProgram,
            rainProgram: _rainProgram,
            fluidProgram: _fluidProgram,
            time: _time,
            energy: widget.energy,
            density: widget.settings.particleDensity,
            speed: widget.settings.particleSpeed,
            snowEnabled: widget.settings.snowEnabled,
            fogEnabled: widget.settings.fogEnabled,
            rainEnabled: widget.settings.raindropsEnabled),
        if (widget.spectrum != null)
          CustomPaint(
              painter: SpectrumPainter(
                  magnitudes: widget.spectrum!,
                  opacity: .24,
                  barCount: 48,
                  style: SpectrumStyle.curve,
                  color: Colors.white)),
        widget.child,
      ],
    );
  }
}

class _BackgroundLayer extends StatelessWidget {
  const _BackgroundLayer(
      {required this.settings,
      required this.cover,
      required this.baseColor,
      required this.blurFilter,
      required this.snowProgram,
      required this.fogProgram,
      required this.rainProgram,
      required this.fluidProgram,
      required this.time,
      required this.energy,
      required this.density,
      required this.speed,
      required this.snowEnabled,
      required this.fogEnabled,
      required this.rainEnabled});

  final LyricsBackgroundSettings settings;
  final ImageProvider<Object>? cover;
  final Color baseColor;
  final ui.ImageFilter? blurFilter;
  final ui.FragmentProgram? snowProgram;
  final ui.FragmentProgram? fogProgram;
  final ui.FragmentProgram? rainProgram;
  final ui.FragmentProgram? fluidProgram;
  final double time, energy, density, speed;
  final bool snowEnabled, fogEnabled, rainEnabled;

  @override
  Widget build(BuildContext context) {
    final effectChildren = <Widget>[];

    if (snowEnabled && snowProgram != null) {
      effectChildren.add(_ShaderEffect(
          program: snowProgram!,
          time: time,
          energy: energy,
          density: density,
          speed: speed));
    }
    if (fogEnabled && fogProgram != null) {
      effectChildren.add(_ShaderEffect(
          program: fogProgram!, time: time, energy: energy));
    }
    if (rainEnabled && rainProgram != null) {
      effectChildren.add(_ShaderEffect(
          program: rainProgram!,
          time: time,
          energy: energy,
          density: density,
          speed: speed));
    }

    return Stack(fit: StackFit.expand, children: [
      _buildBackground(blurFilter),
      ...effectChildren,
    ]);
  }

  Widget _buildBackground(ui.ImageFilter? blurFilter) {
    switch (settings.mode) {
      case LyricsBackgroundMode.coverBlur:
        return Stack(fit: StackFit.expand, children: [
          if (cover != null)
            ImageFiltered(
                imageFilter: blurFilter ??
                    ui.ImageFilter.blur(
                        sigmaX: settings.blurSigma,
                        sigmaY: settings.blurSigma),
                child: Image(image: cover!, fit: BoxFit.cover)),
          if (cover != null) Container(color: baseColor.withOpacity(.35)),
          Container(color: baseColor.withOpacity(.45))
        ]);
      case LyricsBackgroundMode.extractedColor:
        return DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
          baseColor,
          Color.lerp(baseColor, Colors.black, .75)!
        ], begin: Alignment.topLeft, end: Alignment.bottomRight)));
      case LyricsBackgroundMode.fluid:
        if (fluidProgram == null) return ColoredBox(color: baseColor);
        return _FluidShaderEffect(
            program: fluidProgram!,
            time: time,
            color: baseColor,
            energy: energy);
      case LyricsBackgroundMode.solid:
        return ColoredBox(color: baseColor);
      case LyricsBackgroundMode.none:
        return const ColoredBox(color: Colors.transparent);
    }
  }
}

class _ShaderEffect extends StatelessWidget {
  const _ShaderEffect(
      {required this.program,
      required this.time,
      this.energy = 0,
      this.density = 0.35,
      this.speed = 0.25});

  final ui.FragmentProgram program;
  final double time;
  final double energy;
  final double density;
  final double speed;

  ui.FragmentShader _createShader(Size size) => program.fragmentShader()
    ..setFloat(0, size.width)
    ..setFloat(1, size.height)
    ..setFloat(2, time)
    ..setFloat(3, density)
    ..setFloat(4, speed)
    ..setFloat(5, energy);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
      return CustomPaint(
          painter: _FragmentPainter(shader: _createShader(size)),
          size: size);
    });
  }
}

class _FluidShaderEffect extends StatelessWidget {
  const _FluidShaderEffect(
      {required this.program,
      required this.time,
      required this.color,
      required this.energy});

  final ui.FragmentProgram program;
  final double time;
  final Color color;
  final double energy;

  ui.FragmentShader _createShader(Size size) => program.fragmentShader()
    ..setFloat(0, size.width)
    ..setFloat(1, size.height)
    ..setFloat(2, time)
    ..setFloat(3, color.r)
    ..setFloat(4, color.g)
    ..setFloat(5, color.b)
    ..setFloat(6, energy);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
      return CustomPaint(
          painter: _FragmentPainter(shader: _createShader(size)),
          size: size);
    });
  }
}

class _FragmentPainter extends CustomPainter {
  _FragmentPainter({required this.shader});
  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _FragmentPainter old) => true;
}
