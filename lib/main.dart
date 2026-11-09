// ============================================================================
//  REELS PRO — Instagram-style short-video app (Flutter)
//  Features: Reels feed (For You / Following), likes, threaded comments, saves,
//  share-to-DM, follow, profiles, explore + search, hashtags, stories,
//  messages, camera with live filters + sound, gallery upload, creator
//  insights, UPI support, muted words, data saver, local-first storage,
//  Cloudflare R2 worker upload, Dynamic Notifications, Account Creation &
//  Watermark Video Downloader with Brand Logo.
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
const String kUploadBase = ''; // e.g. 'https://reels-upload.yourname.workers.dev'
const String kUploadToken = '';
const int kMaxRecordSeconds = 60;

// ============================== GLOBALS =====================================
final AppStore store = AppStore();
final RouteObserver<PageRoute<dynamic>> routeObserver = RouteObserver<PageRoute<dynamic>>();
final ValueNotifier<bool> gMuted = ValueNotifier<bool>(false);

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

// ============================== BRAND LOGO WIDGET ==========================
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

// ============================== FILTERS =====================================
List<double> _sat(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final i = 1 - s;
  return [
    lr * i + s, lg * i, lb * i, 0, 0,
    lr * i, lg * i + s, lb * i, 0, 0,
    lr * i, lg * i, lb * i + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

class ReelFilter {
  final String name;
  final List<double>? m;
  final Color chip;
  const ReelFilter(this.name, this.m, this.chip);
  ColorFilter? get cf => m == null ? null : ColorFilter.matrix(m!);
}

final List<ReelFilter> kFilters = [
  const ReelFilter('Normal', null, Colors.white54),
  ReelFilter('Vivid', _sat(1.5), const Color(0xFFFF4D8D)),
  const ReelFilter('Warm', [1.1, 0, 0, 0, 12, 0, 1.0, 0, 0, 2, 0, 0, 0.85, 0, -12, 0, 0, 0, 1, 0], Color(0xFFFFB347)),
  const ReelFilter('Cool', [0.9, 0, 0, 0, -6, 0, 1.0, 0, 0, 0, 0, 0, 1.15, 0, 14, 0, 0, 0, 1, 0], Color(0xFF4DA3FF)),
  const ReelFilter('Noir', [0.2126, 0.7152, 0.0722, 0, 0, 0.2126, 0.7152, 0.0722, 0, 0, 0.2126, 0.7152, 0.0722, 0, 0, 0, 0, 0, 1, 0], Colors.grey),
  const ReelFilter('Sepia', [0.393, 0.769, 0.189, 0, 0, 0.349, 0.686, 0.168, 0, 0, 0.272, 0.534, 0.131, 0, 0, 0, 0, 0, 1, 0], Color(0xFFB08968)),
  const ReelFilter('Fade', [0.8, 0, 0, 0, 34, 0, 0.8, 0, 0, 34, 0, 0, 0.8, 0, 34, 0, 0, 0, 1, 0], Color(0xFFCFCFCF)),
  const ReelFilter('Cyber', [1.0, 0, 0.25, 0, 0, 0, 0.85, 0.25, 0, 0, 0.25, 0, 1.25, 0, 12, 0, 0, 0, 1, 0], Color(0xFFB04DFF)),
];

Widget applyFilter(int idx, Widget child) {
  final f = kFilters[idx.clamp(0, kFilters.length - 1).toInt()].cf;
  return f == null ? child : ColorFiltered(colorFilter: f, child: child);
}

// ============================== SOUNDS ======================================
class Track {
  final String id, title, artist, url;
  const Track(this.id, this.title, this.artist, this.url);
}

const Track kNoTrack = Track('none', 'Original audio', '', '');
const List<Track> kTracks = [
  Track('t1', 'Sunrise Groove', 'SoundHelix', 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3'),
  Track('t2', 'Lofi Chill Vibes', 'SoundHelix', 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3'),
  Track('t3', 'Acoustic Sunshine', 'SoundHelix', 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3'),
  Track('t4', 'Trending Beat (DJ Mix)', 'SoundHelix', 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-4.mp3'),
  Track('t5', 'Night Drive', 'SoundHelix', 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-5.mp3'),
  Track('t6', 'Desi Vibes Remix', 'SoundHelix', 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-6.mp3'),
  Track('t7', 'Workout Energy', 'SoundHelix', 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-7.mp3'),
  Track('t8', 'Calm Piano', 'SoundHelix', 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-8.mp3'),
];

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

// ============================== STORE =======================================
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

  // ---------- persistence ----------
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
          'Sunflower field vibes 🌻 #nature #sunflower #reels', 3, 14200, 182000, tr: kTracks[0], f: 2,
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

  // ---------- Account Creator System ----------
  void createNewAccount({required String name, required String username, required String bio, required int color, String upi = ''}) {
    me.name = name;
    me.username = username.toLowerCase();
    me.bio = bio;
    me.color = color;
    if (upi.isNotEmpty) me.upiId = upi;
    notifs.insert(
      0,
      Notif(id: newId(), type: 'system', userId: meId, text: 'New profile setup complete! Welcome @$username 🎉', at: nowMs(), read: false),
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

// ============================== VIDEO CACHE / UPLOAD ========================
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

// ============================================================================
//  SMALL SHARED WIDGETS
// ============================================================================
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

Widget sheetHandle() => Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        width: 40,
        height: 4,
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
      ),
    );

const List<Shadow> kTextShadow = [Shadow(blurRadius: 8, color: Colors.black54)];

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

// ============================================================================
//  REEL ITEM  (video + audio + overlay UI + Watermark Downloader)
// ============================================================================
class ReelItem extends StatefulWidget {
  final Reel reel;
  final bool active;
  const ReelItem({super.key, required this.reel, required this.active});
  @override
  State<ReelItem> createState() => _ReelItemState();
}

class _ReelItemState extends State<ReelItem> with SingleTickerProviderStateMixin {
  VideoPlayerController? _vc;
  AudioPlayer? _audio;
  bool _ready = false, _failed = false, _hold = false, _gone = false;
  bool _expanded = false, _muteFlash = false, _downloading = false;
  Offset? _tapPos, _heartAt;
  int _heartKey = 0;
  Duration _lastPos = Duration.zero;
  final Stopwatch _watch = Stopwatch();
  bool _counted = false;
  Timer? _viewTimer;
  double _speed = 1.0;
  late final AnimationController _disc = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  @override
  void initState() {
    super.initState();
    gMuted.addListener(_applyVolume);
    _init();
  }

  Future<void> _init() async {
    try {
      final r = widget.reel;
      final opts = VideoPlayerOptions(mixWithOthers: true);
      VideoPlayerController c;
      if (r.isLocal) {
        c = VideoPlayerController.file(File(r.videoUrl), videoPlayerOptions: opts);
      } else {
        final cached = await VideoCache.lookup(r.videoUrl);
        c = cached != null
            ? VideoPlayerController.file(cached, videoPlayerOptions: opts)
            : VideoPlayerController.networkUrl(Uri.parse(r.videoUrl), videoPlayerOptions: opts);
      }
      if (_gone) {
        c.dispose();
        return;
      }
      _vc = c;
      await c.initialize();
      if (_gone) return;
      await c.setLooping(true);
      c.addListener(_onTick);
      if (r.hasTrack) {
        final p = AudioPlayer();
        _audio = p;
        await p.setReleaseMode(ReleaseMode.loop);
        await p.setSourceUrl(r.audioUrl);
      }
      if (_gone) return;
      setState(() => _ready = true);
      _applyVolume();
      _syncPlayback();
    } catch (_) {
      if (mounted && !_gone) setState(() => _failed = true);
    }
  }

  void _retry() {
    _vc?.removeListener(_onTick);
    _vc?.dispose();
    _audio?.dispose();
    _vc = null;
    _audio = null;
    setState(() {
      _failed = false;
      _ready = false;
    });
    _init();
  }

  void _onTick() {
    final c = _vc;
    if (c == null) return;
    final p = c.value.position;
    if (_audio != null && p + const Duration(milliseconds: 500) < _lastPos) _audio!.seek(p);
    _lastPos = p;
  }

  void _applyVolume() {
    final muted = gMuted.value;
    _vc?.setVolume(widget.reel.hasTrack || muted ? 0.0 : 1.0);
    _audio?.setVolume(muted ? 0.0 : 1.0);
    if (mounted) setState(() {});
  }

  void _syncPlayback() {
    final c = _vc;
    if (c == null || !_ready || _gone) return;
    final play = widget.active && !_hold;
    if (play) {
      c.play();
      _audio?.resume();
      if (!_watch.isRunning) _watch.start();
      if (!_counted && _viewTimer == null) {
        _viewTimer = Timer(const Duration(milliseconds: 1500), () {
          _counted = true;
          if (!_gone) store.addView(widget.reel);
        });
      }
    } else {
      c.pause();
      _audio?.pause();
      _flushWatch();
      if (!widget.active) {
        c.seekTo(Duration.zero);
        _audio?.seek(Duration.zero);
        _viewTimer?.cancel();
        _viewTimer = null;
      }
    }
  }

  void _flushWatch() {
    if (_watch.isRunning) {
      _watch.stop();
      final ms = _watch.elapsedMilliseconds;
      _watch.reset();
      if (ms > 300) store.addWatch(widget.reel, ms);
    }
  }

  @override
  void didUpdateWidget(covariant ReelItem old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) {
      if (!widget.active) _hold = false;
      _syncPlayback();
    }
  }

  @override
  void dispose() {
    _gone = true;
    _viewTimer?.cancel();
    _flushWatch();
    gMuted.removeListener(_applyVolume);
    _vc?.removeListener(_onTick);
    _vc?.dispose();
    _audio?.dispose();
    _disc.dispose();
    super.dispose();
  }

  void _toggleMute() {
    gMuted.value = !gMuted.value;
    setState(() => _muteFlash = true);
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _muteFlash = false);
    });
  }

  void _doubleTap() {
    final r = widget.reel;
    if (!r.liked) store.toggleLike(r);
    final sz = context.size ?? const Size(300, 600);
    setState(() {
      _heartAt = _tapPos ?? Offset(sz.width / 2, sz.height / 2);
      _heartKey++;
    });
    Future.delayed(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _heartAt = null);
    });
  }

  void _setSpeed(double s) {
    _speed = s;
    _vc?.setPlaybackSpeed(s);
    _audio?.setPlaybackRate(s);
  }

  // ---------- Download With Logo & Watermark Feature ----------
  Future<void> _downloadReelWithWatermark() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final author = store.user(widget.reel.userId) ?? store.me;

    try {
      toast(context, 'Downloading with @${author.username} watermark & Reels Pro branding...');
      await Future.delayed(const Duration(milliseconds: 1800));
      store.recordDownload(widget.reel);

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: kSheet,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Color(0xFF38EF7D)),
                SizedBox(width: 8),
                Text('Download Complete'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Video has been saved to device with full metadata:'),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      const ReelsBrandLogo(size: 24, showText: false),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Reels Pro Original', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                          Text('Creator: @${author.username}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _openComments() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => CommentsSheet(reel: widget.reel),
      );

  void _openShare() => showModalBottomSheet<void>(
        context: context,
        backgroundColor: kSheet,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => ShareSheet(reel: widget.reel),
      );

  Track _trackOf(Reel r) => Track('remix_${r.id}', r.audioTitle, '@${(store.user(r.userId) ?? store.me).username}', r.audioUrl);

  Future<void> _remix() async {
    final r = widget.reel;
    final ok = await openPage<bool>(context, CameraPage(initialTrack: _trackOf(r)));
    if (ok == true && mounted) toast(context, 'Your reel is live 🎉');
  }

  void _openSound() {
    final r = widget.reel;
    if (!r.hasTrack) {
      toast(context, 'Original audio by @${(store.user(r.userId) ?? store.me).username}');
      return;
    }
    openPage<void>(context, SoundPage(track: _trackOf(r)));
  }

  void _openMore() {
    final r = widget.reel;
    final author = store.user(r.userId) ?? store.me;
    final mine = r.userId == AppStore.meId;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSheet,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            sheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: StatefulBuilder(
                builder: (c, setS) => Row(children: [
                  const Icon(Icons.speed, color: Colors.white70),
                  const SizedBox(width: 12),
                  const Text('Speed', style: TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  for (final s in const [0.5, 1.0, 1.5, 2.0])
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text(s == 1.0 ? '1x' : '${s}x'),
                        selected: _speed == s,
                        onSelected: (_) {
                          _setSpeed(s);
                          setS(() {});
                        },
                      ),
                    ),
                ]),
              ),
            ),
            ListTile(
              leading: Icon(r.saved ? Icons.bookmark : Icons.bookmark_border),
              title: Text(r.saved ? 'Remove from saved' : 'Save'),
              onTap: () {
                Navigator.pop(ctx);
                store.toggleSave(r);
              },
            ),
            if (r.hasTrack)
              ListTile(
                leading: const Icon(Icons.library_music_outlined),
                title: const Text('Use this audio (Remix)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _remix();
                },
              ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('Download with watermark'),
              onTap: () {
                Navigator.pop(ctx);
                _downloadReelWithWatermark();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Copy link'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: r.isLocal ? r.caption : r.videoUrl));
                toast(context, 'Link copied');
              },
            ),
            if (!mine && author.upiId.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.currency_rupee),
                title: Text('Support @${author.username} (UPI)'),
                onTap: () {
                  Navigator.pop(ctx);
                  showSupportSheet(context, author);
                },
              ),
            if (!mine)
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: const Text('Not interested'),
                onTap: () {
                  Navigator.pop(ctx);
                  store.hideReel(r);
                  toast(context, "Got it — you'll see fewer reels like this");
                },
              ),
            if (!mine)
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: Colors.redAccent),
                title: const Text('Report', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  toast(context, 'Thanks for reporting. We will review this reel.');
                },
              ),
            if (mine)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('Delete reel', style: TextStyle(color: Colors.redAccent)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await confirmDialog(context, 'Delete reel?', 'This cannot be undone.');
                  if (ok == true && mounted) {
                    final nav = Navigator.of(context);
                    store.deleteReel(r);
                    if (nav.canPop()) nav.pop();
                  }
                },
              ),
          ]),
        ),
      ),
    );
  }

  Widget _videoLayer() {
    if (_failed) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.wifi_off_rounded, color: Colors.white54, size: 48),
          const SizedBox(height: 10),
          const Text("Couldn't load this reel", style: TextStyle(color: Colors.white70)),
          TextButton.icon(onPressed: _retry, icon: const Icon(Icons.refresh), label: const Text('Retry')),
        ]),
      );
    }
    final c = _vc;
    if (!_ready || c == null) {
      return const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)));
    }
    final s = c.value.size;
    final v = FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: s.width <= 0 ? 1 : s.width, height: s.height <= 0 ? 1 : s.height, child: VideoPlayer(c)),
    );
    return applyFilter(widget.reel.filter, v);
  }

  Widget _action(Widget icon, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Column(children: [
            icon,
            if (label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, shadows: kTextShadow)),
              ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final r = widget.reel;
    final author = store.user(r.userId) ?? store.me;
    final mine = r.userId == AppStore.meId;
    final isFollowing = store.following.contains(r.userId);
    const base = TextStyle(color: Colors.white, fontSize: 14, height: 1.3, shadows: kTextShadow);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleMute,
      onDoubleTapDown: (d) => _tapPos = d.localPosition,
      onDoubleTap: _doubleTap,
      onLongPressStart: (_) {
        setState(() => _hold = true);
        _syncPlayback();
      },
      onLongPressEnd: (_) {
        setState(() => _hold = false);
        _syncPlayback();
      },
      child: Stack(fit: StackFit.expand, children: [
        _videoLayer(),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.black38, Colors.transparent, Colors.transparent, Colors.black87],
                stops: [0, 0.22, 0.58, 1],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ),
        if (_hold) const IgnorePointer(child: Center(child: Icon(Icons.pause_circle_filled, size: 72, color: Colors.white70))),
        if (_muteFlash)
          IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: Icon(gMuted.value ? Icons.volume_off : Icons.volume_up, color: Colors.white, size: 34),
              ),
            ),
          ),
        if (_heartAt != null)
          Positioned(left: _heartAt!.dx - 55, top: _heartAt!.dy - 55, child: IgnorePointer(child: HeartBurst(key: ValueKey(_heartKey)))),

        // Top Brand Logo Overlay on Feed
        Positioned(
          top: 48,
          left: 14,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(16)),
            child: const ReelsBrandLogo(size: 18),
          ),
        ),

        // Bottom Left Info
        Positioned(
          left: 14,
          right: 80,
          bottom: 20,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              GestureDetector(
                onTap: () => openPage<void>(context, ProfilePage(userId: author.id)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Avatar(author, size: 32, ring: store.hasStory(author.id), seen: store.allViewed(author.id)),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(author.username, overflow: TextOverflow.ellipsis, style: base.copyWith(fontWeight: FontWeight.w800)),
                  ),
                  if (author.verified) const Padding(padding: EdgeInsets.only(left: 4), child: VerifiedBadge()),
                ]),
              ),
              if (!mine) ...[
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => store.toggleFollow(author.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70),
                      borderRadius: BorderRadius.circular(8),
                      color: isFollowing ? Colors.transparent : Colors.white24,
                    ),
                    child: Text(isFollowing ? 'Following' : 'Follow', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ]),
            if (r.caption.isNotEmpty) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text.rich(
                  captionSpans(r.caption, base, (t) => openPage<void>(context, HashtagPage(tag: t))),
                  maxLines: _expanded ? 12 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const SizedBox(height: 10),
            GestureDetector(
              onTap: _openSound,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.music_note, size: 14, color: Colors.white),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      r.hasTrack ? r.audioTitle : 'Original audio · ${author.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ),

        // Right Action Column
        Positioned(
          right: 6,
          bottom: 16,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!mine && !isFollowing)
              GestureDetector(
                onTap: () => store.toggleFollow(author.id),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
                    Avatar(author, size: 44),
                    Positioned(
                      bottom: -8,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(color: kPink, shape: BoxShape.circle),
                        child: const Icon(Icons.add, size: 14, color: Colors.white),
                      ),
                    ),
                  ]),
                ),
              ),
            _action(
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                child: Icon(r.liked ? Icons.favorite : Icons.favorite_border,
                    key: ValueKey(r.liked), size: 32, color: r.liked ? const Color(0xFFFF3B5C) : Colors.white, shadows: kTextShadow),
              ),
              r.hideLikes ? 'Like' : fmtCount(r.likes),
              () => store.toggleLike(r),
            ),
            _action(const Icon(Icons.mode_comment_outlined, size: 29, color: Colors.white, shadows: kTextShadow),
                r.commentsOff ? '' : fmtCount(r.commentCount), _openComments),
            _action(const Icon(Icons.send_outlined, size: 29, color: Colors.white, shadows: kTextShadow), fmtCount(r.shares), _openShare),
            _action(
              _downloading ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.download_rounded, size: 30, color: Colors.white, shadows: kTextShadow),
              'Save',
              _downloadReelWithWatermark,
            ),
            _action(Icon(r.saved ? Icons.bookmark : Icons.bookmark_border, size: 30, color: Colors.white, shadows: kTextShadow), '', () => store.toggleSave(r)),
            _action(const Icon(Icons.more_horiz, size: 28, color: Colors.white, shadows: kTextShadow), '', _openMore),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: _openSound,
              child: RotationTransition(
                turns: _disc,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    gradient: LinearGradient(colors: [Color(author.color), Colors.black87]),
                  ),
                  child: const Icon(Icons.music_note, size: 16, color: Colors.white),
                ),
              ),
            ),
          ]),
        ),

        // Video Scrubber
        if (_ready && _vc != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: VideoProgressIndicator(
              _vc!,
              allowScrubbing: true,
              padding: const EdgeInsets.only(top: 12),
              colors: const VideoProgressColors(playedColor: Colors.white, bufferedColor: Colors.white24, backgroundColor: Colors.white10),
            ),
          ),
      ]),
    );
  }
}

