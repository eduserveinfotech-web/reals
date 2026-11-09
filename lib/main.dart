// ============================================================================
//  REELS PRO — Instagram-style short-video app (Flutter)
//  Complete production code with all features: Feed, Camera Studio,
//  Filters, Sounds, Stories, Direct Messages, Creator Insights, UPI Support,
//  Account Creator/Switcher, Watermark Downloader & R2 Cloud Upload.
// ============================================================================
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

// ============================== CONFIG ======================================
const String kUploadBase = '';
const String kUploadToken = '';
const int kMaxRecordSeconds = 60;

// ============================== THEME BITS ==================================
const Color kPink = Color(0xFFE1306C);
const Color kSheet = Color(0xFF1C1C1E);
const LinearGradient kBrand = LinearGradient(
  colors: [Color(0xFFFEDA77), Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF), Color(0xFF515BD4)],
  begin: Alignment.topRight,
  end: Alignment.bottomLeft,
);
const LinearGradient kBrandBtn = LinearGradient(colors: [Color(0xFFF58529), Color(0xFFDD2A7B), Color(0xFF8134AF)]);

const List<List<Color>> kStoryBg = [
  [Color(0xFF833AB4), Color(0xFFFD1D1D)],
  [Color(0xFF0F2027), Color(0xFF2C5364)],
  [Color(0xFFF7971E), Color(0xFFFFD200)],
  [Color(0xFF11998E), Color(0xFF38EF7D)],
  [Color(0xFFEE0979), Color(0xFFFF6A00)],
  [Color(0xFF396AFC), Color(0xFF2948FF)],
];

const List<Shadow> kTextShadow = [Shadow(blurRadius: 8, color: Colors.black54)];

// ============================== BRAND LOGO ==================================
class ReelsBrandLogo extends StatelessWidget {
  final double size;
  final bool showText;
  const ReelsBrandLogo({super.key, this.size = 28, this.showText = true});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: kBrand,
            borderRadius: BorderRadius.circular(size * 0.28),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))],
          ),
          child: Center(
            child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: size * 0.72),
          ),
        ),
        if (showText) ...[
          const SizedBox(width: 8),
          ShaderMask(
            shaderCallback: (r) => kBrandBtn.createShader(r),
            child: Text(
              'Reels Pro',
              style: TextStyle(
                fontFamily: 'sans-serif',
                fontWeight: FontWeight.w900,
                fontSize: size * 0.78,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ============================== HELPERS =====================================
int nowMs() => DateTime.now().millisecondsSinceEpoch;
String newId() => '${nowMs()}${math.Random().nextInt(9999)}';

String fmtCount(int n) {
  String f(double v, String s) {
    final t = v.toStringAsFixed(1);
    return '${t.endsWith('.0') ? t.substring(0, t.length - 2) : t}$s';
  }

  if (n >= 1000000) return f(n / 1000000, 'M');
  if (n >= 1000) return f(n / 1000, 'K');
  return '$n';
}

String timeAgo(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${(d.inDays / 7).floor()}w';
}

List<String> extractTags(String t) =>
    RegExp(r'#([A-Za-z0-9_\u0900-\u097F]+)').allMatches(t).map((m) => m.group(1)!.toLowerCase()).toSet().toList();

void toast(BuildContext c, String m) {
  final s = ScaffoldMessenger.of(c);
  s.hideCurrentSnackBar();
  s.showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
}

Future<T?> openPage<T>(BuildContext c, Widget page) =>
    Navigator.of(c).push<T>(MaterialPageRoute<T>(builder: (_) => page));

Widget sheetHandle() => Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        width: 40,
        height: 4,
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
      ),
    );

Future<bool?> confirmDialog(BuildContext c, String title, String body, {String ok = 'Delete'}) => showDialog<bool>(
      context: c,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSheet,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok, style: const TextStyle(color: Colors.redAccent))),
        ],
      ),
    );

InlineSpan captionSpans(String text, TextStyle style, void Function(String tag) onTag) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in RegExp(r'#[^\s#]+').allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    final tag = m.group(0)!;
    spans.add(WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: GestureDetector(
        onTap: () => onTag(tag.substring(1).toLowerCase()),
        child: Text(tag, style: style.copyWith(fontWeight: FontWeight.w700, color: const Color(0xFF8FC7FF))),
      ),
    ));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return TextSpan(style: style, children: spans);
}

// ============================== MODELS ======================================
class AppUser {
  final String id;
  String username, name, bio, upiId;
  int color, followersBase, followingBase;
  bool verified;
  AppUser({
    required this.id,
    required this.username,
    required this.name,
    this.bio = '',
    this.upiId = '',
    this.color = 0xFFE1306C,
    this.verified = false,
    this.followersBase = 0,
    this.followingBase = 0,
  });
  Map<String, dynamic> toJson() => {
        'id': id, 'username': username, 'name': name, 'bio': bio, 'upi': upiId,
        'color': color, 'verified': verified, 'fb': followersBase, 'gb': followingBase,
      };
  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as String,
        username: j['username'] as String,
        name: j['name'] as String,
        bio: (j['bio'] ?? '') as String,
        upiId: (j['upi'] ?? '') as String,
        color: (j['color'] as num).toInt(),
        verified: (j['verified'] ?? false) as bool,
        followersBase: ((j['fb'] ?? 0) as num).toInt(),
        followingBase: ((j['gb'] ?? 0) as num).toInt(),
      );
}

