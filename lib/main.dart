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
  final _textCtrl = TextEditingController();

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

  // الكتابة على الفيديو
  bool _textOn = false;
  String _textPos = 'bottom';
  String _textSize = 'm';
  String _textColor = 'white';
  bool _textBox = true;
  int _textTiming = 0; // 0 طوال الفيديو / 1 أول 5 ثواني / 2 آخر 5 ثواني

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
  static const _textPosNames = {'top': 'أعلى', 'center': 'وسط', 'bottom': 'أسفل'};
  static const _textSizeNames = {'s': 'صغير', 'm': 'متوسط', 'l': 'كبير'};
  static const Map<String, Color> _textColors = {
    'white': Colors.white,
    'yellow': Color(0xFFFFE14D),
    'pink': kAccent,
    'green': Color(0xFF6BFF8A),
    'cyan': Color(0xFF4DE1FF),
  };

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

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

  /// الدمج النهائي: انتقالات + كتابة + موسيقى + فيد
  Future<bool> _finalize({
    required List<String> files,
    required List<double> lens,
    required String out,
    required double total,
    required Random rng,
    required bool useOrig,
    String? textPng,
  }) async {
    final n = files.length;
    final hasMusic = _musicPath != null;
    final hasText = textPng != null;
    final musicIdx = n;
    final textIdx = hasMusic ? n + 1 : n;
    final totalStr = total.toStringAsFixed(3);

    String build(List<String> trs) {
      final c = _chain(n, lens, trs);
      final fc = <String>[...c.fc];
      final inputs = StringBuffer();
      for (final f in files) {
        inputs.write('-i "$f" ');
      }
      if (hasMusic) inputs.write('-stream_loop -1 -i "$_musicPath" ');
      if (hasText) inputs.write('-loop 1 -framerate 30 -i "$textPng" ');

      var vLabel = c.v;
      if (hasText) {
        var enable = '';
        if (_textTiming == 1) {
          enable = ":enable='lt(t,5)'";
        } else if (_textTiming == 2) {
          enable = ":enable='gt(t,${max(0.0, total - 5).toStringAsFixed(3)})'";
        }
        fc.add('[$textIdx:v]format=rgba[tx]');
        fc.add('$vLabel[tx]overlay=0:0$enable[vt]');
        vLabel = '[vt]';
      }
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

  // ───── الكتابة على الفيديو (صورة شفافة بتتعمل بفلاتر → بتدعم العربي) ─────

  Future<String?> _makeTextPng(String path, int w, int h) async {
    try {
      final text = _textCtrl.text.trim();
      if (text.isEmpty) return null;
      final isRtl = RegExp(r'[\u0600-\u06FF]').hasMatch(text);
      final base = min(w, h).toDouble();
      final factor = _textSize == 's' ? 0.045 : (_textSize == 'l' ? 0.09 : 0.065);
      final fs = base * factor;
      final color = _textColors[_textColor] ?? Colors.white;

      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fs,
            fontWeight: FontWeight.w800,
            height: 1.3,
            shadows: const [Shadow(color: Colors.black, blurRadius: 6, offset: Offset(0, 2))],
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
      )..layout(maxWidth: w * 0.84);

      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      final dx = (w - tp.width) / 2;
      double dy;
      if (_textPos == 'top') {
        dy = h * 0.10;
      } else if (_textPos == 'center') {
        dy = (h - tp.height) / 2;
      } else {
        dy = h * 0.84 - tp.height;
      }
      if (_textBox) {
        final pad = fs * 0.5;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(dx - pad, dy - pad * 0.6, tp.width + pad * 2, tp.height + pad * 1.2),
            Radius.circular(pad),
          ),
          Paint()..color = const Color.fromARGB(140, 0, 0, 0),
        );
      }
      tp.paint(canvas, Offset(dx, dy));
      final pic = rec.endRecording();
      final img = await pic.toImage(w, h);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) return null;
      await File(path).writeAsBytes(bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes));
      return path;
    } catch (_) {
      return null;
    }
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

      // 6) الكتابة
      String? textPng;
      if (_textOn && _textCtrl.text.trim().isNotEmpty) {
        textPng = await _makeTextPng('${tmp.path}/text.png', outW, outH);
        if (textPng == null) warns.add('تعذر إنشاء الكتابة على الفيديو.');
      }

      // 7) الدمج النهائي
      final dir = await montagesDir();
      final outPath = '${dir.path}/montage_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _set('الدمج النهائي (انتقالات + كتابة + موسيقى)…', _mStart + _mW * (_stepsDone / max(1, _stepsTotal)));
      final useOrig = _keepOriginal && anyRealAudio;
      final ok = await _finalize(
        files: finalFiles,
        lens: finalLens,
        out: outPath,
        total: total,
        rng: rng,
        useOrig: useOrig,
        textPng: textPng,
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

  Widget _sub(String t) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Text(t, style: const TextStyle(fontSize: 12, color: Colors.white54)),
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
                      _section('9) كتابة على الفيديو', _buildTextControls()),
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

  Widget _buildTextControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _switch('إضافة كتابة', 'نص يظهر فوق الفيديو (يدعم العربي)', _textOn, (v) => _textOn = v),
        if (_textOn) ...[
          TextField(
            controller: _textCtrl,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'اكتب النص هنا…',
              filled: true,
              fillColor: kSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          _sub('مكان الكتابة'),
          _chips<String>(_textPosNames.keys.toList(), _textPos, (v) => _textPosNames[v]!, (v) => _textPos = v),
          _sub('الحجم'),
          _chips<String>(_textSizeNames.keys.toList(), _textSize, (v) => _textSizeNames[v]!, (v) => _textSize = v),
          _sub('اللون'),
          Wrap(
            spacing: 10,
            children: _textColors.entries
                .map((e) => GestureDetector(
                      onTap: () => setState(() => _textColor = e.key),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: e.value,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _textColor == e.key ? kAccent2 : Colors.white24,
                            width: _textColor == e.key ? 3 : 1,
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
          _sub('وقت الظهور'),
          _chips<int>(
            [0, 1, 2],
            _textTiming,
            (v) => const ['طوال الفيديو', 'أول 5 ثواني', 'آخر 5 ثواني'][v],
            (v) => _textTiming = v,
          ),
          _switch('خلفية خلف الكتابة', 'مربع شفاف غامق يوضّح النص', _textBox, (v) => _textBox = v),
        ],
      ],
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

// ───────────────────── Player ─────────────────────

class PlayerPage extends StatefulWidget {
  final File file;
  final bool fromProject;
  const PlayerPage({super.key, required this.file, required this.fromProject});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late VideoPlayerController _c;
  bool _ready = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.file(widget.file);
    _c.initialize().then((_) async {
      if (!mounted) return;
      await _c.setLooping(true);
      await _c.play();
      setState(() => _ready = true);
    });
    _c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          _toast('لازم توافق على إذن الوصول للمعرض');
          return;
        }
      }
      await Gal.putVideo(widget.file.path, album: 'SmartMontage');
      _toast('تم الحفظ في المعرض (ألبوم SmartMontage)');
    } catch (e) {
      _toast('حدث خطأ أثناء الحفظ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    await Share.shareXFiles([XFile(widget.file.path)], text: 'مونتاج بالذكاء ✨');
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('حذف المونتاج', style: TextStyle(fontSize: 16)),
        content: const Text('هيتحذف نهائياً. متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    ThumbService.forget(widget.file);
    try {
      await widget.file.delete();
    } catch (_) {}
    if (mounted) Navigator.pop(context, 'deleted');
  }

  @override
  Widget build(BuildContext context) {
    final total = _c.value.duration.inMilliseconds.toDouble();
    final pos = _c.value.position.inMilliseconds.toDouble().clamp(0.0, total <= 0 ? 1.0 : total).toDouble();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('المونتاج', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'حذف',
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: _delete,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: !_ready
                  ? const CircularProgressIndicator(color: kAccent)
                  : GestureDetector(
                      onTap: () => _c.value.isPlaying ? _c.pause() : _c.play(),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          AspectRatio(
                            aspectRatio: _c.value.aspectRatio == 0 ? 9 / 16 : _c.value.aspectRatio,
                            child: VideoPlayer(_c),
                          ),
                          if (!_c.value.isPlaying)
                            const Icon(Icons.play_circle_fill, size: 64, color: Colors.white70),
                        ],
                      ),
                    ),
            ),
          ),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Slider(
              min: 0,
              max: total <= 0 ? 1 : total,
              value: pos,
              activeColor: kAccent,
              inactiveColor: Colors.white24,
              onChanged: (v) => _c.seekTo(Duration(milliseconds: v.toInt())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _busy ? null : _save,
                        icon: const Icon(Icons.save_alt, color: Colors.black),
                        label: const Text(
                          'حفظ بالمعرض',
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kAccent,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _share,
                        icon: const Icon(Icons.share, color: Colors.white),
                        label: const Text(
                          'مشاركة',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
                if (widget.fromProject) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: kAccent2),
                      ),
                      onPressed: () => Navigator.pop(context, 'remix'),
                      icon: const Icon(Icons.casino, color: kAccent2),
                      label: const Text(
                        'مونتاج جديد بنفس الفيديوهات 🎲',
                        style: TextStyle(color: kAccent2),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}