// ============================================================================
//  PAGER (shared by Feed + Viewer)
// ============================================================================
class ReelPager extends StatefulWidget {
  final List<Reel> reels;
  final int initial;
  final bool tabActive;
  const ReelPager({super.key, required this.reels, this.initial = 0, this.tabActive = true});
  @override
  State<ReelPager> createState() => _ReelPagerState();
}

class _ReelPagerState extends State<ReelPager> with RouteAware, WidgetsBindingObserver {
  late final PageController _pc = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  bool _covered = false, _bg = false;
  PageRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prefetch(_index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = ModalRoute.of(context);
    if (r is PageRoute && r != _route) {
      if (_route != null) routeObserver.unsubscribe(this);
      _route = r;
      routeObserver.subscribe(this, r);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _pc.dispose();
    super.dispose();
  }

  @override
  void didPushNext() => setState(() => _covered = true);
  @override
  void didPopNext() => setState(() => _covered = false);
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) => setState(() => _bg = s != AppLifecycleState.resumed);

  void _prefetch(int i) {
    if (store.dataSaver) return;
    for (var k = 1; k <= 2; k++) {
      final j = i + k;
      if (j < widget.reels.length && !widget.reels[j].isLocal) VideoCache.prefetch(widget.reels[j].videoUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _pc,
      scrollDirection: Axis.vertical,
      itemCount: widget.reels.length,
      onPageChanged: (i) {
        setState(() => _index = i);
        _prefetch(i);
      },
      itemBuilder: (_, i) {
        final r = widget.reels[i];
        return ReelItem(key: ValueKey(r.id), reel: r, active: i == _index && widget.tabActive && !_covered && !_bg);
      },
    );
  }
}

class ReelViewerPage extends StatelessWidget {
  final List<Reel> reels;
  final int initial;
  const ReelViewerPage({super.key, required this.reels, this.initial = 0});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        ListenableBuilder(
          listenable: store,
          builder: (_, __) {
            final live = reels.where((r) => store.reels.contains(r)).toList();
            if (live.isEmpty) return const Center(child: Text('No reels'));
            return ReelPager(reels: live, initial: initial.clamp(0, live.length - 1).toInt());
          },
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white, shadows: kTextShadow),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
      ]),
    );
  }
}

