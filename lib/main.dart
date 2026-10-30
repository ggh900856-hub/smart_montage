import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

const kBg = Color(0xFF0B0F1A);
const kSurface = Color(0xFF1A2236);
const kAccent = Color(0xFFFF4D8D);
const kAccent2 = Color(0xFFFFB84D);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const MagicApp());
}

// ───────────────────────── App ─────────────────────────

class MagicApp extends StatelessWidget {
  const MagicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'المونتاج الذكي',
      locale: const Locale('ar'),
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent, surface: kSurface),
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const HomePage(),
    );
  }
}

// ───────────────────── Helpers / Models ─────────────────────

Future<Directory> montagesDir() async {
  final base = await getApplicationDocumentsDirectory();
  final d = Directory('${base.path}/Montages');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

String fmtDur(double seconds) {
  final s = seconds.round();
  final m = (s ~/ 60).toString().padLeft(2, '0');
  final r = (s % 60).toString().padLeft(2, '0');
  return '$m:$r';
}

String durLabel(int s) {
  if (s < 60) return '$s ثانية';
  final m = s ~/ 60;
  final r = s % 60;
  return r == 0 ? '$m دقيقة' : '$m د و $r ث';
}

String formatSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

double aspectOf(String a) {
  switch (a) {
    case '16:9':
      return 16 / 9;
    case '1:1':
      return 1.0;
    default:
      return 9 / 16;
  }
}

/// فحص مرن لنوع الستريم (بيتعامل مع اختلاف إصدارات الباكيدج)
bool isAudioStream(dynamic s) {
  try {
    dynamic t = s.getType();
    t ??= s.getStringProperty('codec_type');
    if (t != null && t.toString().toLowerCase() == 'audio') return true;
    final codec = (s.getCodec() ?? '').toString().toLowerCase();
    return const [
      'aac', 'mp3', 'opus', 'vorbis', 'flac', 'ac3', 'eac3', 'alac',
      'amr_nb', 'amr_wb', 'pcm_s16le', 'pcm_s16be', 'pcm_u8'
    ].contains(codec);
  } catch (_) {
    return false;
  }
}

class SourceVideo {
  final String path;
  final String name;
  double duration;
  bool hasAudio;
  bool noAudio = false; // اتأكدنا فعلاً إن الصوت مش بيشتغل مع الفيديو ده
  bool analyzed = false;
  bool muted = false; // كتم صوت المقطع (في وضع تقسيم الشاشة)
  List<double> scores = []; // درجة اهتمام كل ثانية (0..1)
  List<double> cuts = []; // أوقات تغيّر المشهد

  SourceVideo({
    required this.path,
    required this.name,
    required this.duration,
    required this.hasAudio,
  });
}

class ClipPlan {
  final int source;
  double start; // بداية القص من الفيديو الأصلي
  double srcLen; // طول الجزء المقصوص من الأصل
  final double len; // طول المقطع في المونتاج
  bool slow;
  final double score;

  ClipPlan({
    required this.source,
    required this.start,
    required this.srcLen,
    required this.len,
    required this.slow,
    required this.score,
  });
}

// ───────────────────── الستايلات (20 ستايل + بدون + مزيج) ─────────────────────

const Map<String, String> kStyleNames = {
  'none': 'بدون',
  'cinematic': 'سينمائي',
  'vivid': 'حيوي',
  'warm': 'دافئ',
  'cool': 'بارد',
  'bw': 'أبيض وأسود',
  'noir': 'نوار درامي',
  'vintage': 'قديم',
  'sepia': 'سيبيا',
  'tealorange': 'تيل وبرتقالي',
  'neon': 'نيون',
  'dreamy': 'حالم',
  'faded': 'باهت مات',
  'sunset': 'غروب',
  'forest': 'طبيعة خضراء',
  'pink': 'وردي',
  'cyber': 'سايبر',
  'film': 'فيلم قديم',
  'hdr': 'HDR قوي',
  'golden': 'ذهبي',
  'bluemono': 'أزرق أحادي',
  'mix': '🎲 مزيج (ستايل لكل مقطع)',
};

String gradeFor(String style) {
  switch (style) {
    case 'cinematic':
      return 'colorbalance=rs=-0.05:bs=0.08:rh=0.06:bh=-0.05,eq=contrast=1.08:saturation=0.92,vignette=PI/5,noise=alls=5:allf=t';
    case 'vivid':
      return 'eq=contrast=1.08:saturation=1.35:brightness=0.01,unsharp=5:5:0.7';
    case 'warm':
      return 'colorbalance=rm=0.07:gm=0.01:bm=-0.07:rh=0.05:bh=-0.05,eq=saturation=1.12:contrast=1.04,vignette=PI/6';
    case 'cool':
      return 'colorbalance=rs=-0.06:bs=0.10:rm=-0.04:bm=0.06:bh=0.04,eq=saturation=1.05:contrast=1.04,vignette=PI/6';
    case 'bw':
      return 'hue=s=0,eq=contrast=1.25:brightness=-0.02,vignette=PI/5,noise=alls=5:allf=t';
    case 'noir':
      return 'hue=s=0,eq=contrast=1.55:brightness=-0.05,vignette=PI/3.5,noise=alls=6:allf=t';
    case 'vintage':
      return 'curves=preset=vintage,eq=saturation=0.9:contrast=1.03,vignette=PI/5,noise=alls=7:allf=t';
    case 'sepia':
      return 'colorchannelmixer=rr=.393:rg=.769:rb=.189:gr=.349:gg=.686:gb=.168:br=.272:bg=.534:bb=.131,vignette=PI/6';
    case 'tealorange':
      return 'colorbalance=rs=-0.10:bs=0.12:rm=-0.03:bm=0.04:rh=0.12:bh=-0.10,eq=contrast=1.1:saturation=1.2';
    case 'neon':
      return 'eq=contrast=1.18:saturation=1.75:brightness=-0.02,colorbalance=bs=0.10:bm=0.06:rh=0.06,unsharp=5:5:0.6';
    case 'dreamy':
      return 'gblur=sigma=1.0,eq=brightness=0.04:saturation=1.1:contrast=0.96,colorbalance=rh=0.05:bh=0.05';
    case 'faded':
      return 'eq=contrast=0.88:saturation=0.78:brightness=0.04,colorbalance=rs=0.02:bs=0.03';
    case 'sunset':
      return 'colorbalance=rs=0.12:gs=0.02:bs=-0.10:rm=0.08:bm=-0.08:rh=0.06:bh=-0.05,eq=saturation=1.25:contrast=1.05,vignette=PI/6';
    case 'forest':
      return 'colorbalance=rs=-0.04:gs=0.08:bs=-0.03:gm=0.05,eq=saturation=1.2:contrast=1.05';
    case 'pink':
      return 'colorbalance=rm=0.08:gm=-0.04:bm=0.06:rh=0.04:bh=0.04,eq=saturation=1.15:brightness=0.02';
    case 'cyber':
      return 'colorbalance=rs=0.10:gs=-0.08:bs=0.15:rh=0.10:bh=0.10,eq=contrast=1.2:saturation=1.5';
    case 'film':
      return 'curves=preset=cross_process,eq=saturation=0.95,noise=alls=12:allf=t,vignette=PI/5';
    case 'hdr':
      return 'eq=contrast=1.25:saturation=1.3:brightness=0.01,unsharp=5:5:1.0';
    case 'golden':
      return 'colorbalance=rm=0.10:gm=0.04:bm=-0.12:rh=0.06:bh=-0.06,eq=saturation=1.2:contrast=1.04,vignette=PI/6';
    case 'bluemono':
      return 'hue=s=0.15,colorbalance=bs=0.20:bm=0.20:bh=0.12:rs=-0.10:rm=-0.12,eq=contrast=1.1';
    default:
      return '';
  }
}

// ───────────────────── الانتقالات ─────────────────────

const List<String> kSmoothTr = [
  'fade', 'dissolve', 'fadeblack', 'fadewhite', 'fadegrays',
  'smoothleft', 'smoothright', 'smoothup', 'smoothdown', 'distance',
];

const List<String> kDynamicTr = [
  'wipeleft', 'wiperight', 'wipeup', 'wipedown',
  'slideleft', 'slideright', 'slideup', 'slidedown',
  'circleopen', 'circleclose', 'circlecrop', 'rectcrop',
  'vertopen', 'vertclose', 'horzopen', 'horzclose',
  'radial', 'diagtl', 'diagtr', 'diagbl', 'diagbr', 'pixelize',
  'hlslice', 'hrslice', 'vuslice', 'vdslice', 'hblur',
  'wipetl', 'wipetr', 'wipebl', 'wipebr',
  'squeezeh', 'squeezev', 'zoomin',
  'hlwind', 'hrwind', 'vuwind', 'vdwind',
  'coverleft', 'coverright', 'coverup', 'coverdown',
  'revealleft', 'revealright', 'revealup', 'revealdown',
];

/// انتقالات مضمونة في الإصدارات القديمة من FFmpeg
const Set<String> kSafeTr = {
  'fade', 'dissolve', 'fadeblack', 'fadewhite', 'wipeleft', 'wiperight',
  'wipeup', 'wipedown', 'slideleft', 'slideright', 'slideup', 'slidedown',
  'circleopen', 'circleclose', 'circlecrop', 'rectcrop', 'vertopen',
  'vertclose', 'horzopen', 'horzclose', 'radial', 'smoothleft',
  'smoothright', 'smoothup', 'smoothdown', 'distance', 'pixelize',
  'diagtl', 'diagtr', 'diagbl', 'diagbr',
};

/// صور مصغرة للمونتاجات المحفوظة
class ThumbService {
  static final Map<String, Future<File?>> _cache = {};
  static Future<void> _queue = Future.value();

  static File thumbFileFor(File video) {
    final name = video.path.split('/').last.replaceAll('.mp4', '.jpg');
    return File('${video.parent.path}/.thumbs/$name');
  }

  static Future<File?> get(File video) {
    return _cache.putIfAbsent(video.path, () => _generate(video));
  }

  static void forget(File video) {
    _cache.remove(video.path);
    try {
      final t = thumbFileFor(video);
      if (t.existsSync()) t.deleteSync();
    } catch (_) {}
  }

  static Future<File?> _generate(File video) {
    final completer = Completer<File?>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await _run(video));
      } catch (_) {
        completer.complete(null);
      }
    });
    return completer.future;
  }

  static Future<File?> _run(File video) async {
    final out = thumbFileFor(video);
    final dir = out.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    if (await out.exists() && await out.length() > 0) return out;

    for (final ss in ['0.5', '0']) {
      final session = await FFmpegKit.execute(
        '-y -ss $ss -i "${video.path}" -frames:v 1 -vf scale=360:-2 -q:v 4 "${out.path}"',
      );
      final code = await session.getReturnCode();
      if (ReturnCode.isSuccess(code) && await out.exists() && await out.length() > 0) {
        return out;
      }
    }
    return null;
  }
}