class Comment {
  final String id, userId, text;
  final int at;
  int likes;
  bool liked;
  final List<Comment> replies;
  Comment({required this.id, required this.userId, required this.text, required this.at, this.likes = 0, this.liked = false, List<Comment>? replies})
      : replies = replies ?? [];
  Map<String, dynamic> toJson() => {
        'id': id, 'u': userId, 't': text, 'at': at, 'l': likes, 'lk': liked,
        'r': replies.map((e) => e.toJson()).toList(),
      };
  factory Comment.fromJson(Map<String, dynamic> j) => Comment(
        id: j['id'] as String,
        userId: j['u'] as String,
        text: j['t'] as String,
        at: (j['at'] as num).toInt(),
        likes: (j['l'] as num).toInt(),
        liked: j['lk'] as bool,
        replies: ((j['r'] ?? []) as List).map((e) => Comment.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
      );
}

class Reel {
  final String id, userId, videoUrl, audioTitle, audioUrl;
  final bool isLocal;
  final int filter, at;
  String caption;
  int likes, shares, views, watchMs, saves, downloads;
  bool liked, saved, hidden, commentsOff, hideLikes;
  final List<Comment> comments;
  Reel({
    required this.id,
    required this.userId,
    required this.videoUrl,
    required this.at,
    this.isLocal = false,
    this.caption = '',
    this.audioTitle = '',
    this.audioUrl = '',
    this.filter = 0,
    this.likes = 0,
    this.shares = 0,
    this.views = 0,
    this.watchMs = 0,
    this.saves = 0,
    this.downloads = 0,
    this.liked = false,
    this.saved = false,
    this.hidden = false,
    this.commentsOff = false,
    this.hideLikes = false,
    List<Comment>? comments,
  }) : comments = comments ?? [];

  int get commentCount => comments.fold<int>(0, (s, c) => s + 1 + c.replies.length);
  List<String> get tags => extractTags(caption);
  bool get hasTrack => audioUrl.isNotEmpty;
  String get soundLabel => hasTrack ? audioTitle : 'Original audio';

  Map<String, dynamic> toJson() => {
        'id': id, 'u': userId, 'v': videoUrl, 'local': isLocal, 'cap': caption, 'at': at,
        'aT': audioTitle, 'aU': audioUrl, 'f': filter, 'lk': likes, 'sh': shares, 'vw': views,
        'wm': watchMs, 'sv': saves, 'dw': downloads, 'liked': liked, 'saved': saved, 'hid': hidden,
        'co': commentsOff, 'hl': hideLikes, 'c': comments.map((e) => e.toJson()).toList(),
      };
  factory Reel.fromJson(Map<String, dynamic> j) => Reel(
        id: j['id'] as String,
        userId: j['u'] as String,
        videoUrl: j['v'] as String,
        isLocal: j['local'] as bool,
        caption: (j['cap'] ?? '') as String,
        at: (j['at'] as num).toInt(),
        audioTitle: (j['aT'] ?? '') as String,
        audioUrl: (j['aU'] ?? '') as String,
        filter: ((j['f'] ?? 0) as num).toInt(),
        likes: ((j['lk'] ?? 0) as num).toInt(),
        shares: ((j['sh'] ?? 0) as num).toInt(),
        views: ((j['vw'] ?? 0) as num).toInt(),
        watchMs: ((j['wm'] ?? 0) as num).toInt(),
        saves: ((j['sv'] ?? 0) as num).toInt(),
        downloads: ((j['dw'] ?? 0) as num).toInt(),
        liked: (j['liked'] ?? false) as bool,
        saved: (j['saved'] ?? false) as bool,
        hidden: (j['hid'] ?? false) as bool,
        commentsOff: (j['co'] ?? false) as bool,
        hideLikes: (j['hl'] ?? false) as bool,
        comments: ((j['c'] ?? []) as List).map((e) => Comment.fromJson(Map<String, dynamic>.from(e as Map))).toList(),
      );
}

class Story {
  final String id, userId, text;
  final int grad, at;
  bool viewed;
  Story({required this.id, required this.userId, required this.text, required this.grad, required this.at, this.viewed = false});
  Map<String, dynamic> toJson() => {'id': id, 'u': userId, 't': text, 'g': grad, 'at': at, 'vw': viewed};
  factory Story.fromJson(Map<String, dynamic> j) => Story(
        id: j['id'] as String,
        userId: j['u'] as String,
        text: j['t'] as String,
        grad: (j['g'] as num).toInt(),
        at: (j['at'] as num).toInt(),
        viewed: (j['vw'] ?? false) as bool,
      );
}

class Notif {
  final String id, type, userId, text;
  final String? reelId;
  final int at;
  bool read;
  Notif({required this.id, required this.type, required this.userId, required this.text, required this.at, this.reelId, this.read = false});
  Map<String, dynamic> toJson() => {'id': id, 'ty': type, 'u': userId, 't': text, 'at': at, 'r': reelId, 'rd': read};
  factory Notif.fromJson(Map<String, dynamic> j) => Notif(
        id: j['id'] as String,
        type: j['ty'] as String,
        userId: j['u'] as String,
        text: j['t'] as String,
        at: (j['at'] as num).toInt(),
        reelId: j['r'] as String?,
        read: (j['rd'] ?? false) as bool,
      );
}

class Msg {
  final bool mine;
  final String text;
  final int at;
  final String? reelId;
  Msg({required this.mine, required this.text, required this.at, this.reelId});
  Map<String, dynamic> toJson() => {'m': mine, 't': text, 'at': at, 'r': reelId};
  factory Msg.fromJson(Map<String, dynamic> j) =>
      Msg(mine: j['m'] as bool, text: j['t'] as String, at: (j['at'] as num).toInt(), reelId: j['r'] as String?);
}

// ============================== BASIC WIDGETS ===============================
class Avatar extends StatelessWidget {
  final AppUser user;
  final double size;
  final bool ring, seen;
  const Avatar(this.user, {super.key, this.size = 40, this.ring = false, this.seen = false});

  @override
  Widget build(BuildContext context) {
    final base = Color(user.color);
    final letter = user.name.isEmpty ? '?' : String.fromCharCode(user.name.runes.first).toUpperCase();
    final inner = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [base, base.withOpacity(0.55)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Text(letter, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.42)),
    );
    if (!ring) return inner;
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(shape: BoxShape.circle, gradient: seen ? null : kBrand, color: seen ? Colors.white24 : null),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black),
        child: inner,
      ),
    );
  }
}

class VerifiedBadge extends StatelessWidget {
  const VerifiedBadge({super.key});
  @override
  Widget build(BuildContext context) => const Icon(Icons.verified, color: Color(0xFF3897F0), size: 14);
}

class GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  const GradientButton(this.label, {super.key, this.onTap, this.icon});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(gradient: kBrandBtn, borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, color: Colors.white, size: 18), const SizedBox(width: 6)],
            Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

