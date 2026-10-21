// ============================================================================
//  REELS PRO  —  Instagram-style short-video app (Flutter)
//  Features: Reels feed (For You / Following), likes, threaded comments, saves,
//  share-to-DM, follow, profiles, explore + search, hashtags, stories,
//  messages, camera with live filters + sound, gallery upload, creator
//  insights, UPI support, muted words, data saver, local-first storage and
//  optional Cloudflare R2 upload through a Worker (see worker.js).
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
/// Cloudflare Worker URL (worker.js deploy karne ke baad bharo).
/// Khaali = local mode (reels phone me save hongi, cloud par nahi jaayengi).
const String kUploadBase = ''; // e.g. 'https://reels-upload.yourname.workers.dev'
const String kUploadToken = ''; // Worker ke APP_TOKEN secret jaisa hi
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
  int likes, shares, views, watchMs, saves;
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
        'wm': watchMs, 'sv': saves, 'liked': liked, 'saved': saved, 'hid': hidden,
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
    final raw = _prefs!.getString('reels_pro_store_v1');
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
      _prefs?.setString('reels_pro_store_v1', jsonEncode(_toJson()));
    });
  }

  /// UI refresh + save
  void changed() {
    notifyListeners();
    _persist();
  }

  /// sirf save (no UI rebuild) — views / watch time ke liye
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

  // ---------- demo seed ----------
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

  // ---------- feed queries ----------
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

  // ---------- stories ----------
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

  // ---------- reel actions ----------
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
    notifs.insert(0, Notif(id: newId(), type: 'system', userId: meId, text: 'Your reel is live 🎉', at: nowMs(), reelId: r.id, read: true));
    changed();
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

  // ---------- comments ----------
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

  // ---------- messages ----------
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

  // ---------- settings / profile ----------
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
  /// Worker ko PUT karta hai; public URL return karta hai.
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
//  REEL ITEM  (video + audio + overlay UI)
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
  bool _expanded = false, _muteFlash = false;
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

  // ---------- gestures / actions ----------
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

  // ---------- build ----------
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
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
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

        // ----- bottom-left info -----
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

        // ----- right action column -----
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

        // ----- progress / scrubber -----
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
//  COMMENTS SHEET
// ============================================================================
class CommentsSheet extends StatefulWidget {
  final Reel reel;
  const CommentsSheet({super.key, required this.reel});
  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final TextEditingController _ctl = TextEditingController();
  final FocusNode _focus = FocusNode();
  Comment? _replyTo;
  final Set<String> _open = {};

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final t = _ctl.text.trim();
    if (t.isEmpty) return;
    store.addComment(widget.reel, t, replyTo: _replyTo);
    if (_replyTo != null) _open.add(_replyTo!.id);
    _ctl.clear();
    setState(() => _replyTo = null);
    FocusScope.of(context).unfocus();
  }

  Widget _tile(Comment c, {bool reply = false}) {
    final u = store.user(c.userId) ?? store.me;
    final canDelete = c.userId == AppStore.meId || widget.reel.userId == AppStore.meId;
    return GestureDetector(
      onLongPress: canDelete
          ? () async {
              final ok = await confirmDialog(context, 'Delete comment?', 'This cannot be undone.');
              if (ok == true) store.deleteComment(widget.reel, c);
            }
          : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(reply ? 56 : 16, 8, 8, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Avatar(u, size: reply ? 26 : 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: u.username, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                TextSpan(text: '  ${timeAgo(c.at)}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ])),
              const SizedBox(height: 2),
              Text(c.text, style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              if (!reply)
                GestureDetector(
                  onTap: () {
                    setState(() => _replyTo = c);
                    _focus.requestFocus();
                  },
                  child: const Text('Reply', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
          GestureDetector(
            onTap: () => store.toggleCommentLike(c),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(children: [
                Icon(c.liked ? Icons.favorite : Icons.favorite_border, size: 18, color: c.liked ? const Color(0xFFFF3B5C) : Colors.white54),
                if (c.likes > 0) Text(fmtCount(c.likes), style: const TextStyle(fontSize: 11, color: Colors.white54)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reel;
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scroll) => Container(
        decoration: const BoxDecoration(color: kSheet, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: ListenableBuilder(
          listenable: store,
          builder: (_, __) => Column(children: [
            sheetHandle(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('Comments${r.commentsOff ? '' : ' · ${r.commentCount}'}', style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: r.commentsOff
                  ? const Center(child: Text('Comments are turned off for this reel.', style: TextStyle(color: Colors.white54)))
                  : r.comments.isEmpty
                      ? const Center(child: Text('No comments yet.\nStart the conversation 💬', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)))
                      : ListView(controller: scroll, children: [
                          for (final c in r.comments) ...[
                            _tile(c),
                            if (c.replies.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 60),
                                child: GestureDetector(
                                  onTap: () => setState(() => _open.contains(c.id) ? _open.remove(c.id) : _open.add(c.id)),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Text(
                                      _open.contains(c.id) ? '—— Hide replies' : '—— View ${c.replies.length} ${c.replies.length == 1 ? 'reply' : 'replies'}',
                                      style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ),
                            if (_open.contains(c.id)) for (final rep in c.replies) _tile(rep, reply: true),
                          ],
                        ]),
            ),
            if (!r.commentsOff) ...[
              const Divider(height: 1, color: Colors.white12),
              if (_replyTo != null)
                Container(
                  color: Colors.white10,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(children: [
                    Expanded(child: Text('Replying to @${(store.user(_replyTo!.userId) ?? store.me).username}', style: const TextStyle(color: Colors.white70, fontSize: 12))),
                    GestureDetector(onTap: () => setState(() => _replyTo = null), child: const Icon(Icons.close, size: 16, color: Colors.white54)),
                  ]),
                ),
              SizedBox(
                height: 42,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final e in const ['❤️', '🙌', '🔥', '👏', '😢', '😍', '😮', '😂'])
                      GestureDetector(
                        onTap: () => _ctl.text = '${_ctl.text}$e',
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 9), child: Center(child: Text(e, style: const TextStyle(fontSize: 22)))),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 8, 8 + MediaQuery.of(context).viewInsets.bottom),
                child: Row(children: [
                  Avatar(store.me, size: 34),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _ctl,
                      focusNode: _focus,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: _replyTo != null ? 'Write a reply…' : 'Add a comment…',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Colors.white10,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  TextButton(onPressed: _send, child: const Text('Post', style: TextStyle(color: Color(0xFF3897F0), fontWeight: FontWeight.w800))),
                ]),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

// ============================================================================
//  SHARE SHEET
// ============================================================================
class ShareSheet extends StatefulWidget {
  final Reel reel;
  const ShareSheet({super.key, required this.reel});
  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  final Set<String> _sent = {};

  String get _text {
    final r = widget.reel;
    final who = (store.user(r.userId) ?? store.me).username;
    return r.isLocal ? 'Check out my reel on Reels Pro 🎬\n${r.caption}' : '${r.caption}\nby @$who\n${r.videoUrl}';
  }

  Widget _circle(IconData i, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Column(children: [
          Container(width: 54, height: 54, decoration: const BoxDecoration(color: Colors.white12, shape: BoxShape.circle), child: Icon(i)),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final contacts = store.users.values.where((u) => u.id != AppStore.meId).toList();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          sheetHandle(),
          const Padding(padding: EdgeInsets.only(bottom: 14, top: 4), child: Text('Share', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          Wrap(spacing: 18, runSpacing: 14, children: [
            for (final u in contacts)
              GestureDetector(
                onTap: () {
                  if (_sent.add(u.id)) {
                    store.sendMessage(u.id, 'Shared a reel', reelId: widget.reel.id);
                    store.countShare(widget.reel);
                    setState(() {});
                  }
                },
                child: SizedBox(
                  width: 64,
                  child: Column(children: [
                    Stack(alignment: Alignment.bottomRight, children: [
                      Avatar(u, size: 54),
                      if (_sent.contains(u.id)) const CircleAvatar(radius: 9, backgroundColor: Color(0xFF3897F0), child: Icon(Icons.check, size: 12, color: Colors.white)),
                    ]),
                    const SizedBox(height: 6),
                    Text(_sent.contains(u.id) ? 'Sent' : u.name.split(' ').first, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                  ]),
                ),
              ),
          ]),
          const Divider(height: 28, color: Colors.white12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _circle(Icons.link, 'Copy link', () {
              Clipboard.setData(ClipboardData(text: _text));
              store.countShare(widget.reel);
              Navigator.pop(context);
              toast(context, 'Copied');
            }),
            _circle(Icons.ios_share, 'Share to…', () {
              store.countShare(widget.reel);
              Share.share(_text);
            }),
            if (widget.reel.hasTrack)
              _circle(Icons.library_music_outlined, 'Remix', () async {
                final nav = Navigator.of(context);
                final r = widget.reel;
                nav.pop();
                await nav.push<bool>(MaterialPageRoute<bool>(
                  builder: (_) => CameraPage(initialTrack: Track('remix_${r.id}', r.audioTitle, 'remix', r.audioUrl)),
                ));
              }),
          ]),
        ]),
      ),
    );
  }
}

// ============================================================================
//  SOUND PICKER
// ============================================================================
Future<Track?> showTrackPicker(BuildContext context, {String? currentId}) => showModalBottomSheet<Track>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSheet,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => TrackPicker(currentId: currentId),
    );

class TrackPicker extends StatefulWidget {
  final String? currentId;
  const TrackPicker({super.key, this.currentId});
  @override
  State<TrackPicker> createState() => _TrackPickerState();
}

class _TrackPickerState extends State<TrackPicker> {
  final AudioPlayer _p = AudioPlayer();
  String? _playing;

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  Future<void> _preview(Track t) async {
    try {
      if (_playing == t.id) {
        await _p.stop();
        setState(() => _playing = null);
      } else {
        await _p.stop();
        await _p.play(UrlSource(t.url));
        setState(() => _playing = t.id);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.72),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          sheetHandle(),
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Add sound', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          const Divider(height: 1, color: Colors.white12),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              ListTile(
                leading: const CircleAvatar(backgroundColor: Colors.white12, child: Icon(Icons.mic, color: Colors.white)),
                title: const Text('Original audio'),
                subtitle: const Text('Use your own voice / camera mic'),
                trailing: widget.currentId == null || widget.currentId == 'none' ? const Icon(Icons.check_circle, color: Color(0xFF3897F0)) : null,
                onTap: () => Navigator.pop(context, kNoTrack),
              ),
              for (final t in kTracks)
                ListTile(
                  leading: IconButton(
                    icon: Icon(_playing == t.id ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 36, color: Colors.white70),
                    onPressed: () => _preview(t),
                  ),
                  title: Text(t.title),
                  subtitle: Text(t.artist, style: const TextStyle(color: Colors.white54)),
                  trailing: widget.currentId == t.id ? const Icon(Icons.check_circle, color: Color(0xFF3897F0)) : const Text('Use', style: TextStyle(color: Color(0xFF3897F0), fontWeight: FontWeight.w700)),
                  onTap: () => Navigator.pop(context, t),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ============================================================================
//  FEED PAGE  (Following | For You)
// ============================================================================
class FeedPage extends StatefulWidget {
  final bool active;
  final VoidCallback onOpenCamera;
  const FeedPage({super.key, required this.active, required this.onOpenCamera});
  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  int _seg = 1;

  Widget _segBtn(String t, int i) => GestureDetector(
        onTap: () => setState(() => _seg = i),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(t,
              style: TextStyle(
                color: _seg == i ? Colors.white : Colors.white60,
                fontWeight: _seg == i ? FontWeight.w800 : FontWeight.w600,
                fontSize: 17,
                shadows: kTextShadow,
              )),
        ),
      );

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.people_outline, size: 64, color: Colors.white38),
            const SizedBox(height: 12),
            Text(_seg == 0 ? 'Follow creators to see their reels here' : 'No reels to show', style: const TextStyle(color: Colors.white70, fontSize: 16), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (_seg == 0) GradientButton('Discover reels', onTap: () => setState(() => _seg = 1)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final list = _seg == 0 ? store.followingFeed() : store.forYouFeed();
        return Stack(children: [
          Positioned.fill(
            child: list.isEmpty ? _empty() : ReelPager(key: ValueKey('$_seg-${store.feedEpoch}'), reels: list, tabActive: widget.active),
          ),
          SafeArea(
            child: Row(children: [
              ValueListenableBuilder<bool>(
                valueListenable: gMuted,
                builder: (_, m, __) => IconButton(
                  icon: Icon(m ? Icons.volume_off : Icons.volume_up, color: Colors.white, shadows: kTextShadow),
                  onPressed: () => gMuted.value = !gMuted.value,
                ),
              ),
              const Spacer(),
              _segBtn('Following', 0),
              _segBtn('For You', 1),
              const Spacer(),
              IconButton(icon: const Icon(Icons.photo_camera_outlined, color: Colors.white, shadows: kTextShadow), onPressed: widget.onOpenCamera),
            ]),
          ),
        ]);
      },
    );
  }
}

// ============================================================================
//  GRID TILE + HELPERS
// ============================================================================
class ReelTile extends StatelessWidget {
  final Reel reel;
  final VoidCallback onTap;
  const ReelTile({super.key, required this.reel, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final u = store.user(reel.userId) ?? store.me;
    final c = Color(u.color);
    final text = reel.caption.replaceAll(RegExp(r'#[^\s#]+'), '').trim();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(gradient: LinearGradient(colors: [c, Color.lerp(c, Colors.black, 0.7)!], begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: Stack(children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(text.isEmpty ? '🎬' : text, maxLines: 4, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, shadows: kTextShadow)),
            ),
          ),
          Positioned(
            left: 6,
            bottom: 6,
            child: Row(children: [
              const Icon(Icons.play_arrow_outlined, color: Colors.white, size: 16, shadows: kTextShadow),
              Text(fmtCount(reel.views), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, shadows: kTextShadow)),
            ]),
          ),
          if (reel.hasTrack) const Positioned(top: 6, right: 6, child: Icon(Icons.music_note, color: Colors.white, size: 14, shadows: kTextShadow)),
        ]),
      ),
    );
  }
}

Widget reelSliverGrid(BuildContext context, List<Reel> list) => SliverGrid(
      delegate: SliverChildBuilderDelegate(
        (c, i) => ReelTile(reel: list[i], onTap: () => openPage<void>(context, ReelViewerPage(reels: list, initial: i))),
        childCount: list.length,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2, childAspectRatio: 0.62),
    );

// ============================================================================
//  STORIES
// ============================================================================
class StoriesTray extends StatelessWidget {
  const StoriesTray({super.key});

  Widget _item(BuildContext context, AppUser u, VoidCallback onTap, {bool me = false, Widget? badge}) {
    final has = store.hasStory(u.id);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 78,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            Avatar(u, size: 62, ring: has, seen: has && store.allViewed(u.id)),
            if (badge != null) Positioned(right: -2, bottom: -2, child: badge),
          ]),
          const SizedBox(height: 6),
          Text(me ? 'Your story' : u.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final ids = store.storyUsers();
        return SizedBox(
          height: 100,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
            _item(
              ctx,
              store.me,
              () => store.hasStory(AppStore.meId) ? openPage<void>(ctx, const StoryViewer(userIds: [AppStore.meId])) : openPage<void>(ctx, const StoryComposer()),
              me: true,
              badge: GestureDetector(
                onTap: () => openPage<void>(ctx, const StoryComposer()),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(color: const Color(0xFF3897F0), shape: BoxShape.circle, border: Border.all(color: Colors.black, width: 2)),
                  child: const Icon(Icons.add, size: 14, color: Colors.white),
                ),
              ),
            ),
            for (var i = 0; i < ids.length; i++)
              _item(ctx, store.users[ids[i]]!, () => openPage<void>(ctx, StoryViewer(userIds: ids, start: i))),
          ]),
        );
      },
    );
  }
}

class StoryViewer extends StatefulWidget {
  final List<String> userIds;
  final int start;
  const StoryViewer({super.key, required this.userIds, this.start = 0});
  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> with SingleTickerProviderStateMixin {
  late int _u = widget.start;
  int _s = 0;
  bool _liked = false;
  late final AnimationController _ac = AnimationController(vsync: this, duration: const Duration(seconds: 5))
    ..addStatusListener((st) {
      if (st == AnimationStatus.completed) _next();
    });
  final TextEditingController _reply = TextEditingController();
  final FocusNode _focus = FocusNode();

  String get _uid => widget.userIds[_u];
  List<Story> get _list => store.storiesOf(_uid);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _ac.stop();
      } else if (mounted) {
        _ac.forward();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final i = _list.indexWhere((s) => !s.viewed);
      _s = i < 0 ? 0 : i;
      _begin();
    });
  }

  @override
  void dispose() {
    _ac.dispose();
    _reply.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _begin() {
    final l = _list;
    if (l.isEmpty) {
      Navigator.pop(context);
      return;
    }
    _s = _s.clamp(0, l.length - 1).toInt();
    store.markViewed(l[_s]);
    setState(() => _liked = false);
    _ac.forward(from: 0);
  }

  void _next() {
    if (!mounted) return;
    if (_s < _list.length - 1) {
      _s++;
      _begin();
    } else if (_u < widget.userIds.length - 1) {
      _u++;
      _s = 0;
      _begin();
    } else {
      Navigator.pop(context);
    }
  }

  void _prev() {
    if (_s > 0) {
      _s--;
      _begin();
    } else if (_u > 0) {
      _u--;
      _s = 0;
      _begin();
    } else {
      _ac.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (list.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    final story = list[_s.clamp(0, list.length - 1).toInt()];
    final u = store.user(_uid) ?? store.me;
    final mine = _uid == AppStore.meId;
    final bg = kStoryBg[story.grad % kStoryBg.length];
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(fit: StackFit.expand, children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => d.localPosition.dx < MediaQuery.of(context).size.width / 3 ? _prev() : _next(),
            onLongPressStart: (_) => _ac.stop(),
            onLongPressEnd: (_) => _ac.forward(),
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 300) Navigator.pop(context);
            },
            child: Container(
              decoration: BoxDecoration(gradient: LinearGradient(colors: bg, begin: Alignment.topLeft, end: Alignment.bottomRight)),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(story.text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white, height: 1.25, shadows: kTextShadow)),
            ),
          ),
        ),
        SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: AnimatedBuilder(
                animation: _ac,
                builder: (_, __) => Row(children: [
                  for (var i = 0; i < list.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: i < _s ? 1 : (i == _s ? _ac.value : 0),
                            minHeight: 3,
                            backgroundColor: Colors.white30,
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                Avatar(u, size: 34),
                const SizedBox(width: 8),
                Text(u.username, style: const TextStyle(fontWeight: FontWeight.w800, shadows: kTextShadow)),
                const SizedBox(width: 8),
                Text(timeAgo(story.at), style: const TextStyle(color: Colors.white70, shadows: kTextShadow)),
                const Spacer(),
                if (mine)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white),
                    onPressed: () async {
                      _ac.stop();
                      final ok = await confirmDialog(context, 'Delete story?', 'This story will be removed.');
                      if (ok == true) {
                        store.deleteStory(story);
                        if (!mounted) return;
                        if (_list.isEmpty) {
                          Navigator.pop(context);
                        } else {
                          _begin();
                        }
                      } else {
                        _ac.forward();
                      }
                    },
                  ),
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ]),
            ),
          ]),
        ),
        if (!mine)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12 + MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom,
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _reply,
                  focusNode: _focus,
                  style: const TextStyle(color: Colors.white),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (t) {
                    if (t.trim().isEmpty) return;
                    store.sendMessage(_uid, 'Replied to your story: ${t.trim()}');
                    _reply.clear();
                    _focus.unfocus();
                    toast(context, 'Reply sent');
                  },
                  decoration: InputDecoration(
                    hintText: 'Send message',
                    hintStyle: const TextStyle(color: Colors.white70),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: const BorderSide(color: Colors.white70)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: const BorderSide(color: Colors.white)),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(_liked ? Icons.favorite : Icons.favorite_border, color: _liked ? const Color(0xFFFF3B5C) : Colors.white, size: 28),
                onPressed: () {
                  setState(() => _liked = !_liked);
                  if (store.haptics) HapticFeedback.lightImpact();
                },
              ),
            ]),
          ),
      ]),
    );
  }
}