class VideoThumb extends StatelessWidget {
  final File video;
  const VideoThumb({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: ThumbService.get(video),
      builder: (context, snap) {
        final f = snap.data;
        if (f != null) return Image.file(f, fit: BoxFit.cover, gaplessPlayback: true);
        return Container(
          color: Colors.black26,
          child: Center(
            child: snap.connectionState == ConnectionState.done
                ? const Icon(Icons.movie, color: Colors.white24, size: 32)
                : const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  ),
          ),
        );
      },
    );
  }
}

// ───────────────────── الطبقات: صور PiP + كتابة حرة ─────────────────────

/// عنصر فوق الفيديو (صورة أو كتابة). الإحداثيات نسب من 0 لـ 1 من حجم الفيديو
/// فبتتطبق بنفس المكان بالظبط على أي جودة أو أبعاد.
class OverlayItem {
  final bool isImage;
  ui.Image? image;
  String text;
  Color color;
  bool box; // خلفية غامقة خلف الكتابة
  double cx; // مركز العنصر (أفقي)
  double cy; // مركز العنصر (رأسي)
  double scale;
  double rotation; // بالراديان
  double opacity;
  int timing; // 0 طوال الفيديو / 1 أول 5 ثواني / 2 آخر 5 ثواني
  int shape; // للصور: 0 حواف مدورة / 1 دائرة / 2 مربع
  bool border;

  OverlayItem({
    required this.isImage,
    this.image,
    this.text = '',
    this.color = Colors.white,
    this.box = true,
    this.cx = 0.5,
    this.cy = 0.5,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.opacity = 1.0,
    this.timing = 0,
    this.shape = 0,
    this.border = false,
  });

  bool get valid => isImage ? image != null : text.trim().isNotEmpty;
}

Future<ui.Image?> loadUiImage(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    var codec = await ui.instantiateImageCodec(bytes);
    var frame = await codec.getNextFrame();
    var img = frame.image;
    if (img.width > 1280 || img.height > 1280) {
      final wide = img.width >= img.height;
      img.dispose();
      codec.dispose();
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: wide ? 1280 : null,
        targetHeight: wide ? null : 1280,
      );
      frame = await codec.getNextFrame();
      img = frame.image;
    }
    return img;
  } catch (_) {
    return null;
  }
}

TextPainter overlayTextPainter(OverlayItem it, Size frame) {
  final minSide = min(frame.width, frame.height);
  final fs = minSide * 0.065 * it.scale;
  final isRtl = RegExp(r'[\u0600-\u06FF]').hasMatch(it.text);
  final shadowColor = it.color.computeLuminance() < 0.2 ? Colors.white : Colors.black;
  return TextPainter(
    text: TextSpan(
      text: it.text,
      style: TextStyle(
        color: it.color,
        fontSize: fs,
        fontWeight: FontWeight.w800,
        height: 1.3,
        shadows: [Shadow(color: shadowColor, blurRadius: fs * 0.12, offset: Offset(0, fs * 0.04))],
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
    textWidthBasis: TextWidthBasis.longestLine,
  )..layout(maxWidth: frame.width * 0.9);
}

Size overlayItemSize(OverlayItem it, Size frame) {
  final minSide = min(frame.width, frame.height);
  if (it.isImage) {
    final img = it.image;
    if (img == null) return Size.zero;
    final w = minSide * 0.35 * it.scale;
    final h = it.shape == 1 ? w : w * img.height / img.width;
    return Size(w, h);
  }
  final tp = overlayTextPainter(it, frame);
  final pad = minSide * 0.065 * it.scale * 0.5;
  return Size(tp.width + pad * 2, tp.height + pad * 1.2);
}

/// نفس دالة الرسم بتتستخدم في المعاينة وفي التصدير (علشان الشكل يطلع زي ما شايفه)
void paintOverlayItem(Canvas canvas, Size frame, OverlayItem it) {
  if (!it.valid) return;
  final minSide = min(frame.width, frame.height);
  canvas.save();
  canvas.translate(it.cx * frame.width, it.cy * frame.height);
  canvas.rotate(it.rotation);
  final fade = it.opacity < 0.999;
  if (fade) {
    canvas.saveLayer(null, Paint()..color = Color.fromRGBO(255, 255, 255, it.opacity));
  }

  if (it.isImage) {
    final img = it.image!;
    final sz = overlayItemSize(it, frame);
    final dst = Rect.fromCenter(center: Offset.zero, width: sz.width, height: sz.height);
    Rect src;
    if (it.shape == 1) {
      final s = min(img.width, img.height).toDouble();
      src = Rect.fromCenter(center: Offset(img.width / 2, img.height / 2), width: s, height: s);
    } else {
      src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    }
    final radius = it.shape == 1 ? sz.width / 2 : (it.shape == 2 ? 0.0 : minSide * 0.02);
    final rr = RRect.fromRectAndRadius(dst, Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(rr, doAntiAlias: true);
    canvas.drawImageRect(img, src, dst, Paint()..filterQuality = FilterQuality.high);
    canvas.restore();
    if (it.border) {
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = max(2.0, minSide * 0.006)
          ..color = Colors.white,
      );
    }
  } else {
    final tp = overlayTextPainter(it, frame);
    final fs = minSide * 0.065 * it.scale;
    final pad = fs * 0.5;
    if (it.box) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: tp.width + pad * 2,
            height: tp.height + pad * 1.2,
          ),
          Radius.circular(pad),
        ),
        Paint()..color = const Color.fromARGB(140, 0, 0, 0),
      );
    }
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  }

  if (fade) canvas.restore();
  canvas.restore();
}

class OverlayLayer {
  final String png;
  final int timing;
  const OverlayLayer(this.png, this.timing);
}

/// بيرسم كل العناصر في صور شفافة بحجم الفيديو (صورة لكل وقت ظهور)
Future<List<OverlayLayer>> buildOverlayLayers(
  List<OverlayItem> items,
  int w,
  int h,
  String dir,
) async {
  final out = <OverlayLayer>[];
  final size = Size(w.toDouble(), h.toDouble());
  for (var t = 0; t < 3; t++) {
    final group = items.where((i) => i.valid && i.timing == t).toList();
    if (group.isEmpty) continue;
    try {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec, Offset.zero & size);
      for (final it in group) {
        paintOverlayItem(canvas, size, it);
      }
      final pic = rec.endRecording();
      final img = await pic.toImage(w, h);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (bd == null) continue;
      final path = '$dir/overlay_$t.png';
      await File(path).writeAsBytes(bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes));
      out.add(OverlayLayer(path, t));
    } catch (_) {}
  }
  return out;
}

/// فلاتر FFmpeg اللي بتركّب الطبقات فوق الفيديو
({List<String> fc, String label}) overlayFilters(
  List<OverlayLayer> layers,
  int firstIdx,
  String inLabel,
  double total,
) {
  final fc = <String>[];
  var cur = inLabel;
  for (var i = 0; i < layers.length; i++) {
    final idx = firstIdx + i;
    var enable = '';
    if (layers[i].timing == 1) {
      enable = ":enable='lt(t,5)'";
    } else if (layers[i].timing == 2) {
      enable = ":enable='gt(t,${max(0.0, total - 5).toStringAsFixed(3)})'";
    }
    fc.add('[$idx:v]format=rgba[ov$i]');
    fc.add('$cur[ov$i]overlay=0:0$enable[ot$i]');
    cur = '[ot$i]';
  }
  return (fc: fc, label: cur);
}

class _OverlayPainter extends CustomPainter {
  final List<OverlayItem> items;
  final OverlayItem? selected;
  _OverlayPainter(this.items, this.selected);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    for (final it in items) {
      paintOverlayItem(canvas, size, it);
    }
    final s = selected;
    if (s != null && s.valid) {
      final sz = overlayItemSize(s, size);
      canvas.save();
      canvas.translate(s.cx * size.width, s.cy * size.height);
      canvas.rotate(s.rotation);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: sz.width + 8, height: sz.height + 8),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = kAccent2,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) => true;
}

/// كارت مختصر بيظهر في صفحة المونتاج وتقسيم الشاشة ويفتح المحرر
class OverlaysCard extends StatelessWidget {
  final List<OverlayItem> items;
  final String aspect;
  final String? backdropVideo;
  final VoidCallback onChanged;

  const OverlaysCard({
    super.key,
    required this.items,
    required this.aspect,
    required this.backdropVideo,
    required this.onChanged,
  });

  Future<void> _open(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OverlayEditorPage(
          items: items,
          aspect: aspectOf(aspect),
          backdropVideo: backdropVideo,
        ),
      ),
    );
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final valid = items.where((e) => e.valid).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (valid.isEmpty)
          const Text(
            'تقدر تضيف صورة صغيرة (PiP) وكتابة حرة تحركها في أي مكان على الفيديو.',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final it in valid)
                Chip(
                  backgroundColor: kSurface,
                  avatar: Icon(it.isImage ? Icons.image : Icons.text_fields, size: 16, color: kAccent2),
                  label: Text(
                    it.isImage ? 'صورة' : (it.text.length > 14 ? '${it.text.substring(0, 14)}…' : it.text),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            side: const BorderSide(color: kAccent),
          ),
          onPressed: () => _open(context),
          icon: const Icon(Icons.layers, color: kAccent),
          label: Text(valid.isEmpty ? 'فتح محرر الصور والكتابة' : 'تعديل (${valid.length} عناصر)'),
        ),
      ],
    );
  }
}

/// محرر الطبقات: معاينة بنسبة الفيديو النهائي، اسحب وكبّر وكتابة حرة
class OverlayEditorPage extends StatefulWidget {
  final List<OverlayItem> items;
  final double aspect;
  final String? backdropVideo;

  const OverlayEditorPage({
    super.key,
    required this.items,
    required this.aspect,
    this.backdropVideo,
  });

  @override
  State<OverlayEditorPage> createState() => _OverlayEditorPageState();
}

class _OverlayEditorPageState extends State<OverlayEditorPage> {
  static const int _maxItems = 8;
  static const _timingNames = ['طوال الفيديو', 'أول 5 ثواني', 'آخر 5 ثواني'];
  static const _shapeNames = ['حواف مدورة', 'دائرة', 'مربع'];
  static const List<Color> _colors = [
    Colors.white,
    Color(0xFFFFE14D),
    kAccent,
    Color(0xFF6BFF8A),
    Color(0xFF4DE1FF),
    Color(0xFFFF8A3D),
    Colors.black,
  ];

  final _picker = ImagePicker();
  OverlayItem? _sel;
  File? _backdrop;

  OverlayItem? _active;
  double _s0 = 1;
  double _r0 = 0;
  int _lastCount = 1;