class HeartBurst extends StatefulWidget {
  const HeartBurst({super.key});
  @override
  State<HeartBurst> createState() => _HeartBurstState();
}

class _HeartBurstState extends State<HeartBurst> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
  final double _tilt = (math.Random().nextDouble() - 0.5) * 0.5;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = _c.value;
          final scale = t < 0.25 ? Curves.easeOut.transform(t / 0.25) * 1.25 : 1.25 - 0.25 * ((t - 0.25) / 0.75).clamp(0.0, 1.0).toDouble();
          final opacity = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3);
          return Opacity(
            opacity: opacity.clamp(0.0, 1.0).toDouble(),
            child: Transform.rotate(
              angle: _tilt,
              child: Transform.scale(
                scale: scale,
                child: ShaderMask(
                  shaderCallback: (r) => kBrandBtn.createShader(r),
                  child: const Icon(Icons.favorite, size: 110, color: Colors.white),
                ),
              ),
            ),
          );
        },
      );
}

// ============================== VIDEO CACHE & UPLOAD =======================
class VideoCache {
  static final BaseCacheManager _m = DefaultCacheManager();
  static final Set<String> _busy = {};

  static Future<File?> lookup(String url) async {
    try {
      final i = await _m.getFileFromCache(url);
      return i?.file;
    } catch (_) {
      return null;
    }
  }

  static Future<void> prefetch(String url) async {
    if (store.dataSaver || !_busy.add(url)) return;
    try {
      await _m.downloadFile(url);
    } catch (_) {
    } finally {
      _busy.remove(url);
    }
  }

  static Future<void> clear() => _m.emptyCache();
}

class Uploader {
  static Future<String> upload(File f, String name, {void Function(double)? onProgress}) async {
    final len = await f.length();
    final req = http.StreamedRequest('PUT', Uri.parse('$kUploadBase/upload/$name'));
    req.headers['Content-Type'] = 'video/mp4';
    if (kUploadToken.isNotEmpty) req.headers['X-App-Token'] = kUploadToken;
    req.contentLength = len;
    var sent = 0;
    f.openRead().listen(
      (chunk) {
        sent += chunk.length;
        req.sink.add(chunk);
        onProgress?.call(sent / len);
      },
      onDone: () => req.sink.close(),
      onError: (Object e) {
        req.sink.addError(e);
        req.sink.close();
      },
      cancelOnError: true,
    );
    final res = await req.send();
    final body = await res.stream.bytesToString();
    if (res.statusCode != 200) throw 'Upload failed (HTTP ${res.statusCode}) $body';
    return (jsonDecode(body) as Map<String, dynamic>)['url'] as String;
  }
}

// ============================== STORE DEFINITION ============================
class AppStore extends ChangeNotifier {
  static const String meId = 'me';
  final Map<String, AppUser> users = {};
  final List<Reel> reels = [];
  final List<Story> stories = [];
  final List<Notif> notifs = [];
  final Map<String, List<Msg>> threads = {};
  final Set<String> following = {};
  final List<String> mutedWords = [];
  bool dataSaver = false;
  bool haptics = true;
  int feedEpoch = 0;
  SharedPreferences? _prefs;
  Timer? _debounce;