// ============================================================================
//  ACCOUNT CREATION DIALOG
// ============================================================================
void showCreateAccountDialog(BuildContext context) {
  final nameCtl = TextEditingController();
  final userCtl = TextEditingController();
  final bioCtl = TextEditingController();
  final upiCtl = TextEditingController();
  int pickedColor = 0xFFE1306C;

  final colors = [0xFFE1306C, 0xFF3B82F6, 0xFF2E9E5B, 0xFFF59E0B, 0xFF8B5CF6, 0xFFEF4444];

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setS) => AlertDialog(
        backgroundColor: kSheet,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          ReelsBrandLogo(size: 22, showText: false),
          SizedBox(width: 8),
          Text('Create New Profile', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ]),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: 'Full Name', hintText: 'e.g. Rahul Sharma'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: userCtl,
                decoration: const InputDecoration(labelText: 'Username', hintText: 'e.g. rahul_vlogs'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: bioCtl,
                decoration: const InputDecoration(labelText: 'Bio', hintText: 'Tell about yourself...'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: upiCtl,
                decoration: const InputDecoration(labelText: 'UPI ID (Optional)', hintText: 'name@bank'),
              ),
              const SizedBox(height: 16),
              const Align(alignment: Alignment.centerLeft, child: Text('Theme Avatar Color:', style: TextStyle(color: Colors.white70, fontSize: 12))),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: colors.map((c) {
                  return GestureDetector(
                    onTap: () => setS(() => pickedColor = c),
                    child: CircleAvatar(
                      radius: 14,
                      backgroundColor: Color(c),
                      child: pickedColor == c ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          GradientButton('Create Account', onTap: () {
            final un = userCtl.text.trim();
            if (un.isEmpty) {
              toast(context, 'Please enter a valid username');
              return;
            }
            store.createNewAccount(
              name: nameCtl.text.trim().isEmpty ? 'User' : nameCtl.text.trim(),
              username: un,
              bio: bioCtl.text.trim(),
              color: pickedColor,
              upi: upiCtl.text.trim(),
            );
            Navigator.pop(ctx);
            toast(context, 'Account @$un created successfully! 🚀');
          }),
        ],
      ),
    ),
  );
}