  @override
  void initState() {
    super.initState();
    _loadBackdrop();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _loadBackdrop() async {
    final src = widget.backdropVideo;
    if (src == null) return;
    try {
      final tmp = await getTemporaryDirectory();
      final out = File('${tmp.path}/overlay_backdrop_${src.hashCode}.jpg');
      if (!await out.exists() || await out.length() == 0) {
        for (final ss in ['1', '0']) {
          final s = await FFmpegKit.execute(
            '-y -ss $ss -i "$src" -frames:v 1 -vf scale=720:-2 -q:v 4 "${out.path}"',
          );
          final code = await s.getReturnCode();
          if (ReturnCode.isSuccess(code) && await out.exists() && await out.length() > 0) break;
        }
      }
      if (await out.exists() && await out.length() > 0 && mounted) {
        setState(() => _backdrop = out);
      }
    } catch (_) {}
  }

  Future<String?> _askText(String initial) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('الكتابة', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'اكتب النص هنا…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kAccent),
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('تم', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _addImage() async {
    if (widget.items.length >= _maxItems) {
      _toast('الحد الأقصى $_maxItems عناصر');
      return;
    }
    final x = await _picker.pickImage(source: ImageSource.gallery);
    if (x == null) return;
    final img = await loadUiImage(x.path);
    if (img == null) {
      _toast('تعذر قراءة الصورة دي');
      return;
    }
    if (!mounted) return;
    final it = OverlayItem(isImage: true, image: img, cx: 0.78, cy: 0.18);
    setState(() {
      widget.items.add(it);
      _sel = it;
    });
  }

  Future<void> _addText() async {
    if (widget.items.length >= _maxItems) {
      _toast('الحد الأقصى $_maxItems عناصر');
      return;
    }
    final t = await _askText('');
    if (t == null || t.isEmpty || !mounted) return;
    final it = OverlayItem(isImage: false, text: t, cy: 0.8);
    setState(() {
      widget.items.add(it);
      _sel = it;
    });
  }

  Future<void> _editText(OverlayItem it) async {
    final t = await _askText(it.text);
    if (t == null || t.isEmpty || !mounted) return;
    setState(() => it.text = t);
  }

  void _delete(OverlayItem it) {
    setState(() {
      widget.items.remove(it);
      if (_sel == it) _sel = null;
    });
  }

  OverlayItem? _hit(Offset p, Size size) {
    for (var i = widget.items.length - 1; i >= 0; i--) {
      final it = widget.items[i];
      if (!it.valid) continue;
      final s = overlayItemSize(it, size);
      final d = p - Offset(it.cx * size.width, it.cy * size.height);
      final cosA = cos(-it.rotation);
      final sinA = sin(-it.rotation);
      final lx = d.dx * cosA - d.dy * sinA;
      final ly = d.dx * sinA + d.dy * cosA;
      const slack = 14.0;
      if (lx.abs() <= s.width / 2 + slack && ly.abs() <= s.height / 2 + slack) return it;
    }
    return null;
  }

  Widget _preview(Size size) {
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: _backdrop != null
                ? Image.file(_backdrop!, fit: BoxFit.cover)
                : Container(color: kSurface),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final hit = _hit(d.localPosition, size);
                setState(() => _sel = hit);
              },
              onScaleStart: (d) {
                final hit = _hit(d.localFocalPoint, size);
                if (hit != null) setState(() => _sel = hit);
                _active = hit ?? (d.pointerCount >= 2 ? _sel : null);
                _lastCount = d.pointerCount;
                _s0 = _active?.scale ?? 1;
                _r0 = _active?.rotation ?? 0;
              },
              onScaleUpdate: (d) {
                final it = _active;
                if (it == null) return;
                if (d.pointerCount != _lastCount) {
                  _lastCount = d.pointerCount;
                  _s0 = it.scale;
                  _r0 = it.rotation;
                  return;
                }
                setState(() {
                  it.cx = (it.cx + d.focalPointDelta.dx / size.width).clamp(0.0, 1.0).toDouble();
                  it.cy = (it.cy + d.focalPointDelta.dy / size.height).clamp(0.0, 1.0).toDouble();
                  if (d.pointerCount >= 2) {
                    it.scale = (_s0 * d.scale).clamp(0.2, 6.0).toDouble();
                    it.rotation = _r0 + d.rotation;
                  }
                });
              },
              onScaleEnd: (_) => _active = null,
              child: CustomPaint(
                size: Size.infinite,
                painter: _OverlayPainter(widget.items, _sel),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double lo,
    double hi,
    ValueChanged<double> onChanged,
    String shown,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ),
        Expanded(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Slider(
              min: lo,
              max: hi,
              value: value.clamp(lo, hi).toDouble(),
              activeColor: kAccent,
              onChanged: (v) => setState(() => onChanged(v)),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            shown,
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        ),
      ],
    );
  }

  Widget _chipsRow(List<String> names, int current, void Function(int) onSel) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (var i = 0; i < names.length; i++)
          ChoiceChip(
            label: Text(names[i], style: const TextStyle(fontSize: 12)),
            selected: current == i,
            selectedColor: kAccent,
            onSelected: (_) => setState(() => onSel(i)),
          ),
      ],
    );
  }

  Widget _controls(OverlayItem it) {
    var deg = it.rotation * 180 / pi;
    deg = ((deg + 180) % 360) - 180;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        if (!it.isImage) ...[
          Row(
            children: [
              TextButton.icon(
                onPressed: () => _editText(it),
                icon: const Icon(Icons.edit, size: 18, color: kAccent2),
                label: const Text('تعديل النص', style: TextStyle(color: kAccent2)),
              ),
            ],
          ),
          Wrap(
            spacing: 10,
            children: [
              for (final c in _colors)
                GestureDetector(
                  onTap: () => setState(() => it.color = c),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: it.color == c ? kAccent2 : Colors.white24,
                        width: it.color == c ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeColor: kAccent,
            title: const Text('خلفية خلف الكتابة', style: TextStyle(fontSize: 13)),
            value: it.box,
            onChanged: (v) => setState(() => it.box = v),
          ),
        ] else ...[
          _chipsRow(_shapeNames, it.shape, (v) => it.shape = v),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeColor: kAccent,
            title: const Text('إطار أبيض', style: TextStyle(fontSize: 13)),
            value: it.border,
            onChanged: (v) => setState(() => it.border = v),
          ),
        ],
        _slider('الحجم', it.scale, 0.2, 4.0, (v) => it.scale = v, '${(it.scale * 100).round()}%'),
        _slider('التدوير', deg, -180, 180, (v) => it.rotation = v * pi / 180, '${deg.round()}°'),
        _slider('الشفافية', it.opacity, 0.1, 1.0, (v) => it.opacity = v, '${(it.opacity * 100).round()}%'),
        const SizedBox(height: 6),
        const Text('وقت الظهور', style: TextStyle(fontSize: 12, color: Colors.white54)),
        const SizedBox(height: 6),
        _chipsRow(_timingNames, it.timing, (v) => it.timing = v),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() => it.cx = 0.5),
                icon: const Icon(Icons.align_horizontal_center, size: 18, color: Colors.white70),
                label: const Text('توسيط', style: TextStyle(color: Colors.white70)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent)),
                onPressed: () => _delete(it),
                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                label: const Text('حذف', style: TextStyle(color: Colors.redAccent)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _panel() {
    final it = _sel;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: kAccent)),
                  onPressed: _addImage,
                  icon: const Icon(Icons.add_photo_alternate, color: kAccent),
                  label: const Text('صورة PiP'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: kAccent2)),
                  onPressed: _addText,
                  icon: const Icon(Icons.text_fields, color: kAccent2),
                  label: const Text('كتابة'),
                ),
              ),
            ],
          ),
          if (it == null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'اضغط على أي عنصر في المعاينة عشان تعدّله.\n'
                'اسحب بإصبع للتحريك • بإصبعين للتكبير والتدوير.',
                style: TextStyle(fontSize: 12, color: Colors.white38, height: 1.5),
              ),
            )
          else
            _controls(it),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('محرر الصور والكتابة', style: TextStyle(fontSize: 16)),
        backgroundColor: kBg,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('تم', style: TextStyle(color: kAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, cons) {
                  var pw = cons.maxWidth;
                  var ph = pw / widget.aspect;
                  if (ph > cons.maxHeight) {
                    ph = cons.maxHeight;
                    pw = ph * widget.aspect;
                  }
                  final size = Size(pw, ph);
                  return Center(
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Colors.white24)),
                      child: SizedBox(width: pw, height: ph, child: _preview(size)),
                    ),
                  );
                },
              ),
            ),
          ),
          Expanded(flex: 5, child: _panel()),
        ],
      ),
    );
  }
}