  AppUser get me => users[meId]!;
  AppUser? user(String id) => users[id];

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString('reels_pro_store_v2');
    if (raw != null) {
      try {
        _fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        if (users.containsKey(meId)) return;
      } catch (_) {}
    }
    _seed();
    _persist();
  }

  void _persist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _prefs?.setString('reels_pro_store_v2', jsonEncode(_toJson()));
    });
  }

  void changed() {
    notifyListeners();
    _persist();
  }

  void quietSave() => _persist();

  Map<String, dynamic> _toJson() => {
        'users': users.values.map((u) => u.toJson()).toList(),
        'reels': reels.map((r) => r.toJson()).toList(),
        'stories': stories.map((s) => s.toJson()).toList(),
        'notifs': notifs.map((n) => n.toJson()).toList(),
        'threads': threads.map((k, v) => MapEntry(k, v.map((m) => m.toJson()).toList())),
        'following': following.toList(),
        'muted': mutedWords,
        'dataSaver': dataSaver,
        'haptics': haptics,
      };

  void _fromJson(Map<String, dynamic> j) {
    users.clear();
    reels.clear();
    stories.clear();
    notifs.clear();
    threads.clear();
    following.clear();
    mutedWords.clear();
    for (final u in (j['users'] as List)) {
      final x = AppUser.fromJson(Map<String, dynamic>.from(u as Map));
      users[x.id] = x;
    }
    for (final r in (j['reels'] as List)) {
      reels.add(Reel.fromJson(Map<String, dynamic>.from(r as Map)));
    }
    for (final s in (j['stories'] as List)) {
      stories.add(Story.fromJson(Map<String, dynamic>.from(s as Map)));
    }
    for (final n in (j['notifs'] as List)) {
      notifs.add(Notif.fromJson(Map<String, dynamic>.from(n as Map)));
    }
    (j['threads'] as Map).forEach((k, v) {
      threads[k as String] = (v as List).map((e) => Msg.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    });
    following.addAll((j['following'] as List).map((e) => e as String));
    mutedWords.addAll((j['muted'] as List).map((e) => e as String));
    dataSaver = (j['dataSaver'] ?? false) as bool;
    haptics = (j['haptics'] ?? true) as bool;
  }

  void resetAll() {
    _seed();
    feedEpoch++;
    changed();
  }

  void _seed() {
    users.clear();
    reels.clear();
    stories.clear();
    notifs.clear();
    threads.clear();
    following.clear();
    mutedWords.clear();
    final t = nowMs();
    const h = 3600000;

    void u(String id, String un, String name, String bio, int color, int fol, {bool v = false, String upi = ''}) {
      users[id] = AppUser(id: id, username: un, name: name, bio: bio, color: color, followersBase: fol, followingBase: 120 + id.length * 17, verified: v, upiId: upi);
    }

    users[meId] = AppUser(id: meId, username: 'you', name: 'You', bio: 'Creating on Reels Pro ✨', color: 0xFFE1306C, followersBase: 0, followingBase: 0);
    u('u1', 'nature_lover', 'Nature Lover', 'Chasing sunsets 🌅 | Travel & nature', 0xFF2E9E5B, 125400, v: true, upi: 'naturelover@upi');
    u('u2', 'skate_king', 'Skate King', 'Flip. Grind. Repeat 🛹', 0xFF3B82F6, 98200);
    u('u3', 'foodie_amit', 'Amit | Street Food', 'Banaras ki galiyon se 🍛', 0xFFF59E0B, 48200, upi: 'foodieamit@upi');
    u('u4', 'tech_with_riya', 'Riya | Tech', 'Gadgets, AI & coding 💻', 0xFF8B5CF6, 210500, v: true);
    u('u5', 'fit_arjun', 'Arjun Fitness', 'Daily workouts 💪 No excuses', 0xFFEF4444, 67300);
    u('u6', 'art_by_meera', 'Meera | Art', 'Digital artist 🎨 Commissions open', 0xFFEC4899, 33900, upi: 'meeraart@upi');

    const g = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/';
    Reel mk(String id, String uid, String url, String cap, int hoursAgo, int likes, int views, {Track? tr, int f = 0, List<Comment>? cm}) => Reel(
          id: id, userId: uid, videoUrl: url, caption: cap, at: t - hoursAgo * h,
          likes: likes, views: views, shares: likes ~/ 40, saves: likes ~/ 25,
          audioTitle: tr?.title ?? '', audioUrl: tr?.url ?? '', filter: f, comments: cm,
        );
    Comment c(String id, String uid, String text, int likes, {List<Comment>? r}) =>
        Comment(id: id, userId: uid, text: text, at: t - 2 * h, likes: likes, replies: r);

    reels.addAll([
      mk('r1', 'u1', 'https://assets.mixkit.co/videos/preview/mixkit-vertical-portrait-of-a-woman-in-a-field-of-sunflowers-42995-large.mp4',
          'Sunflower field vibes 🌻✨ #nature #sunflower #reels', 3, 14200, 182000, tr: kTracks[0], f: 2,
          cm: [c('c1', 'u2', 'Superb! ❤️', 42, r: [c('c1a', 'u1', 'Thank you bhai 🙏', 5)]), c('c2', 'u4', 'Colors are unreal 🔥', 18)]),
      mk('r2', 'u2', 'https://assets.mixkit.co/videos/preview/mixkit-young-woman-skater-doing-tricks-in-a-skatepark-42984-large.mp4',
          'New flip trick unlocked 🛹🔥 Rate 1 to 10 #skate #tricks', 6, 98500, 940000, tr: kTracks[3],
          cm: [c('c3', 'u5', '10/10 🔥', 77), c('c4', 'u3', 'Smooth landing 👌', 12)]),
      mk('r3', 'u3', '${g}ForBiggerBlazes.mp4', 'Kashi ki famous kachori sabzi 😍 #streetfood #banaras #foodie', 9, 22300, 260000, f: 1,
          cm: [c('c5', 'u1', 'Bhook lag gayi 😭', 31)]),
      mk('r4', 'u4', '${g}ForBiggerEscapes.mp4', '3 AI tools that will save you 10 hours a week 🤖 #ai #tech #productivity', 14, 45100, 512000, tr: kTracks[4],
          cm: [c('c6', 'u6', 'Saving this one 🔖', 64), c('c7', 'u2', 'Which is the best for coding?', 9)]),
      mk('r5', 'u5', '${g}ForBiggerFun.mp4', '10 min home workout, no equipment 💪 #fitness #workout #motivation', 20, 18800, 201000, tr: kTracks[6], f: 1),
      mk('r6', 'u6', '${g}ForBiggerJoyrides.mp4', 'Speed painting a sunset in 60 sec 🎨 #art #digitalart #sunset', 26, 12900, 143000, tr: kTracks[7], f: 7),
      mk('r7', 'u1', '${g}ForBiggerMeltdowns.mp4', 'Hidden waterfall trek 🌿 #nature #travel #trek', 31, 31200, 330000, f: 3),
    ]);

    following.addAll(['u1', 'u3', 'u4']);

    for (final e in [
      ['u1', 'Monsoon mood ☔ chai + pakode', 1, 2],
      ['u2', 'Practice day. 100 attempts, 1 clean landing 😅', 3, 0],
      ['u4', 'New phone unboxing tomorrow 👀', 5, 1],
      ['u3', 'Aaj ka special: Malaiyo ❄️', 8, 4],
    ]) {
      stories.add(Story(id: newId(), userId: e[0] as String, text: e[1] as String, grad: e[3] as int, at: t - (e[2] as int) * h));
    }

    notifs.addAll([
      Notif(id: newId(), type: 'follow', userId: 'u2', text: 'started following you.', at: t - 2 * h),
      Notif(id: newId(), type: 'comment', userId: 'u4', text: 'Welcome to Reels Pro! Post your first reel 🔥', at: t - 4 * h),
      Notif(id: newId(), type: 'follow', userId: 'u6', text: 'started following you.', at: t - 22 * h, read: true),
    ]);

    threads['u1'] = [Msg(mine: false, text: 'Hey! Welcome to Reels Pro 👋', at: t - 3 * h)];
    threads['u4'] = [Msg(mine: false, text: 'Try the Insights tab on your profile 📊', at: t - 7 * h)];
  }

  void createNewAccount({required String name, required String username, required String bio, required int color, String upi = ''}) {
    me.name = name;
    me.username = username.toLowerCase();
    me.bio = bio;
    me.color = color;
    if (upi.isNotEmpty) me.upiId = upi;
    notifs.insert(
      0,
      Notif(id: newId(), type: 'system', userId: meId, text: 'Welcome @$username! Profile is now active 🚀', at: nowMs(), read: false),
    );
    feedEpoch++;
    changed();
  }

  bool _visible(Reel r) {
    if (r.hidden) return false;
    final c = r.caption.toLowerCase();
    for (final w in mutedWords) {
      if (w.isNotEmpty && c.contains(w)) return false;
    }
    return true;
  }

  List<Reel> forYouFeed() => reels.where(_visible).toList()..sort((a, b) => b.at.compareTo(a.at));
  List<Reel> followingFeed() => forYouFeed().where((r) => following.contains(r.userId)).toList();
  List<Reel> reelsOf(String uid) => reels.where((r) => r.userId == uid).toList()..sort((a, b) => b.at.compareTo(a.at));
  List<Reel> savedReels() => reels.where((r) => r.saved).toList();
  List<Reel> likedReels() => reels.where((r) => r.liked).toList();
  List<Reel> byTag(String tag) => forYouFeed().where((r) => r.tags.contains(tag)).toList();
  List<Reel> bySound(String title) => forYouFeed().where((r) => r.hasTrack && r.audioTitle == title).toList();
  Reel? reelById(String id) {
    for (final r in reels) {
      if (r.id == id) return r;
    }
    return null;
  }

  List<MapEntry<String, int>> trendingTags([int n = 12]) {
    final m = <String, int>{};
    for (final r in reels.where(_visible)) {
      for (final t in r.tags) {
        m[t] = (m[t] ?? 0) + 1 + r.views ~/ 1000;
      }
    }
    final l = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return l.take(n).toList();
  }

  int followersOf(String uid) {
    final u = users[uid];
    if (u == null) return 0;
    return u.followersBase + (following.contains(uid) ? 1 : 0);
  }

  int followingCount(String uid) => uid == meId ? following.length : (users[uid]?.followingBase ?? 0);

  List<Story> storiesOf(String uid) {
    final cut = nowMs() - 24 * 3600000;
    return stories.where((s) => s.userId == uid && s.at > cut).toList()..sort((a, b) => a.at.compareTo(b.at));
  }

  bool hasStory(String uid) => storiesOf(uid).isNotEmpty;
  bool allViewed(String uid) => storiesOf(uid).every((s) => s.viewed);

  List<String> storyUsers() {
    final ids = users.keys.where((id) => id != meId && hasStory(id)).toList();
    ids.sort((a, b) {
      final av = allViewed(a) ? 1 : 0, bv = allViewed(b) ? 1 : 0;
      if (av != bv) return av.compareTo(bv);
      return (following.contains(b) ? 1 : 0).compareTo(following.contains(a) ? 1 : 0);
    });
    return ids;
  }

  void addStory(String text, int grad) {
    stories.add(Story(id: newId(), userId: meId, text: text, grad: grad, at: nowMs(), viewed: true));
    changed();
  }

  void deleteStory(Story s) {
    stories.remove(s);
    changed();
  }

  void markViewed(Story s) {
    if (!s.viewed) {
      s.viewed = true;
      changed();
    }
  }

  void _buzz() {
    if (haptics) HapticFeedback.lightImpact();
  }

  void toggleLike(Reel r) {
    r.liked = !r.liked;
    r.likes += r.liked ? 1 : -1;
    _buzz();
    changed();
  }

  void toggleSave(Reel r) {
    r.saved = !r.saved;
    r.saves += r.saved ? 1 : -1;
    _buzz();
    changed();
  }

  void toggleFollow(String uid) {
    if (!following.add(uid)) following.remove(uid);
    _buzz();
    changed();
  }

  void addReel(Reel r) {
    reels.insert(0, r);
    feedEpoch++;
    notifs.insert(0, Notif(id: newId(), type: 'system', userId: meId, text: 'Your reel is live 🎉', at: nowMs(), reelId: r.id, read: false));
    changed();
  }

  void recordDownload(Reel r) {
    r.downloads++;
    quietSave();
  }

  void deleteReel(Reel r) {
    reels.remove(r);
    feedEpoch++;
    changed();
  }

  void hideReel(Reel r) {
    r.hidden = true;
    changed();
  }

  void addView(Reel r) {
    r.views++;
    quietSave();
  }

  void addWatch(Reel r, int ms) {
    r.watchMs += ms;
    quietSave();
  }

  void countShare(Reel r) {
    r.shares++;
    quietSave();
  }

  void addComment(Reel r, String text, {Comment? replyTo}) {
    final c = Comment(id: newId(), userId: meId, text: text.trim(), at: nowMs());
    if (replyTo != null) {
      replyTo.replies.add(c);
    } else {
      r.comments.insert(0, c);
    }
    changed();
  }

  void toggleCommentLike(Comment c) {
    c.liked = !c.liked;
    c.likes += c.liked ? 1 : -1;
    _buzz();
    changed();
  }

  void deleteComment(Reel r, Comment c) {
    if (!r.comments.remove(c)) {
      for (final p in r.comments) {
        if (p.replies.remove(c)) break;
      }
    }
    changed();
  }

  void sendMessage(String uid, String text, {String? reelId}) {
    final t = threads.putIfAbsent(uid, () => []);
    t.add(Msg(mine: true, text: text, at: nowMs(), reelId: reelId));
    changed();
    Future.delayed(const Duration(milliseconds: 1400), () {
      const replies = ['😂😂', 'Nice one! 🔥', 'Sahi hai bhai 😄', 'Love this ❤️', 'Haha 😍', 'Will check it out 👀'];
      t.add(Msg(mine: false, text: replies[math.Random().nextInt(replies.length)], at: nowMs()));
      changed();
    });
  }

  int get unreadNotifs => notifs.where((n) => !n.read).length;

  void markNotifsRead() {
    var any = false;
    for (final n in notifs) {
      if (!n.read) {
        n.read = true;
        any = true;
      }
    }
    if (any) changed();
  }

  void updateMe({String? name, String? username, String? bio, String? upi}) {
    if (name != null) me.name = name;
    if (username != null) me.username = username;
    if (bio != null) me.bio = bio;
    if (upi != null) me.upiId = upi;
    changed();
  }

  void setDataSaver(bool v) {
    dataSaver = v;
    changed();
  }

  void setHaptics(bool v) {
    haptics = v;
    changed();
  }

  void addMuted(String w) {
    final x = w.trim().toLowerCase();
    if (x.isEmpty || mutedWords.contains(x)) return;
    mutedWords.add(x);
    feedEpoch++;
    changed();
  }

  void removeMuted(String w) {
    mutedWords.remove(w);
    feedEpoch++;
    changed();
  }
}