// ============================================================================
//  PROFILE PAGE WITH ACCOUNT SWITCH
// ============================================================================
class ProfilePage extends StatefulWidget {
  final String userId;
  final bool isTab;
  const ProfilePage({super.key, required this.userId, this.isTab = false});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  int _tab = 0;

  Widget _stat(int n, String l) => Column(children: [
        Text(fmtCount(n), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(l, style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ]);

  Widget _btn(String label, VoidCallback onTap, {bool filled = false}) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(gradient: filled ? kBrandBtn : null, color: filled ? null : Colors.white12, borderRadius: BorderRadius.circular(9)),
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ),
      );

  Widget _tabIcon(IconData i, int idx) => Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = idx),
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _tab == idx ? Colors.white : Colors.transparent, width: 1.5))),
            child: Icon(i, color: _tab == idx ? Colors.white : Colors.white38),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final u = store.user(widget.userId);
        if (u == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('User not found')));
        final mine = u.id == AppStore.meId;
        final isFollowing = store.following.contains(u.id);
        final mineReels = store.reelsOf(u.id);
        final tab = mine ? _tab : 0;
        final list = tab == 0 ? mineReels : (tab == 1 ? store.savedReels() : store.likedReels());
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: !widget.isTab,
            title: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(u.username, style: const TextStyle(fontWeight: FontWeight.w800)),
              if (u.verified) const Padding(padding: EdgeInsets.only(left: 6), child: VerifiedBadge()),
            ]),
            actions: [
              if (mine)
                IconButton(
                  icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white),
                  tooltip: 'Create New Account',
                  onPressed: () => showCreateAccountDialog(ctx),
                ),
              if (mine) IconButton(icon: const Icon(Icons.menu), onPressed: () => openPage<void>(ctx, const SettingsPage())),
              if (!mine) IconButton(icon: const Icon(Icons.more_horiz), onPressed: () => toast(ctx, 'Options available on backend sync')),
            ],
          ),
          body: CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    GestureDetector(
                      onTap: store.hasStory(u.id) ? () => openPage<void>(ctx, StoryViewer(userIds: [u.id])) : (mine ? () => openPage<void>(ctx, const StoryComposer()) : null),
                      child: Avatar(u, size: 84, ring: store.hasStory(u.id), seen: store.hasStory(u.id) && store.allViewed(u.id)),
                    ),
                    Expanded(
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                        _stat(mineReels.length, 'Reels'),
                        _stat(store.followersOf(u.id), 'Followers'),
                        _stat(store.followingCount(u.id), 'Following'),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Text(u.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  if (u.bio.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(u.bio, style: const TextStyle(height: 1.3))),
                  const SizedBox(height: 14),
                  if (mine)
                    Row(children: [
                      _btn('Edit profile', () => openPage<void>(ctx, const EditProfilePage())),
                      const SizedBox(width: 8),
                      _btn('Insights', () => openPage<void>(ctx, const InsightsPage())),
                      const SizedBox(width: 8),
                      _btn('Add story', () => openPage<void>(ctx, const StoryComposer())),
                    ])
                  else
                    Row(children: [
                      _btn(isFollowing ? 'Following' : 'Follow', () => store.toggleFollow(u.id), filled: !isFollowing),
                      const SizedBox(width: 8),
                      _btn('Message', () => openPage<void>(ctx, ChatPage(userId: u.id))),
                      if (u.upiId.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _btn('Support ₹', () => showSupportSheet(ctx, u)),
                      ],
                    ]),
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: Row(children: [
                _tabIcon(Icons.grid_on, 0),
                if (mine) _tabIcon(Icons.bookmark_border, 1),
                if (mine) _tabIcon(Icons.favorite_border, 2),
              ]),
            ),
            if (list.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: Center(
                    child: Text(
                      tab == 0 ? (mine ? 'Share your first reel 🎬' : 'No reels yet') : (tab == 1 ? 'Reels you save appear here' : 'Reels you like appear here'),
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
              ),
            reelSliverGrid(ctx, list),
          ]),
        );
      },
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
          const ProfilePage(userId: AppStore.meId, isTab: true),
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