// ───────────────────────── Home ─────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<File> _files = [];

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
    _requestNotificationPermission();
    _load();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'smart_montage_channel',
        channelName: 'خدمة المونتاج',
        channelDescription: 'تضمن استمرار المونتاج في الخلفية',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> _requestNotificationPermission() async {
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  Future<void> _load() async {
    final d = await montagesDir();
    final list = d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mp4'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (!mounted) return;
    setState(() => _files = list);
  }

  Future<void> _newProject() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProjectPage()));
    _load();
  }

  Future<void> _newSplit() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SplitPage()));
    _load();
  }

  Future<void> _open(File f) async {
    await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => PlayerPage(file: f, fromProject: false)),
    );
    _load();
  }

  Future<void> _delete(File f) async {
    ThumbService.forget(f);
    try {
      await f.delete();
    } catch (_) {}
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('المونتاج الذكي ✨'),
        centerTitle: true,
        backgroundColor: kBg,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _newProject,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 28),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(colors: [kAccent, kAccent2]),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.auto_awesome, size: 44, color: Colors.white),
                    SizedBox(height: 8),
                    Text(
                      'مونتاج جديد',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'اختار فيديوهات والسحر يبدأ',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _newSplit,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 22),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: kSurface,
                  border: Border.all(color: kAccent2, width: 1.5),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.view_column, size: 38, color: kAccent2),
                    SizedBox(height: 6),
                    Text(
                      'تقسيم الشاشة',
                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'اختار 2 أو 3 مقاطع وتتشغل جنب بعض في شاشة واحدة',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 36, color: Colors.white12),
            const Text(
              'مونتاجاتك:',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: kAccent),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _files.isEmpty
                  ? const Center(
                      child: Text(
                        'لسه معملتش مونتاج، ابدأ أول واحد!',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _files.length,
                      itemBuilder: (context, i) => _buildCard(_files[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(File f) {
    final m = f.statSync().modified;
    final size = formatSize(f.lengthSync());
    return Card(
      color: kSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(f),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(width: 76, height: 76, child: VideoThumb(video: f)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('مونتاج', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      '${m.year}/${m.month}/${m.day}  •  $size',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54),
                color: kSurface,
                onSelected: (v) {
                  if (v == 'delete') _delete(f);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('حذف')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────── Project (setup + generate) ─────────────────────

class ProjectPage extends StatefulWidget {
  const ProjectPage({super.key});

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  final _picker = ImagePicker();
  final List<SourceVideo> _sources = [];

  int _targetSec = 30;
  int _pace = 1; // 0 سريع / 1 متوسط / 2 هادئ
  String _aspect = '9:16';
  bool _hd = false;
  bool _smart = true;
  String _style = 'cinematic';
  int _trMode = 1; // 0 ناعمة / 1 متنوعة / 2 كل الأنواع
  bool _blurFit = false;
  bool _slowmo = true;
  bool _pan = true;
  bool _keepOriginal = true;
  String? _musicPath;
  String? _musicName;

  // صور PiP وكتابة حرة فوق الفيديو
  final List<OverlayItem> _overlays = [];

  bool _busy = false;
  bool _picking = false;
  bool _cancelled = false;
  double _progress = 0;
  String _status = '';
  String _errorDetail = '';
  String _lastLog = '';

  static const double _td = 0.5; // مدة الانتقال
  static const int _group = 8; // أقصى عدد مقاطع في عملية دمج واحدة
  String? _encInter;
  String? _encFinal;

  // حالة التجهيز
  final Map<String, String> _gradeOf = {};
  List<String> _mixOrder = ['none'];
  Set<String> _supportedTr = {};
  bool _trReady = false;

  // تقدّم الدمج
  int _stepsDone = 0;
  int _stepsTotal = 1;
  double _mStart = 0;
  double _mW = 1;

  static const _aspects = {
    '9:16': 'ريلز 9:16',
    '16:9': 'يوتيوب 16:9',
    '1:1': 'مربع 1:1',
  };

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _set(String stage, double p) {
    if (!mounted) return;
    setState(() {
      _status = stage;
      _progress = p.clamp(0.0, 1.0).toDouble();
    });
  }

  void _setP(double p) {
    if (!mounted) return;
    setState(() => _progress = p.clamp(0.0, 1.0).toDouble());
  }

  void _tick(double f) {
    final total = max(1, _stepsTotal);
    _setP(_mStart + _mW * ((_stepsDone + f) / total));
  }

  // ───── اختيار الفيديوهات والموسيقى ─────

  Future<SourceVideo?> _probe(XFile x) async {
    double duration = 0;
    bool hasAudio = true;
    try {
      final session = await FFprobeKit.getMediaInformation(x.path);
      final info = session.getMediaInformation();
      if (info != null) {
        duration = double.tryParse(info.getDuration() ?? '') ?? 0;
        final streams = info.getStreams();
        hasAudio = streams.isEmpty ? true : streams.any(isAudioStream);
      }
    } catch (_) {}
    if (duration <= 0) {
      try {
        final c = VideoPlayerController.file(File(x.path));
        await c.initialize();
        duration = c.value.duration.inMilliseconds / 1000;
        await c.dispose();
      } catch (_) {}
    }
    if (duration <= 0) return null;
    return SourceVideo(path: x.path, name: x.name, duration: duration, hasAudio: hasAudio);
  }

  Future<void> _pickVideos() async {
    final files = await _picker.pickMultiVideo();
    if (files.isEmpty) return;
    setState(() => _picking = true);
    for (final x in files) {
      if (_sources.any((s) => s.path == x.path)) continue;
      final v = await _probe(x);
      if (v != null) _sources.add(v);
    }
    if (mounted) setState(() => _picking = false);
  }

  Future<void> _pickMusic() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (r == null || r.files.isEmpty || r.files.single.path == null) return;
    setState(() {
      _musicPath = r.files.single.path;
      _musicName = r.files.single.name;
    });
  }

  // ───── تشغيل أوامر FFmpeg ─────

  Future<String?> _runForLogs(String cmd, void Function(int ms)? onTime) async {
    final buf = StringBuffer();
    final c = Completer<String?>();
    await FFmpegKit.executeAsync(
      cmd,
      (session) async {
        final code = await session.getReturnCode();
        c.complete(ReturnCode.isSuccess(code) ? buf.toString() : null);
      },
      (log) => buf.write('${log.getMessage()}\n'),
      onTime == null ? null : (s) => onTime(s.getTime().toInt()),
    );
    return c.future;
  }

  Future<bool> _exec(String cmd, {void Function(int ms)? onTime}) async {
    final c = Completer<bool>();
    var tail = '';
    await FFmpegKit.executeAsync(
      cmd,
      (session) async {
        final code = await session.getReturnCode();
        final ok = ReturnCode.isSuccess(code);
        if (!ok) _lastLog = tail;
        c.complete(ok);
      },
      (log) {
        tail += '${log.getMessage()}\n';
        if (tail.length > 6000) tail = tail.substring(tail.length - 3000);
      },
      onTime == null ? null : (s) => onTime(s.getTime().toInt()),
    );
    return c.future;
  }

  Future<double?> _durationOf(String path) async {
    try {
      final s = await FFprobeKit.getMediaInformation(path);
      final d = double.tryParse(s.getMediaInformation()?.getDuration() ?? '');
      return (d != null && d > 0) ? d : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasAudioStream(String path) async {
    try {
      final s = await FFprobeKit.getMediaInformation(path);
      final streams = s.getMediaInformation()?.getStreams() ?? [];
      return streams.any(isAudioStream);
    } catch (_) {
      return false;
    }
  }

  // ───── التحليل الذكي (صوت + حركة) ─────

  Future<void> _analyze(SourceVideo v, void Function(double) onP) async {
    final totalMs = max(1.0, v.duration * 1000);
    String? audioText;
    if (v.hasAudio) {
      audioText = await _runForLogs(
        '-hide_banner -loglevel info -i "${v.path}" -vn '
        '-af "aresample=44100,asetnsamples=n=44100:p=0,astats=metadata=1:reset=1,'
        'ametadata=print:key=lavfi.astats.Overall.RMS_level" -f null -',
        (ms) => onP(0.4 * (ms / totalMs).clamp(0.0, 1.0).toDouble()),
      );
    }
    if (_cancelled) return;

    final base = v.hasAudio ? 0.4 : 0.0;
    final span = v.hasAudio ? 0.6 : 1.0;
    final motionText = await _runForLogs(
      '-hide_banner -loglevel info -i "${v.path}" -an '
      '-vf "fps=2,scale=160:-2,select=\'gte(scene,0)\',metadata=print:key=lavfi.scene_score" -f null -',
      (ms) => onP(base + span * (ms / totalMs).clamp(0.0, 1.0).toDouble()),
    );
    if (_cancelled) return;

    final secs = max(1, v.duration.floor());

    final audio = List<double>.filled(secs, 0.0);
    var gotAudio = false;
    if (audioText != null) {
      final re = RegExp(r'lavfi\.astats\.Overall\.RMS_level=(-?inf|-?[0-9]+(?:\.[0-9]+)?)');
      final ms = re.allMatches(audioText).toList();
      for (var i = 0; i < ms.length && i < secs; i++) {
        final s = ms[i].group(1)!;
        final db = s.contains('inf') ? -90.0 : (double.tryParse(s) ?? -90.0);
        audio[i] = ((db + 50) / 40).clamp(0.0, 1.0).toDouble();
        gotAudio = true;
      }
    }

    final motion = List<double>.filled(secs, 0.0);
    final cuts = <double>[];
    var gotMotion = false;
    if (motionText != null) {
      final re = RegExp(r'lavfi\.scene_score=([0-9.]+)');
      final vals = re.allMatches(motionText).map((m) => double.tryParse(m.group(1)!) ?? 0.0).toList();
      for (var i = 0; i < vals.length; i++) {
        final t = i / 2.0;
        final sec = t.floor();
        if (vals[i] > 0.45) cuts.add(t);
        if (sec < secs) {
          final m = (min(vals[i], 0.45) / 0.25).clamp(0.0, 1.0).toDouble();
          if (m > motion[sec]) motion[sec] = m;
          gotMotion = true;
        }
      }
    }

    final scores = List<double>.filled(secs, 0.0);
    for (var i = 0; i < secs; i++) {
      if (gotAudio && gotMotion) {
        scores[i] = 0.55 * audio[i] + 0.45 * motion[i];
      } else if (gotAudio) {
        scores[i] = audio[i];
      } else if (gotMotion) {
        scores[i] = motion[i];
      }
    }
    v.scores = (gotAudio || gotMotion) ? scores : [];
    v.cuts = cuts;
    v.analyzed = true;
  }

  // ───── التخطيط: اختيار اللحظات ─────

  (double, double) _paceRange() {
    switch (_pace) {
      case 0:
        return (1.5, 2.6);
      case 2:
        return (3.0, 6.0);
      default:
        return (1.8, 3.5);
    }
  }

  double _availableSec() {
    final (lo, hi) = _paceRange();
    var sum = 0.0;
    for (final s in _sources) {
      if (s.duration >= lo + 0.1) {
        sum += max(1, (s.duration / (hi + 0.5)).floor()) * ((lo + hi) / 2 - _td);
      }
    }
    return sum;
  }

  bool _overlaps(List<List<double>> used, double s, double e) {
    return used.any((u) => s < u[1] + 0.3 && e > u[0] - 0.3);
  }

  double _windowScore(SourceVideo v, double s, double len) {
    final a = s.floor();
    final b = min(v.scores.length - 1, (s + len).ceil() - 1);
    if (a >= v.scores.length || b < a) return 0.0;
    var sum = 0.0;
    var n = 0;
    for (var i = a; i <= b; i++) {
      sum += v.scores[i];
      n++;
    }
    double sc = n == 0 ? 0.0 : sum / n;
    for (final c in v.cuts) {
      if (c > s + 0.4 && c < s + len - 0.4) {
        sc -= 0.5; // قطع مشهد في نص المقطع = مش حلو
        break;
      }
    }
    return sc;
  }

  List<ClipPlan> _plan(Random rng) {
    final (lo, hi) = _paceRange();
    final usable = <int>[];
    for (var i = 0; i < _sources.length; i++) {
      if (_sources[i].duration >= lo + 0.1) usable.add(i);
    }
    if (usable.isEmpty) return [];

    // 1) أطوال المقاطع
    final lens = <double>[];
    var total = 0.0;
    while (total < _targetSec && lens.length < 900) {
      final len = lo + rng.nextDouble() * (hi - lo);
      total += lens.isEmpty ? len : len - _td;
      lens.add(len);
    }
    if (lens.length > 1 && total > _targetSec) {
      lens[lens.length - 1] = max(lo, lens.last - (total - _targetSec));
    }

    // 2) توزيع المقاطع على الفيديوهات (بوزن مدة كل فيديو)
    final assigned = <int, List<double>>{};
    for (final len in lens) {
      final cands = usable
          .where((i) => (assigned[i]?.length ?? 0) < max(1, (_sources[i].duration / (hi + 0.5)).floor()))
          .toList();
      if (cands.isEmpty) break;
      final sumW = cands.fold<double>(0, (a, i) => a + _sources[i].duration);
      var r = rng.nextDouble() * sumW;
      var pick = cands.last;
      for (final i in cands) {
        r -= _sources[i].duration;
        if (r <= 0) {
          pick = i;
          break;
        }
      }
      assigned.putIfAbsent(pick, () => []).add(len);
    }

    // 3) اختيار أفضل نافذة لكل مقطع
    final plans = <ClipPlan>[];
    assigned.forEach((si, lenList) {
      final v = _sources[si];
      final used = <List<double>>[];
      for (final want in lenList) {
        final len = min(want, v.duration - 0.1);
        double? bestStart;
        var bestScore = -1e9;
        if (_smart && v.scores.isNotEmpty) {
          for (var s = 0.0; s + len <= v.duration - 0.05; s += 0.5) {
            if (_overlaps(used, s, s + len)) continue;
            final sc = _windowScore(v, s, len) + rng.nextDouble() * 0.08;
            if (sc > bestScore) {
              bestScore = sc;
              bestStart = s;
            }
          }
        } else {
          for (var k = 0; k < 60; k++) {
            final s = rng.nextDouble() * max(0.0, v.duration - len - 0.1);
            if (_overlaps(used, s, s + len)) continue;
            bestStart = s;
            bestScore = rng.nextDouble();
            break;
          }
        }
        if (bestStart == null) continue;
        used.add([bestStart, bestStart + len]);
        plans.add(ClipPlan(
          source: si,
          start: bestStart,
          srcLen: len,
          len: len,
          slow: false,
          score: bestScore,
        ));
      }
    });

    // 4) حركة بطيئة لأحلى اللقطات
    if (_slowmo && plans.length >= 4) {
      final idx = List<int>.generate(plans.length, (i) => i)
        ..sort((a, b) => plans[b].score.compareTo(plans[a].score));
      final n = max(1, plans.length ~/ 8);
      for (final i in idx.take(n)) {
        final p = plans[i];
        p.start = p.start + p.len * 0.25;
        p.srcLen = p.len * 0.5;
        p.slow = true;
      }
    }

    // 5) الترتيب
    if (_smart) {
      plans.sort((a, b) =>
          a.source != b.source ? a.source.compareTo(b.source) : a.start.compareTo(b.start));
    } else {
      plans.shuffle(rng);
    }
    return plans;
  }

  // ───── الستايلات والانتقالات ─────

  Future<void> _prepareStyles(Random rng) async {
    _gradeOf.clear();
    final keys = _style == 'mix'
        ? kStyleNames.keys.where((k) => k != 'none' && k != 'mix').toList()
        : <String>[_style];
    final good = <String>[];
    for (final k in keys) {
      final g = gradeFor(k);
      if (g.isEmpty) {
        _gradeOf[k] = '';
        good.add(k);
        continue;
      }
      // نجرّب الستايل على لقطة صغيرة قبل ما نعتمد عليه
      final ok = await _exec(
        '-y -f lavfi -i color=c=gray:s=320x180:r=10:d=0.4 -vf "$g,format=yuv420p" -frames:v 2 -f null -',
      );
      if (ok) {
        _gradeOf[k] = g;
        good.add(k);
      }
    }
    if (_style == 'mix') {
      good.shuffle(rng);
      if (good.isEmpty) {
        _gradeOf['none'] = '';
        _mixOrder = ['none'];
      } else {
        _mixOrder = good;
      }
    }
  }

  String _styleForClip(int idx) {
    if (_style == 'mix') return _mixOrder[idx % _mixOrder.length];
    return _style;
  }

  Future<void> _detectTransitions() async {
    if (_trReady) return;
    final help = await _runForLogs('-hide_banner -h filter=xfade', null);
    final found = <String>{};
    if (help != null) {
      final re = RegExp(r'^\s+([a-z0-9]+)\s+-?\d+\s', multiLine: true);
      for (final m in re.allMatches(help)) {
        found.add(m.group(1)!);
      }
    }
    _supportedTr = found;
    _trReady = true;
  }

  List<String> _trPool() {
    final List<String> base;
    if (_trMode == 0) {
      base = kSmoothTr;
    } else if (_trMode == 1) {
      base = kDynamicTr;
    } else {
      base = [...kSmoothTr, ...kDynamicTr];
    }
    List<String> f;
    if (_supportedTr.length >= 5) {
      f = base.where(_supportedTr.contains).toList();
    } else {
      f = base.where(kSafeTr.contains).toList();
    }
    return f.isEmpty ? ['fade'] : f;
  }

  List<String> _pickTransitions(int count, Random rng) {
    final pool = _trPool();
    final out = <String>[];
    while (out.length < count) {
      final s = List<String>.from(pool)..shuffle(rng);
      if (out.isNotEmpty && s.length > 1 && s.first == out.last) {
        s.add(s.removeAt(0));
      }
      out.addAll(s);
    }
    return out.take(count).toList();
  }

  // ───── الترميز ─────

  Future<void> _detectEncoder() async {
    if (_encInter != null) return;
    final candidates = <List<String>>[
      [
        '-c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p',
        '-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p',
      ],
      [
        '-c:v h264_mediacodec -b:v 14M -pix_fmt yuv420p',
        '-c:v h264_mediacodec -b:v 10M -pix_fmt yuv420p',
      ],
      [
        '-c:v mpeg4 -q:v 2 -pix_fmt yuv420p',
        '-c:v mpeg4 -q:v 3 -pix_fmt yuv420p',
      ],
    ];
    for (final c in candidates) {
      final ok = await _exec('-y -f lavfi -i color=c=black:s=640x360:r=30:d=0.4 ${c[0]} -f null -');
      if (ok) {
        _encInter = c[0];
        _encFinal = c[1];
        return;
      }
    }
    _encInter = candidates.last[0];
    _encFinal = candidates.last[1];
  }

  (int, int) _outputSize() {
    switch (_aspect) {
      case '16:9':
        return _hd ? (1920, 1080) : (1280, 720);
      case '1:1':
        return _hd ? (1080, 1080) : (720, 720);
      default:
        return _hd ? (1080, 1920) : (720, 1280);
    }
  }

  Future<bool> _renderClip(
    ClipPlan p,
    int idx,
    String out,
    int outW,
    int outH, {
    required bool fancy,
    required bool audio,
  }) async {
    final v = _sources[p.source];
    final len = p.len.toStringAsFixed(3);
    final grade = fancy ? (_gradeOf[_styleForClip(idx)] ?? '') : '';
    final speed = p.slow ? 'setpts=2.0*PTS,' : '';
    final big = fancy && _pan && !_blurFit;

    var post = '';
    if (grade.isNotEmpty) post += '$grade,';
    post += 'format=yuv420p,setsar=1';

    String vf;
    if (_blurFit) {
      vf = '[0:v]${speed}fps=30,split=2[sa][sb];'
          '[sa]scale=$outW:$outH:force_original_aspect_ratio=increase,crop=$outW:$outH,boxblur=25:5[bg];'
          '[sb]scale=$outW:$outH:force_original_aspect_ratio=decrease[fg];'
          '[bg][fg]overlay=(W-w)/2:(H-h)/2,$post[v]';
    } else if (big) {
      final sw = (outW * 1.15 / 2).round() * 2;
      final sh = (outH * 1.15 / 2).round() * 2;
      String x;
      String y;
      switch (idx % 4) {
        case 0:
          x = "'(iw-ow)*min(1,t/$len)'";
          y = "'(ih-oh)/2'";
          break;
        case 1:
          x = "'(iw-ow)*(1-min(1,t/$len))'";
          y = "'(ih-oh)/2'";
          break;
        case 2:
          x = "'(iw-ow)/2'";
          y = "'(ih-oh)*min(1,t/$len)'";
          break;
        default:
          x = "'(iw-ow)*min(1,t/$len)'";
          y = "'(ih-oh)*(1-min(1,t/$len))'";
      }
      vf = '[0:v]${speed}fps=30,scale=$sw:$sh:force_original_aspect_ratio=increase,'
          'crop=$outW:$outH:x=$x:y=$y,$post[v]';
    } else {
      vf = '[0:v]${speed}fps=30,scale=$outW:$outH:force_original_aspect_ratio=increase,'
          'crop=$outW:$outH,$post[v]';
    }

    final useAudio = audio && !p.slow;
    final af = useAudio
        ? '[0:a]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,'
            'atrim=duration=$len,asetpts=PTS-STARTPTS[aud]'
        : 'anullsrc=r=44100:cl=stereo,atrim=duration=$len,asetpts=PTS-STARTPTS[aud]';

    final cmd = '-y -ss ${p.start.toStringAsFixed(3)} -t ${p.srcLen.toStringAsFixed(3)} '
        '-i "${v.path}" -filter_complex "$vf;$af" -map "[v]" -map "[aud]" -t $len '
        '$_encInter -c:a aac -b:a 192k -ar 44100 -ac 2 "$out"';
    return _exec(cmd);
  }

  /// يبني جزء الدمج بالانتقالات (فيديو xfade + صوت acrossfade)
  ({List<String> fc, String v, String a}) _chain(int n, List<double> lens, List<String> trs) {
    final fc = <String>[];
    for (var k = 0; k < n; k++) {
      fc.add('[$k:v]fps=30,format=yuv420p,setsar=1[nv$k]');
      fc.add('[$k:a]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo[na$k]');
    }
    var acc = 0.0;
    for (var k = 1; k < n; k++) {
      acc += lens[k - 1];
      final offset = acc - k * _td;
      final inV = k == 1 ? '[nv0]' : '[v${k - 1}]';
      final inA = k == 1 ? '[na0]' : '[a${k - 1}]';
      fc.add('$inV[nv$k]xfade=transition=${trs[k - 1]}:duration=$_td:offset=${offset.toStringAsFixed(3)}[v$k]');
      fc.add('$inA[na$k]acrossfade=d=$_td[a$k]');
    }
    return (
      fc: fc,
      v: n == 1 ? '[nv0]' : '[v${n - 1}]',
      a: n == 1 ? '[na0]' : '[a${n - 1}]',
    );
  }

  /// دمج مجموعة مقاطع في ملف وسيط
  Future<bool> _mergeGroup(List<String> files, List<double> lens, String out, Random rng) async {
    final n = files.length;
    final expected = lens.fold<double>(0, (a, b) => a + b) - (n - 1) * _td;

    String build(List<String> trs) {
      final c = _chain(n, lens, trs);
      final inputs = files.map((f) => '-i "$f"').join(' ');
      final fc = [...c.fc, '${c.v}null[vout]', '${c.a}anull[aout]'].join(';');
      return '-y $inputs -filter_complex "$fc" -map "[vout]" -map "[aout]" '
          '$_encInter -c:a aac -b:a 192k -ar 44100 -ac 2 "$out"';
    }

    void prog(int ms) => _tick((ms / (max(0.5, expected) * 1000)).clamp(0.0, 1.0).toDouble());

    var ok = await _exec(build(_pickTransitions(n - 1, rng)), onTime: prog);
    if (!ok && !_cancelled) {
      ok = await _exec(build(List<String>.filled(n - 1, 'fade')), onTime: prog);
    }
    return ok;
  }

  int _mergeSteps(int n) {
    var steps = 1;
    var c = n;
    while (c > _group) {
      final g = (c / _group).ceil();
      steps += g;
      c = g;
    }
    return steps;
  }

  /// يدمج المقاطع على مستويات لحد ما يبقى عدد صغير (للمونتاجات الطويلة)
  Future<(List<String>, List<double>)?> _reduce(
    List<String> files,
    List<double> lens,
    String dir,
    Random rng,
  ) async {
    var cur = files;
    var curL = lens;
    var level = 0;
    while (cur.length > _group) {
      final next = <String>[];
      final nextL = <double>[];
      final groups = (cur.length / _group).ceil();
      for (var g = 0; g < groups; g++) {
        if (_cancelled) return null;
        final s = g * _group;
        final e = min(cur.length, s + _group);
        final sf = cur.sublist(s, e);
        final sl = curL.sublist(s, e);
        if (sf.length == 1) {
          next.add(sf[0]);
          nextL.add(sl[0]);
          continue;
        }
        _set('دمج المجموعة ${g + 1}/$groups (مستوى ${level + 1})…',
            _mStart + _mW * (_stepsDone / max(1, _stepsTotal)));
        final out = '$dir/m${level}_$g.mp4';
        final ok = await _mergeGroup(sf, sl, out, rng);
        if (!ok) return null;
        final d = await _durationOf(out) ??
            (sl.fold<double>(0, (a, b) => a + b) - (sl.length - 1) * _td);
        for (final f in sf) {
          try {
            File(f).deleteSync();
          } catch (_) {}
        }
        next.add(out);
        nextL.add(d);
        _stepsDone++;
        _tick(0);
      }
      cur = next;
      curL = nextL;
      level++;
    }
    return (cur, curL);
  }

  /// الدمج النهائي: انتقالات + صور وكتابة + موسيقى + فيد
  Future<bool> _finalize({
    required List<String> files,
    required List<double> lens,
    required String out,
    required double total,
    required Random rng,
    required bool useOrig,
    required List<OverlayLayer> layers,
  }) async {
    final n = files.length;
    final hasMusic = _musicPath != null;
    final musicIdx = n;
    final layerIdx = hasMusic ? n + 1 : n;
    final totalStr = total.toStringAsFixed(3);

    String build(List<String> trs) {
      final c = _chain(n, lens, trs);
      final fc = <String>[...c.fc];
      final inputs = StringBuffer();
      for (final f in files) {
        inputs.write('-i "$f" ');
      }
      if (hasMusic) inputs.write('-stream_loop -1 -i "$_musicPath" ');
      for (final l in layers) {
        inputs.write('-loop 1 -framerate 30 -i "${l.png}" ');
      }

      var vLabel = c.v;
      final o = overlayFilters(layers, layerIdx, vLabel, total);
      fc.addAll(o.fc);
      vLabel = o.label;

      final fadeOutStart = max(0.0, total - 0.7).toStringAsFixed(3);
      fc.add('${vLabel}fade=t=in:st=0:d=0.5,fade=t=out:st=$fadeOutStart:d=0.7,format=yuv420p[vout]');

      final aFade = 'afade=t=out:st=${max(0.0, total - 1.2).toStringAsFixed(3)}:d=1.2';
      var hasAudioOut = true;
      if (hasMusic && useOrig) {
        fc.add('${c.a}volume=0.35[o]');
        fc.add('[$musicIdx:a]atrim=0:$totalStr,asetpts=PTS-STARTPTS,afade=t=in:d=1[m]');
        fc.add('[o][m]amix=inputs=2:duration=first:dropout_transition=0,volume=2,$aFade[aout]');
      } else if (hasMusic) {
        fc.add('[$musicIdx:a]atrim=0:$totalStr,asetpts=PTS-STARTPTS,afade=t=in:d=1,$aFade[aout]');
      } else if (useOrig) {
        fc.add('${c.a}$aFade[aout]');
      } else {
        hasAudioOut = false;
      }

      final audioArgs = hasAudioOut ? '-map "[aout]" -c:a aac -b:a 192k -ar 44100 -ac 2' : '-an';
      return '-y ${inputs.toString()}-filter_complex "${fc.join(';')}" -map "[vout]" $audioArgs '
          '-t $totalStr $_encFinal -movflags +faststart "$out"';
    }

    void prog(int ms) => _tick((ms / (max(0.5, total) * 1000)).clamp(0.0, 1.0).toDouble());

    final trs = n > 1 ? _pickTransitions(n - 1, rng) : <String>[];
    var ok = await _exec(build(trs), onTime: prog);
    if (!ok && !_cancelled && n > 1) {
      ok = await _exec(build(List<String>.filled(n - 1, 'fade')), onTime: prog);
    }
    return ok;
  }

  // ───── التشغيل الكامل ─────

  Future<void> _generate() async {
    if (_sources.isEmpty) {
      _toast('اختار فيديو واحد على الأقل');
      return;
    }
    setState(() {
      _busy = true;
      _cancelled = false;
      _progress = 0;
      _status = 'جاري التجهيز…';
      _errorDetail = '';
    });

    await FlutterForegroundTask.startService(
      notificationTitle: 'جاري عمل المونتاج',
      notificationText: 'المعالجة مستمرة في الخلفية...',
    );

    final rng = Random();
    final tmpBase = await getTemporaryDirectory();
    final tmp = Directory('${tmpBase.path}/montage_${DateTime.now().millisecondsSinceEpoch}');
    await tmp.create(recursive: true);

    String? resultPath;
    try {
      final warns = <String>[];

      // 1) التحليل
      final needAnalysis = _smart && _sources.any((s) => !s.analyzed);
      final aW = needAnalysis ? 0.15 : 0.0;
      const cW = 0.55;

      if (needAnalysis) {
        for (var i = 0; i < _sources.length; i++) {
          final v = _sources[i];
          if (v.analyzed) continue;
          _set('تحليل الفيديو ${i + 1}/${_sources.length} (الصوت والحركة)…', aW * i / _sources.length);
          await _analyze(v, (f) => _setP(aW * (i + f) / _sources.length));
          if (_cancelled) throw 'cancel';
        }
      }

      // 2) اختيار اللحظات
      _set('جاري اختيار أفضل اللحظات…', aW);
      final plans = _plan(rng);
      if (plans.isEmpty) throw 'تعذر اختيار مقاطع، جرّب فيديوهات أطول';
      final plannedTotal = plans.fold<double>(0, (a, p) => a + p.len) - (plans.length - 1) * _td;
      if (plannedTotal < _targetSec * 0.85) {
        warns.add(
            'المدة الناتجة حوالي ${durLabel(plannedTotal.round())} لأن الفيديوهات المختارة مش كفاية للمدة المطلوبة.');
      }

      // 3) تجهيز الأدوات
      _set('تجهيز الأدوات والستايلات…', aW);
      await _detectEncoder();
      await _detectTransitions();
      await _prepareStyles(rng);
      if (_cancelled) throw 'cancel';

      final (outW, outH) = _outputSize();

      // 4) تجهيز المقاطع
      final clipFiles = <String>[];
      final lens = <double>[];
      var anyRealAudio = false;
      for (var i = 0; i < plans.length; i++) {
        if (_cancelled) throw 'cancel';
        _set('تجهيز المقطع ${i + 1}/${plans.length} وإضافة اللمسات…', aW + cW * i / plans.length);
        final p = plans[i];
        final v = _sources[p.source];
        final out = '${tmp.path}/clip_$i.mp4';
        final tryAudio = !v.noAudio && !p.slow;
        final attempts = <List<bool>>[
          if (tryAudio) [true, true],
          if (tryAudio) [false, true],
          [true, false],
          [false, false],
        ];
        var ok = false;
        var gotAudio = false;
        for (final a in attempts) {
          if (_cancelled) break;
          ok = await _renderClip(p, i, out, outW, outH, fancy: a[0], audio: a[1]);
          if (ok) {
            gotAudio = a[1];
            break;
          }
        }
        if (_cancelled) throw 'cancel';
        if (ok) {
          if (gotAudio) {
            anyRealAudio = true;
          } else if (tryAudio) {
            v.noAudio = true;
          }
          clipFiles.add(out);
          lens.add(await _durationOf(out) ?? p.len);
        }
      }
      if (clipFiles.isEmpty) throw 'فشل تجهيز المقاطع';
      if (clipFiles.length < plans.length) {
        warns.add('${plans.length - clipFiles.length} مقطع اتخطّى بسبب خطأ في المعالجة.');
      }

      // 5) الدمج على مستويات
      _stepsTotal = _mergeSteps(clipFiles.length);
      _stepsDone = 0;
      _mStart = aW + cW;
      _mW = 1 - _mStart;
      final red = await _reduce(clipFiles, lens, tmp.path, rng);
      if (_cancelled) throw 'cancel';
      if (red == null) throw 'فشل دمج المقاطع';
      final (finalFiles, finalLens) = red;
      final total = finalLens.fold<double>(0, (a, b) => a + b) - (finalLens.length - 1) * _td;

      // 6) الصور والكتابة
      var layers = <OverlayLayer>[];
      if (_overlays.any((e) => e.valid)) {
        _set('تجهيز الصور والكتابة…', _mStart + _mW * (_stepsDone / max(1, _stepsTotal)));
        layers = await buildOverlayLayers(_overlays, outW, outH, tmp.path);
        if (layers.isEmpty) warns.add('تعذر إنشاء الصور/الكتابة على الفيديو.');
      }

      // 7) الدمج النهائي
      final dir = await montagesDir();
      final outPath = '${dir.path}/montage_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _set('الدمج النهائي (انتقالات + صور وكتابة + موسيقى)…', _mStart + _mW * (_stepsDone / max(1, _stepsTotal)));
      final useOrig = _keepOriginal && anyRealAudio;
      final ok = await _finalize(
        files: finalFiles,
        lens: finalLens,
        out: outPath,
        total: total,
        rng: rng,
        useOrig: useOrig,
        layers: layers,
      );
      if (_cancelled) throw 'cancel';
      if (!ok) throw 'فشل الدمج النهائي';

      // 8) فحص الصوت
      final wantAudio = useOrig || _musicPath != null;
      if (wantAudio && !await _hasAudioStream(outPath)) {
        warns.add('ما قدرتش أتأكد إن الصوت موجود في الملف النهائي.');
      }
      if (_keepOriginal && !anyRealAudio) {
        warns.add(_musicPath == null
            ? 'الفيديوهات الأصلية مفيهاش صوت (أو تعذر قراءته)، فالمونتاج صامت. ضيف موسيقى لو عايز صوت.'
            : 'الفيديوهات الأصلية مفيهاش صوت، اتستخدمت الموسيقى بس.');
      }

      resultPath = outPath;
      final msg = 'تم! المونتاج جاهز 🎉${warns.isEmpty ? '' : '\n⚠️ ${warns.join('\n⚠️ ')}'}';
      _set(msg, 1);
    } catch (e) {
      if (e != 'cancel' && mounted) setState(() => _errorDetail = _lastLog);
      _set(e == 'cancel' ? 'تم الإلغاء' : 'حدث خطأ: $e', 0);
    } finally {
      await FlutterForegroundTask.stopService();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }

    if (resultPath != null && mounted) {
      final r = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => PlayerPage(file: File(resultPath!), fromProject: true)),
      );
      if (r == 'remix' && mounted) _generate();
    }
  }

  void _cancel() {
    _cancelled = true;
    FFmpegKit.cancel();
  }

  // ───── الواجهة ─────

  Widget _section(String title, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: kAccent)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _chips<T>(List<T> values, T current, String Function(T) label, void Function(T) onSel) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: values
          .map((v) => ChoiceChip(
                label: Text(label(v)),
                selected: v == current,
                selectedColor: kAccent,
                onSelected: (_) => setState(() => onSel(v)),
              ))
          .toList(),
    );
  }

  Widget _switch(String title, String sub, bool value, void Function(bool) onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      activeColor: kAccent,
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(sub, style: const TextStyle(fontSize: 11, color: Colors.white38)),
      value: value,
      onChanged: (v) => setState(() => onChanged(v)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final avail = _availableSec();
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('مونتاج جديد'), backgroundColor: kBg),
        body: Column(
          children: [
            if (_busy || _status.isNotEmpty) _buildStatusCard(),
            Expanded(
              child: IgnorePointer(
                ignoring: _busy,
                child: Opacity(
                  opacity: _busy ? 0.4 : 1,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    children: [
                      _section('1) الفيديوهات', _buildSources()),
                      _section(
                        '2) مدة المونتاج: ${durLabel(_targetSec)}',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: Slider(
                                min: 10,
                                max: 600,
                                divisions: 118,
                                value: _targetSec.toDouble().clamp(10.0, 600.0).toDouble(),
                                label: durLabel(_targetSec),
                                activeColor: kAccent,
                                onChanged: (v) => setState(() => _targetSec = (v / 5).round() * 5),
                              ),
                            ),
                            _chips<int>([15, 30, 60, 120, 180, 300], _targetSec, durLabel, (v) => _targetSec = v),
                            if (_sources.isNotEmpty && _targetSec > avail * 0.95)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  '⚠️ الفيديوهات المختارة تكفي تقريباً لـ ${durLabel(avail.round())} بس. '
                                  'زوّد فيديوهات أو اختار إيقاع "هادئ".',
                                  style: const TextStyle(fontSize: 11, color: kAccent2),
                                ),
                              ),
                          ],
                        ),
                      ),
                      _section(
                        '3) إيقاع القطع',
                        _chips<int>([0, 1, 2], _pace, (v) => const ['سريع', 'متوسط', 'هادئ'][v], (v) => _pace = v),
                      ),
                      _section(
                        '4) الشكل والجودة',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _chips<String>(_aspects.keys.toList(), _aspect, (v) => _aspects[v]!, (v) => _aspect = v),
                            const SizedBox(height: 8),
                            _chips<bool>([false, true], _hd, (v) => v ? 'عالية 1080p' : 'سريعة 720p', (v) => _hd = v),
                          ],
                        ),
                      ),
                      _section(
                        '5) طريقة اختيار اللحظات',
                        _chips<bool>([true, false], _smart, (v) => v ? 'ذكي (صوت وحركة)' : 'عشوائي', (v) => _smart = v),
                      ),
                      _section(
                        '6) الستايل (اللمسة السحرية)',
                        _chips<String>(kStyleNames.keys.toList(), _style, (v) => kStyleNames[v]!, (v) => _style = v),
                      ),
                      _section(
                        '7) الانتقالات',
                        _chips<int>(
                          [0, 1, 2],
                          _trMode,
                          (v) => const ['ناعمة', 'متنوعة', 'كل الأنواع'][v],
                          (v) => _trMode = v,
                        ),
                      ),
                      _section(
                        '8) إضافات',
                        Column(
                          children: [
                            _switch('حركة كاميرا ناعمة', 'تحريك بطيء داخل كل مقطع', _pan, (v) => _pan = v),
                            _switch('خلفية ضبابية', 'بدل قص الفيديو يملأ الشاشة بضبابية', _blurFit, (v) => _blurFit = v),
                            _switch('حركة بطيئة', 'للقطات الأقوى', _slowmo, (v) => _slowmo = v),
                            _switch('الصوت الأصلي', 'صوت الفيديوهات نفسها', _keepOriginal, (v) => _keepOriginal = v),
                          ],
                        ),
                      ),
                      _section(
                        '9) صور وكتابة فوق الفيديو',
                        OverlaysCard(
                          items: _overlays,
                          aspect: _aspect,
                          backdropVideo: _sources.isEmpty ? null : _sources.first.path,
                          onChanged: () => setState(() {}),
                        ),
                      ),
                      _section('10) موسيقى (اختياري)', _buildMusic()),
                      const SizedBox(height: 70),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: kAccent,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: (_busy || _picking) ? null : _generate,
              icon: const Icon(Icons.auto_awesome, color: Colors.white),
              label: const Text(
                'ابدأ السحر ✨',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_status, style: const TextStyle(fontSize: 13)),
          if (_busy) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              color: kAccent,
              backgroundColor: Colors.white12,
              minHeight: 6,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('${(_progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const Spacer(),
                TextButton(
                  onPressed: _cancel,
                  child: const Text('إلغاء', style: TextStyle(color: Colors.redAccent)),
                ),
              ],
            ),
          ],
          if (!_busy && _errorDetail.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  'تفاصيل تقنية (ابعتها لو الخطأ اتكرر)',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                children: [
                  SelectableText(
                    _errorDetail,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontSize: 10, color: Colors.white54),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSources() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            side: const BorderSide(color: kAccent),
          ),
          onPressed: _picking ? null : _pickVideos,
          icon: _picking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                )
              : const Icon(Icons.video_library, color: kAccent),
          label: Text(_sources.isEmpty ? 'اختيار فيديوهات' : 'إضافة فيديوهات أخرى'),
        ),
        ..._sources.map((s) => Card(
              color: kSurface,
              margin: const EdgeInsets.only(top: 8),
              child: ListTile(
                dense: true,
                leading: Icon(s.hasAudio ? Icons.volume_up : Icons.volume_off, color: Colors.white54),
                title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                subtitle: Text(fmtDur(s.duration), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.white54),
                  onPressed: () => setState(() => _sources.remove(s)),
                ),
              ),
            )),
      ],
    );
  }

  Widget _buildMusic() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: const BorderSide(color: Colors.white24),
            ),
            onPressed: _pickMusic,
            icon: const Icon(Icons.music_note, color: kAccent2),
            label: Text(
              _musicName ?? 'اختيار ملف صوتي',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (_musicPath != null)
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white54),
            onPressed: () => setState(() {
              _musicPath = null;
              _musicName = null;
            }),
          ),
      ],
    );
  }
}