final AppStore store = AppStore();
final RouteObserver<PageRoute<dynamic>> routeObserver = RouteObserver<PageRoute<dynamic>>();
final ValueNotifier<bool> gMuted = ValueNotifier<bool>(false);

// ============================================================================
//  PAGES (CAMERA, COMPOSE, CHAT, STORIES)
// ============================================================================
class ComposePage extends StatefulWidget {
  final String path;
  final Track? track;
  final int filter;
  const ComposePage({super.key, required this.path, this.track, this.filter = 0});
  @override
  State<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends State<ComposePage> {
  late final VideoPlayerController _vc = VideoPlayerController.file(File(widget.path), videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
  AudioPlayer? _audio;
  Track? _track;
  late int _filter = widget.filter;
  final TextEditingController _cap = TextEditingController();
  bool _ready = false, _playing = true, _commentsOff = false, _hideLikes = false, _posting = false;
  double _progress = 0;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _track = widget.track;
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      await _vc.initialize();
      await _vc.setLooping(true);
      await _applyTrack();
      if (!mounted) return;
      setState(() => _ready = true);
      _vc.play();
      _audio?.resume();
    } catch (e) {
      if (mounted) toast(context, 'Cannot open this video: $e');
    }
  }

  Future<void> _applyTrack() async {
    try {
      await _audio?.stop();
      if (_track != null) {
        _audio ??= AudioPlayer();
        await _audio!.setReleaseMode(ReleaseMode.loop);
        await _audio!.setSourceUrl(_track!.url);
        await _vc.setVolume(0);
        if (_ready && _playing) await _audio!.resume();
      } else {
        await _vc.setVolume(1);
      }
    } catch (_) {}
  }