class StoryComposer extends StatefulWidget {
  const StoryComposer({super.key});
  @override
  State<StoryComposer> createState() => _StoryComposerState();
}

class _StoryComposerState extends State<StoryComposer> {
  final TextEditingController _ctl = TextEditingController();
  int _g = 0;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        decoration: BoxDecoration(gradient: LinearGradient(colors: kStoryBg[_g], begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: SafeArea(
          child: Column(children: [
            Row(children: [
              IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.palette_outlined, color: Colors.white), onPressed: () => setState(() => _g = (_g + 1) % kStoryBg.length)),
            ]),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: TextField(
                    controller: _ctl,
                    autofocus: true,
                    maxLines: null,
                    maxLength: 160,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white),
                    cursorColor: Colors.white,
                    decoration: const InputDecoration(hintText: 'Type something…', hintStyle: TextStyle(color: Colors.white54), border: InputBorder.none, counterStyle: TextStyle(color: Colors.white54)),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: GradientButton('Share to your story', icon: Icons.auto_stories, onTap: () {
                if (_ctl.text.trim().isEmpty) {
                  toast(context, 'Write something first');
                  return;
                }
                store.addStory(_ctl.text.trim(), _g);
                Navigator.pop(context);
              }),
            ),
          ]),
        ),
      ),
    );
  }
}