// ───────────────────── Split Screen (تقسيم الشاشة) ─────────────────────

Future<SourceVideo?> probeVideoFile(String path, String name) async {
  double duration = 0;
  bool hasAudio = true;
  try {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    if (info != null) {
      duration = double.tryParse(info.getDuration() ?? '') ?? 0;
      final streams = info.getStreams();
      hasAudio = streams.isEmpty ? true : streams.any(isAudioStream);
    }
  } catch (_) {}
  if (duration <= 0) {
    try {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      duration = c.value.duration.inMilliseconds / 1000;
      await c.dispose();
    } catch (_) {}
  }
  if (duration <= 0) return null;
  return SourceVideo(path: path, name: name, duration: duration, hasAudio: hasAudio);
}

class SplitPage extends StatefulWidget {
  const SplitPage({super.key});

  @override
  State<SplitPage> createState() => _SplitPageState();
}

class _SplitPageState extends State<SplitPage> {
  final _picker = ImagePicker();
  final List<SourceVideo> _clips = [];

  String _layout = 'h2';
  String _aspect = '16:9';
  bool _hd = false;
  bool _cover = true; // true = قص لملء المساحة / false = عرض كامل بخلفية سوداء

  // صور PiP وكتابة حرة فوق الفيديو
  final List<OverlayItem> _overlays = [];