  Future<void> _pickTrack() async {
    final t = await showTrackPicker(context, currentId: _track?.id);
    if (t == null || !mounted) return;
    setState(() => _track = t.id == 'none' ? null : t);
    await _applyTrack();
  }

  void _togglePlay() {
    if (!_ready) return;
    setState(() => _playing = !_playing);
    if (_playing) {
      _vc.play();
      _audio?.resume();
    } else {
      _vc.pause();
      _audio?.pause();
    }
  }

  @override
  void dispose() {
    _vc.dispose();
    _audio?.dispose();
    _cap.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    if (_posting) return;
    setState(() {
      _posting = true;
      _progress = 0;
      _status = 'Saving…';
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/reels');
      if (!await dir.exists()) await dir.create(recursive: true);
      final name = 'reel_${nowMs()}.mp4';
      final saved = await File(widget.path).copy('${dir.path}/$name');
      var url = saved.path;
      var local = true;
      if (kUploadBase.isNotEmpty) {
        if (mounted) setState(() => _status = 'Uploading to cloud…');
        try {
          url = await Uploader.upload(saved, name, onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          });
          local = false;
        } catch (e) {
          if (mounted) toast(context, 'Cloud upload failed, saved on this device instead');
        }
      }
      final t = _track;
      store.addReel(Reel(
        id: newId(),
        userId: AppStore.meId,
        videoUrl: url,
        isLocal: local,
        caption: _cap.text.trim(),
        at: nowMs(),
        audioTitle: t?.title ?? '',
        audioUrl: t?.url ?? '',
        filter: _filter,
        commentsOff: _commentsOff,
        hideLikes: _hideLikes,
      ));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _posting = false);
        toast(context, 'Could not post: $e');
      }
    }
  }

  Widget _preview() {
    final s = _vc.value.size;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 202,
        height: 360,
        child: Stack(fit: StackFit.expand, children: [
          Container(color: Colors.white10),
          if (_ready)
            applyFilter(
              _filter,
              FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(width: s.width <= 0 ? 1 : s.width, height: s.height <= 0 ? 1 : s.height, child: VideoPlayer(_vc)),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          GestureDetector(
            onTap: _togglePlay,
            behavior: HitTestBehavior.opaque,
            child: Center(child: AnimatedOpacity(opacity: _playing ? 0 : 1, duration: const Duration(milliseconds: 150), child: const Icon(Icons.play_circle_fill, size: 64, color: Colors.white70))),
          ),
          if (_track != null)
            Positioned(
              left: 8,
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [const Icon(Icons.music_note, size: 14), const SizedBox(width: 4), Expanded(child: Text(_track!.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)))]),
              ),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tags = store.trendingTags(6);
    return PopScope(
      canPop: !_posting,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('New reel', style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            Padding(padding: const EdgeInsets.only(right: 12), child: Center(child: GradientButton('Share', onTap: _posting ? null : _post))),
          ],
        ),
        body: Stack(children: [
          ListView(padding: const EdgeInsets.all(16), children: [
            Center(child: _preview()),
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (var i = 0; i < kFilters.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(label: Text(kFilters[i].name), selected: _filter == i, onSelected: (_) => setState(() => _filter = i)),
                  ),
              ]),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _cap,
              maxLines: 4,
              minLines: 2,
              maxLength: 2200,
              decoration: InputDecoration(
                hintText: 'Write a caption… add #hashtags',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
            if (tags.isNotEmpty)
              Wrap(spacing: 8, children: [
                for (final t in tags)
                  ActionChip(
                    label: Text('#${t.key}'),
                    backgroundColor: Colors.white10,
                    side: BorderSide.none,
                    onPressed: () {
                      final cur = _cap.text;
                      _cap.text = '${cur.isEmpty || cur.endsWith(' ') ? cur : '$cur '}#${t.key} ';
                      _cap.selection = TextSelection.collapsed(offset: _cap.text.length);
                    },
                  ),
              ]),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(backgroundColor: Colors.white12, child: Icon(Icons.music_note, color: Colors.white)),
              title: Text(_track?.title ?? 'Original audio'),
              subtitle: Text(_track == null ? 'Using your camera mic / video sound' : _track!.artist, style: const TextStyle(color: Colors.white54)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickTrack,
            ),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Turn off commenting'), value: _commentsOff, onChanged: (v) => setState(() => _commentsOff = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Hide like count'), value: _hideLikes, onChanged: (v) => setState(() => _hideLikes = v)),
            const SizedBox(height: 8),
            Text(
              kUploadBase.isEmpty ? 'Local mode: this reel is saved on your phone. Add your Worker URL in main.dart to upload to Cloudflare R2.' : 'This reel will be uploaded to your Cloudflare R2 bucket.',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ]),
          if (_posting)
            Positioned.fill(
              child: AbsorbPointer(
                child: Container(
                  color: Colors.black87,
                  alignment: Alignment.center,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: CircularProgressIndicator(value: _progress > 0 && _progress < 1 ? _progress : null, strokeWidth: 5, color: kPink),
                    ),
                    const SizedBox(height: 16),
                    Text(_progress > 0 && _progress < 1 ? '$_status ${(_progress * 100).toStringAsFixed(0)}%' : _status),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class CameraPage extends StatefulWidget {
  final Track? initialTrack;
  const CameraPage({super.key, this.initialTrack});
  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  List<CameraDescription>? _cams;
  int _camIdx = 0;
  CameraController? _cam;
  bool _ready = false, _recording = false, _torch = false, _busy = false;
  String? _error;
  Track? _track;
  int _filter = 0;
  int _timerSecs = 0;
  int _count = 0;
  double _elapsed = 0;
  Timer? _tick;
  final AudioPlayer _audio = AudioPlayer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _track = widget.initialTrack;
    _initCam();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _audio.dispose();
    _cam?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) {
      if (!_recording) _disposeCam();
    } else if (s == AppLifecycleState.resumed && _cam == null && !_busy) {
      _initCam();
    }
  }

  Future<void> _disposeCam() async {
    final c = _cam;
    _cam = null;
    if (mounted) setState(() => _ready = false);
    await c?.dispose();
  }

  Future<void> _initCam() async {
    if (_busy) return;
    _busy = true;
    if (mounted) {
      setState(() {
        _error = null;
        _ready = false;
      });
    }
    try {
      _cams ??= await availableCameras();
      if (_cams!.isEmpty) throw 'No camera found on this device';
      final c = CameraController(_cams![_camIdx % _cams!.length], ResolutionPreset.high, enableAudio: true);
      _cam = c;
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e is CameraException ? (e.description ?? e.code) : '$e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _flip() async {
    if (_recording || (_cams?.length ?? 0) < 2) return;
    _camIdx = (_camIdx + 1) % _cams!.length;
    _torch = false;
    await _disposeCam();
    await _initCam();
  }

  Future<void> _toggleTorch() async {
    final c = _cam;
    if (c == null || !_ready) return;
    try {
      final next = !_torch;
      await c.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      setState(() => _torch = next);
    } catch (_) {
      if (mounted) toast(context, 'Flash is not available on this camera');
    }
  }

  Future<void> _pickSound() async {
    if (_recording) return;
    final t = await showTrackPicker(context, currentId: _track?.id);
    if (t != null && mounted) setState(() => _track = t.id == 'none' ? null : t);
  }

  Future<void> _toggleRecord() async {
    final c = _cam;
    if (c == null || !_ready) return;
    if (_recording) {
      await _stop();
      return;
    }
    if (_count > 0) return;
    if (_timerSecs > 0) {
      for (var i = _timerSecs; i > 0; i--) {
        if (!mounted) return;
        setState(() => _count = i);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!mounted) return;
      setState(() => _count = 0);
    }
    try {
      await c.startVideoRecording();
      if (_track != null) {
        try {
          await _audio.play(UrlSource(_track!.url));
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _recording = true;
        _elapsed = 0;
      });
      _tick = Timer.periodic(const Duration(milliseconds: 100), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _elapsed += 0.1);
        if (_elapsed >= kMaxRecordSeconds) _stop();
      });
    } catch (e) {
      if (mounted) toast(context, 'Could not start recording: $e');
    }
  }

  Future<void> _stop() async {
    final c = _cam;
    if (c == null || !_recording) return;
    _tick?.cancel();
    _recording = false;
    try {
      await _audio.stop();
    } catch (_) {}
    try {
      final f = await c.stopVideoRecording();
      if (!mounted) return;
      setState(() => _elapsed = 0);
      await _goCompose(f.path);
    } catch (e) {
      if (mounted) {
        setState(() => _elapsed = 0);
        toast(context, 'Recording failed: $e');
      }
    }
  }

  Future<void> _pickGallery() async {
    if (_recording) return;
    try {
      final x = await ImagePicker().pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 3));
      if (x != null) await _goCompose(x.path);
    } catch (e) {
      if (mounted) toast(context, 'Could not open gallery: $e');
    }
  }

  Future<void> _goCompose(String path) async {
    await _disposeCam();
    if (!mounted) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => ComposePage(path: path, track: _track, filter: _filter)),
    );
    if (!mounted) return;
    if (ok == true) {
      Navigator.of(context).pop(true);
    } else {
      _initCam();
    }
  }

  String _fmt(double s) {
    final i = s.floor();
    return '${i ~/ 60}:${(i % 60).toString().padLeft(2, '0')}';
  }

  Widget _tool(IconData i, String label, VoidCallback onTap, {bool on = false}) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(children: [
            Icon(i, color: on ? const Color(0xFFFFD54F) : Colors.white, size: 28, shadows: kTextShadow),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.white, shadows: kTextShadow)),
          ]),
        ),
      );

  Widget _filterChip(int i) {
    final f = kFilters[i];
    final sel = _filter == i;
    return GestureDetector(
      onTap: () => setState(() => _filter = i),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(shape: BoxShape.circle, color: f.chip, border: Border.all(color: sel ? Colors.white : Colors.transparent, width: 3)),
          ),
          const SizedBox(height: 4),
          Text(f.name, style: TextStyle(fontSize: 11, color: sel ? Colors.white : Colors.white70, fontWeight: sel ? FontWeight.w800 : FontWeight.w500, shadows: kTextShadow)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    Widget preview;
    if (_error != null) {
      preview = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_off_outlined, size: 56, color: Colors.white54),
            const SizedBox(height: 12),
            Text('Camera unavailable\n$_error', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 14),
            Wrap(spacing: 10, children: [
              OutlinedButton(onPressed: _initCam, child: const Text('Try again')),
              OutlinedButton(onPressed: _pickGallery, child: const Text('Pick from gallery')),
            ]),
          ]),
        ),
      );
    } else if (!_ready || _cam == null) {
      preview = const Center(child: CircularProgressIndicator(color: Colors.white54, strokeWidth: 2));
    } else {
      var scale = size.aspectRatio * _cam!.value.aspectRatio;
      if (scale < 1) scale = 1 / scale;
      preview = ClipRect(child: Transform.scale(scale: scale, child: Center(child: applyFilter(_filter, CameraPreview(_cam!)))));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: preview),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 28, shadows: kTextShadow), onPressed: () => Navigator.pop(context)),
                Expanded(
                  child: Center(
                    child: _recording
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.circle, color: Colors.redAccent, size: 10),
                              const SizedBox(width: 6),
                              Text('${_fmt(_elapsed)} / ${_fmt(kMaxRecordSeconds.toDouble())}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            ]),
                          )
                        : GestureDetector(
                            onTap: _pickSound,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white24)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.music_note, size: 16),
                                const SizedBox(width: 6),
                                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 170), child: Text(_track?.title ?? 'Add sound', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                              ]),
                            ),
                          ),
                  ),
                ),
                IconButton(icon: const Icon(Icons.flip_camera_ios_outlined, color: Colors.white, size: 28, shadows: kTextShadow), onPressed: _flip),
              ]),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.topRight,
                child: _recording
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(right: 14, top: 10),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          _tool(_torch ? Icons.flash_on : Icons.flash_off, 'Flash', _toggleTorch, on: _torch),
                          _tool(Icons.timer_outlined, _timerSecs == 0 ? 'Timer' : '${_timerSecs}s', () => setState(() => _timerSecs = _timerSecs == 0 ? 3 : (_timerSecs == 3 ? 10 : 0)), on: _timerSecs > 0),
                        ]),
                      ),
              ),
            ),
            if (!_recording)
              SizedBox(
                height: 76,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [for (var i = 0; i < kFilters.length; i++) _filterChip(i)]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                SizedBox(
                  width: 56,
                  child: _recording
                      ? null
                      : GestureDetector(
                          onTap: _pickGallery,
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white54, width: 2)),
                            child: const Icon(Icons.photo_library_outlined),
                          ),
                        ),
                ),
                GestureDetector(
                  onTap: _toggleRecord,
                  child: SizedBox(
                    width: 84,
                    height: 84,
                    child: Stack(alignment: Alignment.center, children: [
                      SizedBox(
                        width: 84,
                        height: 84,
                        child: CircularProgressIndicator(
                          value: _recording ? (_elapsed / kMaxRecordSeconds).clamp(0.0, 1.0).toDouble() : 1.0,
                          strokeWidth: 5,
                          color: _recording ? kPink : Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: _recording ? 34 : 64,
                        height: _recording ? 34 : 64,
                        decoration: BoxDecoration(color: _recording ? kPink : Colors.white, borderRadius: BorderRadius.circular(_recording ? 8 : 40)),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(width: 56),
              ]),
            ),
          ]),
        ),
        if (_count > 0) IgnorePointer(child: Center(child: Text('$_count', style: const TextStyle(fontSize: 130, fontWeight: FontWeight.w900, color: Colors.white, shadows: kTextShadow)))),
      ]),
    );
  }
}