// ============================================================================
//  EXPLORE  (search, trending, stories, grid)
// ============================================================================
class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});
  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  final TextEditingController _q = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final q = _query.trim().toLowerCase().replaceAll('#', '');
        final feed = store.forYouFeed();
        final slivers = <Widget>[
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: TextField(
                  controller: _q,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search accounts, #hashtags, sounds',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.search, color: Colors.white54),
                    suffixIcon: _query.isEmpty ? null : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() {
                          _q.clear();
                          _query = '';
                        })),
                    filled: true,
                    fillColor: Colors.white10,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
              ),
            ),
          ),
        ];

        if (q.isEmpty) {
          slivers.add(const SliverToBoxAdapter(child: StoriesTray()));
          final tags = store.trendingTags();
          if (tags.isNotEmpty) {
            slivers.add(SliverToBoxAdapter(
              child: SizedBox(
                height: 44,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10), children: [
                  for (final t in tags)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      child: ActionChip(
                        label: Text('#${t.key}'),
                        backgroundColor: Colors.white10,
                        side: BorderSide.none,
                        onPressed: () => openPage<void>(ctx, HashtagPage(tag: t.key)),
                      ),
                    ),
                ]),
              ),
            ));
          }
          slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 6)));
          slivers.add(reelSliverGrid(ctx, feed));
        } else {
          final users = store.users.values.where((u) => u.id != AppStore.meId && (u.username.toLowerCase().contains(q) || u.name.toLowerCase().contains(q))).toList();
          final tags = store.trendingTags(100).where((e) => e.key.contains(q)).toList();
          final sounds = kTracks.where((t) => t.title.toLowerCase().contains(q)).toList();
          final reels = feed.where((r) => r.caption.toLowerCase().contains(q)).toList();
          slivers.add(SliverToBoxAdapter(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (users.isNotEmpty) _sectionTitle('Accounts'),
              for (final u in users)
                ListTile(
                  leading: Avatar(u, size: 44, ring: store.hasStory(u.id), seen: store.allViewed(u.id)),
                  title: Row(children: [Flexible(child: Text(u.username, overflow: TextOverflow.ellipsis)), if (u.verified) const Padding(padding: EdgeInsets.only(left: 4), child: VerifiedBadge())]),
                  subtitle: Text('${u.name} · ${fmtCount(store.followersOf(u.id))} followers', style: const TextStyle(color: Colors.white54)),
                  onTap: () => openPage<void>(ctx, ProfilePage(userId: u.id)),
                ),
              if (tags.isNotEmpty) _sectionTitle('Hashtags'),
              for (final t in tags.take(6))
                ListTile(
                  leading: const CircleAvatar(backgroundColor: Colors.white12, child: Icon(Icons.tag, color: Colors.white)),
                  title: Text('#${t.key}'),
                  onTap: () => openPage<void>(ctx, HashtagPage(tag: t.key)),
                ),
              if (sounds.isNotEmpty) _sectionTitle('Sounds'),
              for (final t in sounds)
                ListTile(
                  leading: const CircleAvatar(backgroundColor: Colors.white12, child: Icon(Icons.music_note, color: Colors.white)),
                  title: Text(t.title),
                  subtitle: Text('${store.bySound(t.title).length} reels', style: const TextStyle(color: Colors.white54)),
                  onTap: () => openPage<void>(ctx, SoundPage(track: t)),
                ),
              if (reels.isNotEmpty) _sectionTitle('Reels'),
            ]),
          ));
          slivers.add(reelSliverGrid(ctx, reels));
          if (users.isEmpty && tags.isEmpty && sounds.isEmpty && reels.isEmpty) {
            slivers.add(const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No results', style: TextStyle(color: Colors.white54))))));
          }
        }
        return CustomScrollView(slivers: slivers);
      },
    );
  }
}