  bool _busy = false;
  bool _picking = false;
  bool _cancelled = false;
  double _progress = 0;
  String _status = '';
  String _errorDetail = '';
  String _lastLog = '';
  String? _enc;

  static const _aspects = {
    '9:16': 'ريلز 9:16',
    '16:9': 'يوتيوب 16:9',
    '1:1': 'مربع 1:1',
  };

  static const _layoutNames = {
    'h2': 'جنب بعض',
    'v2': 'فوق وتحت',
    'h3': '3 جنب بعض',
    'v3': '3 فوق بعض',
    'bigTop': 'واحد كبير فوق واتنين تحت',
    'bigLeft': 'واحد كبير يسار واتنين يمين',
  };

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _set(String stage, double p) {
    if (!mounted) return;
    setState(() {
      _status = stage;
      _progress = p.clamp(0.0, 1.0).toDouble();
    });
  }

  void _setP(double p) {
    if (!mounted) return;
    setState(() => _progress = p.clamp(0.0, 1.0).toDouble());
  }

  // ───── التقسيمات ─────

  int get _count => max(2, _clips.length);

  List<String> _layoutOptions() => _count >= 3 ? ['h3', 'v3', 'bigTop', 'bigLeft'] : ['h2', 'v2'];

  String _effLayout() {
    final o = _layoutOptions();
    return o.contains(_layout) ? _layout : o.first;
  }