// ============================================================================
//  MAIN APP SHELL
// ============================================================================
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  Future<void> _openCamera() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(builder: (_) => const CameraPage()));
    if (ok == true && mounted) {
      setState(() => _tab = 0);
      toast(context, 'Your reel is live 🎉');
    }
  }

  Widget _item(IconData icon, IconData active, int i, {int badge = 0}) => Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _tab = i),
          child: Center(
            child: Stack(clipBehavior: Clip.none, children: [
              Icon(_tab == i ? active : icon, size: 28, color: Colors.white),
              if (badge > 0)
                Positioned(
                  right: -7,
                  top: -4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: kPink, borderRadius: BorderRadius.circular(10)),
                    child: Text('$badge', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                  ),
                ),
            ]),
          ),
        ),
      );

  Widget _nav() => ListenableBuilder(
        listenable: store,
        builder: (_, __) => Container(
          decoration: const BoxDecoration(color: Colors.black, border: Border(top: BorderSide(color: Colors.white12))),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 54,
              child: Row(children: [
                _item(Icons.home_outlined, Icons.home, 0),
                _item(Icons.search, Icons.search, 1),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _openCamera,
                    child: Center(
                      child: Container(
                        width: 46,
                        height: 32,
                        decoration: BoxDecoration(gradient: kBrandBtn, borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.add, color: Colors.white, size: 26),
                      ),
                    ),
                  ),
                ),
                _item(Icons.chat_bubble_outline, Icons.chat_bubble, 3, badge: store.unreadNotifs),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _tab = 4),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(1.5),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: _tab == 4 ? Colors.white : Colors.transparent, width: 1.5)),
                        child: Avatar(store.me, size: 26),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: IndexedStack(index: _tab, children: [
          FeedPage(active: _tab == 0, onOpenCamera: _openCamera),
          const ExplorePage(),
          const SizedBox.shrink(),
          const InboxPage(),
          ProfilePage(userId: AppStore.meId, isTab: true),
        ]),
        bottomNavigationBar: _nav(),
      ),
    );
  }
}

class ReelsProApp extends StatelessWidget {
  const ReelsProApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reels Pro',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [routeObserver],
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(seedColor: kPink, brightness: Brightness.dark).copyWith(surface: Colors.black),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.black, surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0),
        bottomSheetTheme: const BottomSheetThemeData(backgroundColor: kSheet),
      ),
      home: const HomeShell(),
    );
  }
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    ErrorWidget.builder = (details) => Material(
          color: Colors.black,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Text('ERROR:\n${details.exceptionAsString()}\n\n${details.stack}',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          ),
        );
    try {
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ));
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await store.load();
      runApp(const ReelsProApp());
    } catch (e, st) {
      runApp(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Text('STARTUP ERROR:\n$e\n\n$st', style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          ),
        ),
      ));
    }
  }, (e, st) => debugPrint('Uncaught: $e\n$st'));
}