class HashtagPage extends StatelessWidget {
  final String tag;
  const HashtagPage({super.key, required this.tag});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final list = store.byTag(tag);
        return Scaffold(
          appBar: AppBar(title: Text('#$tag')),
          body: CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: const BoxDecoration(shape: BoxShape.circle, gradient: kBrandBtn),
                    child: const Icon(Icons.tag, size: 32, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('#$tag', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      Text('${list.length} ${list.length == 1 ? 'reel' : 'reels'} · ${fmtCount(list.fold<int>(0, (s, r) => s + r.views))} views', style: const TextStyle(color: Colors.white54)),
                    ]),
                  ),
                ]),
              ),
            ),
            if (list.isEmpty) const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No reels with this hashtag yet', style: TextStyle(color: Colors.white54))))),
            reelSliverGrid(ctx, list),
          ]),
        );
      },
    );
  }
}

class SoundPage extends StatelessWidget {
  final Track track;
  const SoundPage({super.key, required this.track});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final list = store.bySound(track.title);
        return Scaffold(
          appBar: AppBar(title: const Text('Sound')),
          body: CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Row(children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), gradient: kBrandBtn),
                      child: const Icon(Icons.music_note, size: 36, color: Colors.white),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(track.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        Text(track.artist, style: const TextStyle(color: Colors.white54)),
                        Text('${list.length} reels', style: const TextStyle(color: Colors.white54)),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  SizedBox(width: double.infinity, child: Center(child: GradientButton('Use this sound', icon: Icons.photo_camera_outlined, onTap: () => openPage<bool>(ctx, CameraPage(initialTrack: track))))),
                ]),
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
//  PROFILE
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
              if (mine) IconButton(icon: const Icon(Icons.menu), onPressed: () => openPage<void>(ctx, const SettingsPage())),
              if (!mine) IconButton(icon: const Icon(Icons.more_horiz), onPressed: () => toast(ctx, 'Block / report options need an account backend')),
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

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});
  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _name = TextEditingController(text: store.me.name);
  late final TextEditingController _user = TextEditingController(text: store.me.username);
  late final TextEditingController _bio = TextEditingController(text: store.me.bio);
  late final TextEditingController _upi = TextEditingController(text: store.me.upiId);

  @override
  void dispose() {
    _name.dispose();
    _user.dispose();
    _bio.dispose();
    _upi.dispose();
    super.dispose();
  }

  Widget _field(String label, TextEditingController c, {int lines = 1, String? hint, int? max}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: c,
          maxLines: lines,
          maxLength: max,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            filled: true,
            fillColor: Colors.white10,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
      );

  void _save() {
    final un = _user.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9._]{3,30}$').hasMatch(un)) {
      toast(context, 'Username: 3-30 letters, numbers, . or _');
      return;
    }
    final upi = _upi.text.trim();
    if (upi.isNotEmpty && !upi.contains('@')) {
      toast(context, 'UPI ID looks like name@bank');
      return;
    }
    store.updateMe(name: _name.text.trim().isEmpty ? 'You' : _name.text.trim(), username: un, bio: _bio.text.trim(), upi: upi);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile'), actions: [TextButton(onPressed: _save, child: const Text('Done', style: TextStyle(color: Color(0xFF3897F0), fontWeight: FontWeight.w800)))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(child: Padding(padding: const EdgeInsets.only(bottom: 18), child: Avatar(store.me, size: 90))),
        _field('Name', _name),
        _field('Username', _user),
        _field('Bio', _bio, lines: 3, max: 150),
        _field('UPI ID (to receive support)', _upi, hint: 'yourname@upi'),
        const Text('Viewers can tip you through their own UPI app. Reels Pro does not process or verify payments.', style: TextStyle(color: Colors.white38, fontSize: 12)),
      ]),
    );
  }
}

void showSupportSheet(BuildContext context, AppUser u) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kSheet,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => SupportSheet(user: u),
  );
}

class SupportSheet extends StatefulWidget {
  final AppUser user;
  const SupportSheet({super.key, required this.user});
  @override
  State<SupportSheet> createState() => _SupportSheetState();
}

class _SupportSheetState extends State<SupportSheet> {
  int _amt = 50;
  final TextEditingController _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    final amt = int.tryParse(_custom.text.trim()) ?? _amt;
    if (amt <= 0) {
      toast(context, 'Enter a valid amount');
      return;
    }
    final u = widget.user;
    final uri = Uri(scheme: 'upi', host: 'pay', queryParameters: {
      'pa': u.upiId,
      'pn': u.name,
      'am': amt.toStringAsFixed(2),
      'cu': 'INR',
      'tn': 'Support on Reels Pro',
    });
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) toast(context, 'No UPI app found on this phone');
    } catch (_) {
      if (mounted) toast(context, 'No UPI app found on this phone');
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          sheetHandle(),
          Avatar(u, size: 56),
          const SizedBox(height: 10),
          Text('Support @${u.username}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 4),
          Text(u.upiId, style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
          Wrap(spacing: 8, children: [
            for (final a in const [10, 20, 50, 100, 500])
              ChoiceChip(label: Text('₹$a'), selected: _custom.text.isEmpty && _amt == a, onSelected: (_) => setState(() {
                    _amt = a;
                    _custom.clear();
                  })),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _custom,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixText: '₹ ',
              hintText: 'Custom amount',
              filled: true,
              fillColor: Colors.white10,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 16),
          GradientButton('Pay with UPI app', icon: Icons.currency_rupee, onTap: _pay),
          const SizedBox(height: 10),
          const Text('Payment happens inside your UPI app. Reels Pro does not process or verify it.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
      ),
    );
  }
}

// ============================================================================
//  CREATOR INSIGHTS
// ============================================================================
class InsightsPage extends StatelessWidget {
  const InsightsPage({super.key});

  Widget _card(double w, IconData i, String label, String value) => Container(
        width: w,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i, color: Colors.white60, size: 20),
          const SizedBox(height: 10),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final mine = store.reelsOf(AppStore.meId);
        final w = (MediaQuery.of(ctx).size.width - 32 - 12) / 2;
        final views = mine.fold<int>(0, (s, r) => s + r.views);
        final likes = mine.fold<int>(0, (s, r) => s + r.likes);
        final cm = mine.fold<int>(0, (s, r) => s + r.commentCount);
        final saves = mine.fold<int>(0, (s, r) => s + r.saves);
        final shares = mine.fold<int>(0, (s, r) => s + r.shares);
        final watch = mine.fold<int>(0, (s, r) => s + r.watchMs);
        final avgWatch = views == 0 ? 0.0 : watch / views / 1000;
        final eng = views == 0 ? 0.0 : (likes + cm + saves + shares) * 100 / views;
        final top = [...mine]..sort((a, b) => b.views.compareTo(a.views));
        final maxV = top.isEmpty ? 1 : math.max(1, top.first.views);
        return Scaffold(
          appBar: AppBar(title: const Text('Creator insights')),
          body: mine.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('Post your first reel to see views, watch time and engagement here 📊', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54))))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    _card(w, Icons.play_circle_outline, 'Views', fmtCount(views)),
                    _card(w, Icons.timer_outlined, 'Avg watch time', '${avgWatch.toStringAsFixed(1)}s'),
                    _card(w, Icons.favorite_border, 'Likes', fmtCount(likes)),
                    _card(w, Icons.mode_comment_outlined, 'Comments', fmtCount(cm)),
                    _card(w, Icons.bookmark_border, 'Saves', fmtCount(saves)),
                    _card(w, Icons.send_outlined, 'Shares', fmtCount(shares)),
                    _card(w, Icons.trending_up, 'Engagement', '${eng.toStringAsFixed(1)}%'),
                    _card(w, Icons.video_library_outlined, 'Reels', '${mine.length}'),
                  ]),
                  const SizedBox(height: 22),
                  const Text('Your reels by views', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 10),
                  for (final r in top)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(r.caption.isEmpty ? 'Untitled reel' : r.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 6),
                        Row(children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(value: r.views / maxV, minHeight: 10, backgroundColor: Colors.white10, valueColor: const AlwaysStoppedAnimation<Color>(kPink)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text('${fmtCount(r.views)} views · ${timeAgo(r.at)}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        ]),
                      ]),
                    ),
                  const SizedBox(height: 18),
                  const Text('Numbers count views on this device. Connect a backend to count every viewer.', style: TextStyle(color: Colors.white38, fontSize: 12)),
                ]),
        );
      },
    );
  }
}

// ============================================================================
//  INBOX (messages + notifications)
// ============================================================================
class InboxPage extends StatefulWidget {
  const InboxPage({super.key});
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  int _seg = 0;

  Widget _segBtn(String t, int i, {int badge = 0}) => Expanded(
        child: GestureDetector(
          onTap: () {
            setState(() => _seg = i);
            if (i == 1) WidgetsBinding.instance.addPostFrameCallback((_) => store.markNotifsRead());
          },
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _seg == i ? Colors.white : Colors.white12, width: _seg == i ? 2 : 1))),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(t, style: TextStyle(fontWeight: FontWeight.w800, color: _seg == i ? Colors.white : Colors.white54)),
              if (badge > 0) Container(margin: const EdgeInsets.only(left: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: kPink, borderRadius: BorderRadius.circular(10)), child: Text('$badge', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800))),
            ]),
          ),
        ),
      );

  void _newMessage(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSheet,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          sheetHandle(),
          const Padding(padding: EdgeInsets.all(8), child: Text('New message', style: TextStyle(fontWeight: FontWeight.w800))),
          for (final u in store.users.values.where((u) => u.id != AppStore.meId))
            ListTile(
              leading: Avatar(u, size: 40),
              title: Text(u.name),
              subtitle: Text('@${u.username}', style: const TextStyle(color: Colors.white54)),
              onTap: () {
                Navigator.pop(ctx);
                openPage<void>(context, ChatPage(userId: u.id));
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final ids = store.threads.keys.where((k) => (store.threads[k] ?? []).isNotEmpty).toList()
          ..sort((a, b) => store.threads[b]!.last.at.compareTo(store.threads[a]!.last.at));
        return Scaffold(
          appBar: AppBar(
            title: const Text('Inbox', style: TextStyle(fontWeight: FontWeight.w800)),
            actions: [IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _newMessage(ctx))],
          ),
          body: Column(children: [
            Row(children: [_segBtn('Messages', 0), _segBtn('Notifications', 1, badge: store.unreadNotifs)]),
            Expanded(
              child: _seg == 0
                  ? (ids.isEmpty
                      ? const Center(child: Text('No messages yet', style: TextStyle(color: Colors.white54)))
                      : ListView(children: [
                          for (final id in ids)
                            Builder(builder: (_) {
                              final u = store.user(id);
                              final last = store.threads[id]!.last;
                              if (u == null) return const SizedBox.shrink();
                              return ListTile(
                                leading: Avatar(u, size: 48, ring: store.hasStory(id), seen: store.allViewed(id)),
                                title: Text(u.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                                subtitle: Text(last.reelId != null ? '${last.mine ? 'You' : u.username} shared a reel 🎬' : '${last.mine ? 'You: ' : ''}${last.text}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white54)),
                                trailing: Text(timeAgo(last.at), style: const TextStyle(color: Colors.white38, fontSize: 12)),
                                onTap: () => openPage<void>(ctx, ChatPage(userId: id)),
                              );
                            }),
                        ]))
                  : (store.notifs.isEmpty
                      ? const Center(child: Text('No notifications', style: TextStyle(color: Colors.white54)))
                      : ListView(children: [
                          for (final n in store.notifs)
                            Builder(builder: (_) {
                              final u = store.user(n.userId) ?? store.me;
                              final reel = n.reelId == null ? null : store.reelById(n.reelId!);
                              return ListTile(
                                leading: Avatar(u, size: 44),
                                title: Text.rich(TextSpan(children: [
                                  if (n.type != 'system') TextSpan(text: '${u.username} ', style: const TextStyle(fontWeight: FontWeight.w800)),
                                  TextSpan(text: n.text),
                                  TextSpan(text: '  ${timeAgo(n.at)}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                                ])),
                                trailing: n.type == 'follow'
                                    ? GestureDetector(
                                        onTap: () => store.toggleFollow(u.id),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                          decoration: BoxDecoration(gradient: store.following.contains(u.id) ? null : kBrandBtn, color: store.following.contains(u.id) ? Colors.white12 : null, borderRadius: BorderRadius.circular(8)),
                                          child: Text(store.following.contains(u.id) ? 'Following' : 'Follow back', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                                        ),
                                      )
                                    : null,
                                onTap: reel != null ? () => openPage<void>(ctx, ReelViewerPage(reels: [reel])) : (n.type == 'follow' ? () => openPage<void>(ctx, ProfilePage(userId: u.id)) : null),
                              );
                            }),
                        ])),
            ),
          ]),
        );
      },
    );
  }
}

class ChatPage extends StatefulWidget {
  final String userId;
  const ChatPage({super.key, required this.userId});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _send() {
    final t = _ctl.text.trim();
    if (t.isEmpty) return;
    store.sendMessage(widget.userId, t);
    _ctl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final u = store.user(widget.userId) ?? store.me;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: () => openPage<void>(context, ProfilePage(userId: u.id)),
          child: Row(children: [
            Avatar(u, size: 34),
            const SizedBox(width: 10),
            Flexible(child: Text(u.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          ]),
        ),
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: Colors.white10,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: const Text('Demo chat: replies are automatic until a real backend is connected.', style: TextStyle(color: Colors.white54, fontSize: 11)),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: store,
            builder: (ctx, _) {
              final msgs = (store.threads[widget.userId] ?? []).reversed.toList();
              return ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: msgs.length,
                itemBuilder: (_, i) {
                  final m = msgs[i];
                  final reel = m.reelId == null ? null : store.reelById(m.reelId!);
                  return Align(
                    alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: reel != null ? () => openPage<void>(ctx, ReelViewerPage(reels: [reel])) : null,
                      child: Container(
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(ctx).size.width * 0.72),
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          gradient: m.mine ? kBrandBtn : null,
                          color: m.mine ? null : Colors.white12,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: reel != null
                            ? Row(mainAxisSize: MainAxisSize.min, children: [
                                const Icon(Icons.movie_outlined, size: 20),
                                const SizedBox(width: 8),
                                Flexible(child: Text('Reel by @${(store.user(reel.userId) ?? store.me).username}\n${reel.caption.replaceAll(RegExp(r'#[^\s#]+'), '').trim()}', maxLines: 3, overflow: TextOverflow.ellipsis)),
                              ])
                            : Text(m.text),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 6, 8, 8 + MediaQuery.of(context).viewInsets.bottom),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctl,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: 'Message…',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white10,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(26), borderSide: BorderSide.none),
                  ),
                ),
              ),
              IconButton(icon: const Icon(Icons.send_rounded, color: Color(0xFF3897F0)), onPressed: _send),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ============================================================================
//  SETTINGS
// ============================================================================
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _word = TextEditingController();

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  Widget _head(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 6), child: Text(t, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w700, fontSize: 12)));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (ctx, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(children: [
          _head('ACCOUNT'),
          ListTile(leading: const Icon(Icons.person_outline), title: const Text('Edit profile'), onTap: () => openPage<void>(ctx, const EditProfilePage())),
          ListTile(leading: const Icon(Icons.insights), title: const Text('Creator insights'), onTap: () => openPage<void>(ctx, const InsightsPage())),
          _head('FEED & DATA'),
          SwitchListTile(
            secondary: const Icon(Icons.data_saver_on),
            title: const Text('Data saver'),
            subtitle: const Text('Stops pre-loading the next reels', style: TextStyle(color: Colors.white54)),
            value: store.dataSaver,
            onChanged: store.setDataSaver,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vibration),
            title: const Text('Haptic feedback'),
            value: store.haptics,
            onChanged: store.setHaptics,
          ),
          _head('MUTED WORDS  (hide reels whose caption has these)'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _word,
                  onSubmitted: (v) {
                    store.addMuted(v);
                    _word.clear();
                  },
                  decoration: InputDecoration(hintText: 'Add a word or #hashtag', filled: true, fillColor: Colors.white10, isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
                ),
              ),
              IconButton(icon: const Icon(Icons.add_circle, color: kPink), onPressed: () {
                store.addMuted(_word.text);
                _word.clear();
              }),
            ]),
          ),
          if (store.mutedWords.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(spacing: 8, children: [for (final w in store.mutedWords) InputChip(label: Text(w), onDeleted: () => store.removeMuted(w))]),
            ),
          _head('STORAGE'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear video cache'),
            onTap: () async {
              await VideoCache.clear();
              if (ctx.mounted) toast(ctx, 'Cache cleared');
            },
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.redAccent),
            title: const Text('Reset demo data', style: TextStyle(color: Colors.redAccent)),
            subtitle: const Text('Deletes your reels, stories, comments and messages', style: TextStyle(color: Colors.white54)),
            onTap: () async {
              final ok = await confirmDialog(ctx, 'Reset everything?', 'All local data on this device will be replaced with the demo data.', ok: 'Reset');
              if (ok == true) {
                store.resetAll();
                if (ctx.mounted) toast(ctx, 'Reset done');
              }
            },
          ),
          _head('ABOUT'),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(kUploadBase.isEmpty ? 'Storage: local mode' : 'Storage: Cloudflare R2 upload'),
            subtitle: Text(kUploadBase.isEmpty ? 'Reels stay on this phone. Set kUploadBase in main.dart to upload to the cloud.' : kUploadBase, style: const TextStyle(color: Colors.white54)),
          ),
          const ListTile(leading: Icon(Icons.info_outline), title: Text('Reels Pro'), subtitle: Text('Version 2.0.0', style: TextStyle(color: Colors.white54))),
          const SizedBox(height: 30),
        ]),
      ),
    );
  }
}

// ============================================================================
//  CAMERA  (record with live filters + sound, or pick from gallery)
// ============================================================================
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
//  COMPOSE  (preview, caption, sound, filter, settings, post)
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

// ============================================================================
//  HOME SHELL + APP
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
    // Koi bhi error aaye to white screen ki jagah error text dikhe
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