  (int, int) _outputSize() {
    switch (_aspect) {
      case '16:9':
        return _hd ? (1920, 1080) : (1280, 720);
      case '1:1':
        return _hd ? (1080, 1080) : (720, 720);
      default:
        return _hd ? (1080, 1920) : (720, 1280);
    }
  }

  /// كل مستطيل = [x, y, عرض, ارتفاع]
  List<List<int>> _rects(String layout, int w, int h) {
    int ev(num v) => (v / 2).floor() * 2;
    switch (layout) {
      case 'v2':
        {
          final a = ev(h / 2);
          return [
            [0, 0, w, a],
            [0, a, w, h - a],
          ];
        }
      case 'h3':
        {
          final a = ev(w / 3);
          return [
            [0, 0, a, h],
            [a, 0, a, h],
            [2 * a, 0, w - 2 * a, h],
          ];
        }
      case 'v3':
        {
          final a = ev(h / 3);
          return [
            [0, 0, w, a],
            [0, a, w, a],
            [0, 2 * a, w, h - 2 * a],
          ];
        }
      case 'bigTop':
        {
          final a = ev(h / 2);
          final w1 = ev(w / 2);
          return [
            [0, 0, w, a],
            [0, a, w1, h - a],
            [w1, a, w - w1, h - a],
          ];
        }
      case 'bigLeft':
        {
          final w1 = ev(w / 2);
          final h1 = ev(h / 2);
          return [
            [0, 0, w1, h],
            [w1, 0, w - w1, h1],
            [w1, h1, w - w1, h - h1],
          ];
        }
      default: // h2
        {
          final a = ev(w / 2);
          return [
            [0, 0, a, h],
            [a, 0, w - a, h],
          ];
        }
    }
  }

  // ───── اختيار المقاطع ─────

  Future<void> _addVideo() async {
    if (_clips.length >= 3) {
      _toast('الحد الأقصى 3 مقاطع');
      return;
    }
    final x = await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;
    setState(() => _picking = true);
    final v = await probeVideoFile(x.path, x.name);
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (v != null) {
        _clips.add(v);
      }
    });
    if (v == null) _toast('تعذر قراءة الفيديو ده');
  }

  void _moveUp(int i) {
    if (i <= 0) return;
    setState(() {
      final c = _clips.removeAt(i);
      _clips.insert(i - 1, c);
    });
  }

  // ───── FFmpeg ─────

  Future<bool> _exec(String cmd, {void Function(int ms)? onTime}) async {
    final c = Completer<bool>();
    var tail = '';
    await FFmpegKit.executeAsync(
      cmd,
      (session) async {
        final code = await session.getReturnCode();
        final ok = ReturnCode.isSuccess(code);
        if (!ok) _lastLog = tail;
        c.complete(ok);
      },
      (log) {
        tail += '${log.getMessage()}\n';
        if (tail.length > 6000) tail = tail.substring(tail.length - 3000);
      },
      onTime == null ? null : (s) => onTime(s.getTime().toInt()),
    );
    return c.future;
  }

  Future<void> _detectEncoder() async {
    if (_enc != null) return;
    const candidates = [
      '-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p',
      '-c:v h264_mediacodec -b:v 10M -pix_fmt yuv420p',
      '-c:v mpeg4 -q:v 3 -pix_fmt yuv420p',
    ];
    for (final c in candidates) {
      final ok = await _exec('-y -f lavfi -i color=c=black:s=640x360:r=30:d=0.4 $c -f null -');
      if (ok) {
        _enc = c;
        return;
      }
    }
    _enc = candidates.last;
  }

  String _cell(int i, int w, int h) {
    if (_cover) {
      return '[$i:v]fps=30,scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1[c$i]';
    }
    return '[$i:v]fps=30,scale=$w:$h:force_original_aspect_ratio=decrease,'
        'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:black,setsar=1[c$i]';
  }

  bool _plannedAudio() => _clips.any((c) => c.hasAudio && !c.muted);

  String _buildCmd(
    List<List<int>> rects,
    int w,
    int h,
    double total,
    String out,
    bool withAudio,
    List<OverlayLayer> layers,
  ) {
    final n = _clips.length;
    final totalStr = total.toStringAsFixed(3);

    final inputs = StringBuffer();
    for (final c in _clips) {
      // تكرار المقاطع الأقصر لحد ما الأطول يخلص
      inputs.write('-stream_loop -1 -i "${c.path}" ');
    }
    // طبقات الصور والكتابة (بعد مقاطع الفيديو في ترتيب المدخلات)
    for (final l in layers) {
      inputs.write('-loop 1 -framerate 30 -i "${l.png}" ');
    }

    final fc = <String>['color=c=black:s=${w}x$h:r=30[bg]'];
    for (var i = 0; i < n; i++) {
      fc.add(_cell(i, rects[i][2], rects[i][3]));
    }
    var prev = '[bg]';
    for (var i = 0; i < n; i++) {
      fc.add('$prev[c$i]overlay=${rects[i][0]}:${rects[i][1]}[t$i]');
      prev = '[t$i]';
    }
    final o = overlayFilters(layers, n, prev, total);
    fc.addAll(o.fc);
    fc.add('${o.label}format=yuv420p[vout]');

    // الصوت: دمج كل الأصوات غير المكتومة
    final audIdx = <int>[];
    if (withAudio) {
      for (var i = 0; i < n; i++) {
        if (_clips[i].hasAudio && !_clips[i].muted) audIdx.add(i);
      }
    }
    if (audIdx.isNotEmpty) {
      for (final i in audIdx) {
        fc.add('[$i:a]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo[a$i]');
      }
      if (audIdx.length == 1) {
        fc.add('[a${audIdx.first}]anull[aout]');
      } else {
        final ins = audIdx.map((i) => '[a$i]').join();
        final k = audIdx.length;
        fc.add('${ins}amix=inputs=$k:duration=first:dropout_transition=0,'
            'volume=${(k * 0.75).toStringAsFixed(2)}[aout]');
      }
    }

    final audioArgs = audIdx.isNotEmpty ? '-map "[aout]" -c:a aac -b:a 192k -ar 44100 -ac 2' : '-an';
    return '-y ${inputs.toString()}-filter_complex "${fc.join(';')}" -map "[vout]" $audioArgs '
        '-t $totalStr $_enc -movflags +faststart "$out"';
  }

  // ───── التشغيل ─────

  Future<void> _generate() async {
    if (_clips.length < 2) {
      _toast('اختار مقطعين على الأقل');
      return;
    }
    setState(() {
      _busy = true;
      _cancelled = false;
      _progress = 0;
      _status = 'جاري التجهيز…';
      _errorDetail = '';
    });

    await FlutterForegroundTask.startService(
      notificationTitle: 'جاري تقسيم الشاشة',
      notificationText: 'المعالجة مستمرة في الخلفية...',
    );

    final tmpBase = await getTemporaryDirectory();
    final tmp = Directory('${tmpBase.path}/split_${DateTime.now().millisecondsSinceEpoch}');
    await tmp.create(recursive: true);

    String? resultPath;
    String? partialPath;
    try {
      await _detectEncoder();
      final (w, h) = _outputSize();
      final rects = _rects(_effLayout(), w, h);
      final total = _clips.map((c) => c.duration).reduce(max);

      final dir = await montagesDir();
      final path = '${dir.path}/split_${DateTime.now().millisecondsSinceEpoch}.mp4';
      partialPath = path;

      var layers = <OverlayLayer>[];
      final wantOverlays = _overlays.any((e) => e.valid);
      if (wantOverlays) {
        _set('تجهيز الصور والكتابة…', 0);
        layers = await buildOverlayLayers(_overlays, w, h, tmp.path);
      }
      final overlayFailed = wantOverlays && layers.isEmpty;

      _set('جاري دمج المقاطع في شاشة واحدة…', 0);
      void prog(int ms) => _setP(ms / (max(0.5, total) * 1000));

      final planned = _plannedAudio();
      var ok = await _exec(_buildCmd(rects, w, h, total, path, true, layers), onTime: prog);
      var dropped = false;
      if (!ok && !_cancelled && planned) {
        ok = await _exec(_buildCmd(rects, w, h, total, path, false, layers), onTime: prog);
        dropped = ok;
      }
      if (_cancelled) throw 'cancel';
      if (!ok) throw 'فشل التصدير';

      resultPath = path;
      var msg = 'تم! الفيديو جاهز 🎉';
      if (dropped) msg += '\n⚠️ تعذر دمج الصوت، فالفيديو طلع صامت.';
      if (overlayFailed) msg += '\n⚠️ تعذر إنشاء الصور/الكتابة على الفيديو.';
      _set(msg, 1);
    } catch (e) {
      if (e != 'cancel' && mounted) setState(() => _errorDetail = _lastLog);
      _set(e == 'cancel' ? 'تم الإلغاء' : 'حدث خطأ: $e', 0);
    } finally {
      await FlutterForegroundTask.stopService();
      if (resultPath == null && partialPath != null) {
        try {
          final f = File(partialPath);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }

    final done = resultPath;
    if (done != null && mounted) {
      await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => PlayerPage(file: File(done), fromProject: false)),
      );
    }
  }

  void _cancel() {
    _cancelled = true;
    FFmpegKit.cancel();
  }

  // ───── الواجهة ─────

  Widget _section(String title, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: kAccent)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _chips<T>(List<T> values, T current, String Function(T) label, void Function(T) onSel) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: values
          .map((v) => ChoiceChip(
                label: Text(label(v)),
                selected: v == current,
                selectedColor: kAccent,
                onSelected: (_) => setState(() => onSel(v)),
              ))
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canStart = !_busy && !_picking && _clips.length >= 2;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('تقسيم الشاشة'), backgroundColor: kBg),
        body: Column(
          children: [
            if (_busy || _status.isNotEmpty) _buildStatusCard(),
            Expanded(
              child: IgnorePointer(
                ignoring: _busy,
                child: Opacity(
                  opacity: _busy ? 0.4 : 1,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    children: [
                      _section('1) المقاطع (2 أو 3)', _buildClips()),
                      _section(
                        '2) شكل التقسيم',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _chips<String>(
                              _layoutOptions(),
                              _effLayout(),
                              (v) => _layoutNames[v]!,
                              (v) => _layout = v,
                            ),
                            const SizedBox(height: 12),
                            _buildPreview(),
                            const SizedBox(height: 6),
                            const Text(
                              'المقطع رقم 1 بيبقى في الأعلى أو على الشمال، وتقدر تغيّر الترتيب بالسهم.',
                              style: TextStyle(fontSize: 11, color: Colors.white38),
                            ),
                          ],
                        ),
                      ),
                      _section(
                        '3) الشكل والجودة',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _chips<String>(_aspects.keys.toList(), _aspect, (v) => _aspects[v]!, (v) => _aspect = v),
                            const SizedBox(height: 8),
                            _chips<bool>([false, true], _hd, (v) => v ? 'عالية 1080p' : 'سريعة 720p', (v) => _hd = v),
                            const SizedBox(height: 8),
                            _chips<bool>(
                              [true, false],
                              _cover,
                              (v) => v ? 'قص لملء المساحة' : 'عرض كامل (بحواف سوداء)',
                              (v) => _cover = v,
                            ),
                          ],
                        ),
                      ),
                      _section(
                        '4) صور وكتابة فوق الفيديو',
                        OverlaysCard(
                          items: _overlays,
                          aspect: _aspect,
                          backdropVideo: _clips.isEmpty ? null : _clips.first.path,
                          onChanged: () => setState(() {}),
                        ),
                      ),
                      _buildInfo(),
                      const SizedBox(height: 70),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFr