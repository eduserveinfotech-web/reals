import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_video_player_plus/cached_video_player_plus.dart';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:minio/minio.dart';
import 'package:share_plus/share_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:path_provider/path_provider.dart';

// --- CLOUDFLARE R2 CREDENTIALS ---
const String r2Endpoint = "YOUR_ACCOUNT_ID.r2.cloudflarestorage.com";
const String r2AccessKey = "YOUR_R2_ACCESS_KEY";
const String r2SecretKey = "YOUR_R2_SECRET_KEY";
const String r2BucketName = "my-reels-bucket";
const String r2PublicBaseUrl = "https://pub-xxxx.r2.dev";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: AppShell(),
  ));
}

// ------------------- डेटा मॉडल -------------------
class ReelData {
  final String id;
  final String videoUrl;
  final String username;
  final String caption;
  final String songTitle;
  int likes;
  bool isLiked;
  bool isBookmarked;
  final List<String> comments;

  ReelData({
    required this.id,
    required this.videoUrl,
    required this.username,
    required this.caption,
    required this.songTitle,
    required this.likes,
    this.isLiked = false,
    this.isBookmarked = false,
    required this.comments,
  });
}

// ------------------- मुख्य नेविगेशन -------------------
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;

  final List<ReelData> _reels = [
    ReelData(
      id: '1',
      videoUrl: 'https://assets.mixkit.co/videos/preview/mixkit-vertical-portrait-of-a-woman-in-a-field-of-sunflowers-42995-large.mp4',
      username: 'nature_lover',
      caption: 'सनफ्लावर का खूबसूरत दृश्य 🌻✨ #nature #reels #trending',
      songTitle: 'Original Audio - Nature Vibes',
      likes: 14200,
      comments: ['अति सुंदर दृश्य! ❤️', 'शानदार वीडियो brother 🔥'],
    ),
    ReelData(
      id: '2',
      videoUrl: 'https://assets.mixkit.co/videos/preview/mixkit-young-woman-skater-doing-tricks-in-a-skatepark-42984-large.mp4',
      username: 'skate_king',
      caption: 'New flip trick unlocked! 🛹🔥 10 में से कितने नंबर दोगे?',
      songTitle: 'Bass Boosted Beats - DJ Mix',
      likes: 98500,
      comments: ['10/10 bro! 🔥', 'Smooth landing 👌'],
    ),
    ReelData(
      id: '3',
      videoUrl: 'https://assets.mixkit.co/videos/preview/mixkit-tree-branches-in-the-breeze-1188-large.mp4',
      username: 'peaceful_vibes',
      caption: 'सुकून भरी शाम और ठंडी हवा 🍃🕊️ #peace #calm',
      songTitle: 'Lofi Instrumental - SoundWave',
      likes: 5410,
      comments: ['बहुत ही शांत 😌'],
    ),
  ];

  void _addNewReel(String uploadedUrl, String songName) {
    setState(() {
      _reels.insert(
        0,
        ReelData(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          videoUrl: uploadedUrl,
          username: 'creator_pro',
          caption: 'मेरी नई रील! लाइक और शेयर करें 🔥 #newreel',
          songTitle: songName,
          likes: 1,
          isLiked: true,
          comments: ['पहला कमेंट! 🔥'],
        ),
      );
      _tabIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _tabIndex == 0
          ? ReelsFeedView(reels: _reels)
          : AdvancedCameraStudio(onVideoUploaded: _addNewReel),
      bottomNavigationBar: Container(
        color: Colors.black,
        height: 55,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: Icon(Icons.movie_filter_outlined,
                  color: _tabIndex == 0 ? Colors.white : Colors.white38, size: 28),
              onPressed: () => setState(() => _tabIndex = 0),
            ),
            GestureDetector(
              onTap: () => setState(() => _tabIndex = 1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Colors.purpleAccent, Colors.orangeAccent],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.add_a_photo, color: Colors.white, size: 18),
                    SizedBox(width: 6),
                    Text('Create',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------- रील्स फीड व्यू -------------------
class ReelsFeedView extends StatefulWidget {
  final List<ReelData> reels;
  const ReelsFeedView({super.key, required this.reels});

  @override
  State<ReelsFeedView> createState() => _ReelsFeedViewState();
}

class _ReelsFeedViewState extends State<ReelsFeedView> {
  final PageController _pageController = PageController();
  int _focusedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _pageController,
      scrollDirection: Axis.vertical,
      itemCount: widget.reels.length,
      onPageChanged: (i) => setState(() => _focusedIndex = i),
      itemBuilder: (context, index) {
        return SingleReelPlayer(
          data: widget.reels[index],
          isActive: index == _focusedIndex,
        );
      },
    );
  }
}

// ------------------- सिंगल रील प्लेयर -------------------
class SingleReelPlayer extends StatefulWidget {
  final ReelData data;
  final bool isActive;
  const SingleReelPlayer({super.key, required this.data, required this.isActive});

  @override
  State<SingleReelPlayer> createState() => _SingleReelPlayerState();
}

class _SingleReelPlayerState extends State<SingleReelPlayer>
    with SingleTickerProviderStateMixin {
  late VideoPlayerPlusController _controller;
  late AnimationController _discAnimController;
  bool _isReady = false;
  bool _showBigHeart = false;
  bool _isMuted = false;
  bool _showMuteBadge = false;

  @override
  void initState() {
    super.initState();
    _discAnimController =
        AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();

    _controller = VideoPlayerPlusController.networkUrl(
      Uri.parse(widget.data.videoUrl),
      invalidateCacheIfOlderThan: const Duration(days: 7),
    )..initialize().then((_) {
        if (mounted) {
          setState(() => _isReady = true);
          _controller.setLooping(true);
          if (widget.isActive) _controller.play();
        }
      });
  }

  @override
  void didUpdateWidget(covariant SingleReelPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isReady) {
      if (widget.isActive) {
        _controller.play();
        _discAnimController.repeat();
      } else {
        _controller.pause();
        _controller.seekTo(Duration.zero);
        _discAnimController.stop();
      }
    }
  }

  @override
  void dispose() {
    _discAnimController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _triggerDoubleTapHeart() {
    setState(() {
      if (!widget.data.isLiked) {
        widget.data.isLiked = true;
        widget.data.likes++;
      }
      _showBigHeart = true;
    });
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _showBigHeart = false);
    });
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      _controller.setVolume(_isMuted ? 0.0 : 1.0);
      _showMuteBadge = true;
    });
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showMuteBadge = false);
    });
  }

  void _openCommentsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => CommentsDrawer(data: widget.data),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: _triggerDoubleTapHeart,
      onTap: _toggleMute,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _isReady
              ? FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller.value.size.width,
                    height: _controller.value.size.height,
                    child: VideoPlayerPlus(_controller),
                  ),
                )
              : const Center(
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),

          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.black26, Colors.transparent, Colors.black87],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.4, 0.95],
              ),
            ),
          ),

          if (_showMuteBadge)
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: Icon(_isMuted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white, size: 36),
              ),
            ),

          if (_showBigHeart)
            Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.2, end: 1.2),
                duration: const Duration(milliseconds: 300),
                builder: (context, scale, child) {
                  return Transform.scale(
                    scale: scale,
                    child: const Icon(Icons.favorite, color: Colors.redAccent, size: 100),
                  );
                },
              ),
            ),

          Positioned(
            left: 14,
            bottom: 20,
            right: 85,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.white24,
                      child: Icon(Icons.person, color: Colors.white, size: 18),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '@${widget.data.username}',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white60),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('Follow',
                          style: TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  widget.data.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.music_note, color: Colors.white, size: 15),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.data.songTitle,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Positioned(
            right: 12,
            bottom: 20,
            child: Column(
              children: [
                IconButton(
                  icon: Icon(
                    widget.data.isLiked ? Icons.favorite : Icons.favorite_border,
                    color: widget.data.isLiked ? Colors.redAccent : Colors.white,
                    size: 34,
                  ),
                  onPressed: () {
                    setState(() {
                      widget.data.isLiked = !widget.data.isLiked;
                      widget.data.likes += widget.data.isLiked ? 1 : -1;
                    });
                  },
                ),
                Text('${widget.data.likes}',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),

                IconButton(
                  icon: const Icon(Icons.chat_bubble_outline, color: Colors.white, size: 30),
                  onPressed: _openCommentsSheet,
                ),
                Text('${widget.data.comments.length}',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),

                IconButton(
                  icon: const Icon(Icons.share_outlined, color: Colors.white, size: 30),
                  onPressed: () {
                    Share.share('Check out this Reel: ${widget.data.videoUrl}');
                  },
                ),
                const Text('Share',
                    style: TextStyle(
                        color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),

                IconButton(
                  icon: Icon(
                    widget.data.isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                    color: Colors.white,
                    size: 30,
                  ),
                  onPressed: () {
                    setState(() => widget.data.isBookmarked = !widget.data.isBookmarked);
                  },
                ),
                const SizedBox(height: 16),

                AnimatedBuilder(
                  animation: _discAnimController,
                  builder: (_, child) {
                    return Transform.rotate(
                      angle: _discAnimController.value * 2 * math.pi,
                      child: child,
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                    ),
                    child: const CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.white24,
                      child: Icon(Icons.album, color: Colors.amberAccent, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------- कमेंट्स ड्रॉअर -------------------
class CommentsDrawer extends StatefulWidget {
  final ReelData data;
  const CommentsDrawer({super.key, required this.data});

  @override
  State<CommentsDrawer> createState() => _CommentsDrawerState();
}

class _CommentsDrawerState extends State<CommentsDrawer> {
  final TextEditingController _textCtrl = TextEditingController();

  void _postComment() {
    if (_textCtrl.text.trim().isNotEmpty) {
      setState(() {
        widget.data.comments.add(_textCtrl.text.trim());
      });
      _textCtrl.clear();
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: 380,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(10))),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Comments', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: widget.data.comments.length,
                itemBuilder: (ctx, i) {
                  return ListTile(
                    leading: const CircleAvatar(radius: 14, backgroundColor: Colors.white24, child: Icon(Icons.person, size: 16, color: Colors.white)),
                    title: Text(widget.data.comments[i], style: const TextStyle(color: Colors.white, fontSize: 13)),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Add a comment...',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Colors.black45,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, color: Colors.blueAccent),
                    onPressed: _postComment,
                  )
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}

// ------------------- एडवांस्ड कैमरा + लाइव फ़िल्टर्स + म्यूजिक मिक्सर + R2 अपलोड -------------------
class AdvancedCameraStudio extends StatefulWidget {
  final Function(String, String) onVideoUploaded;
  const AdvancedCameraStudio({super.key, required this.onVideoUploaded});

  @override
  State<AdvancedCameraStudio> createState() => _AdvancedCameraStudioState();
}

class _AdvancedCameraStudioState extends State<AdvancedCameraStudio> {
  bool _isProcessing = false;
  String _processStatus = '';
  int _selectedFilterIndex = 0;

  final AudioPlayer _audioPlayer = AudioPlayer();
  Map<String, String>? _selectedTrack;

  final List<Map<String, String>> _musicLibrary = [
    {
      'title': 'No Music (Original Mic Audio)',
      'url': '',
    },
    {
      'title': 'Trending Beat - DJ Mix',
      'url': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
    },
    {
      'title': 'Lofi Chill Vibes',
      'url': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
    },
    {
      'title': 'Acoustic Guitar Sunshine',
      'url': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3',
    },
  ];

  final List<Color> _filters = [
    Colors.transparent,
    Colors.amber.withOpacity(0.2),
    Colors.blueAccent.withOpacity(0.18),
    Colors.purpleAccent.withOpacity(0.18),
    Colors.grey.withOpacity(0.35),
  ];

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  void _openMusicBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Select Background Music',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _musicLibrary.length,
                  itemBuilder: (ctx, i) {
                    final item = _musicLibrary[i];
                    return ListTile(
                      leading: const Icon(Icons.music_note, color: Colors.amberAccent),
                      title: Text(item['title']!, style: const TextStyle(color: Colors.white, fontSize: 14)),
                      trailing: IconButton(
                        icon: const Icon(Icons.play_circle_outline, color: Colors.white70),
                        onPressed: () {
                          if (item['url']!.isNotEmpty) {
                            _audioPlayer.stop();
                            _audioPlayer.play(UrlSource(item['url']!));
                          }
                        },
                      ),
                      onTap: () {
                        setState(() {
                          _selectedTrack = item;
                        });
                        _audioPlayer.stop();
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _processAndUpload(String recordedVideoPath) async {
    setState(() {
      _isProcessing = true;
      _processStatus = 'ऑडियो और वीडियो प्रोसेस हो रहा है...';
    });

    String finalUploadPath = recordedVideoPath;
    String songTitle = _selectedTrack?['title'] ?? 'Original Audio';

    try {
      if (_selectedTrack != null && _selectedTrack!['url']!.isNotEmpty) {
        setState(() => _processStatus = 'बैकग्राउंड म्यूजिक मिक्स (Muxing) हो रहा है...');

        final tempDir = await getTemporaryDirectory();
        final outputPath = '${tempDir.path}/muxed_${DateTime.now().millisecondsSinceEpoch}.mp4';
        final audioUrl = _selectedTrack!['url']!;

        final ffmpegCommand = '-i "$recordedVideoPath" -ss 00:00:00 -i "$audioUrl" -map 0:v -map 1:a -c:v copy -c:a aac -shortest "$outputPath"';

        final session = await FFmpegKit.execute(ffmpegCommand);
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          finalUploadPath = outputPath;
        }
      }

      setState(() => _processStatus = 'Cloudflare R2 पर डायरेक्ट अपलोड हो रहा है...');

      final minio = Minio(
        endPoint: r2Endpoint,
        accessKey: r2AccessKey,
        secretKey: r2SecretKey,
        useSSL: true,
      );

      final String fileName = 'reel_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final file = File(finalUploadPath);
      final fileStream = file.openRead();
      final fileSize = await file.length();

      // Minio 3.5.8+ Compatible Stream API
      await minio.putObject(r2BucketName, fileName, fileStream, size: fileSize);
      final String publicStreamUrl = "$r2PublicBaseUrl/$fileName";

      widget.onVideoUploaded(publicStreamUrl, songTitle);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('रील म्यूजिक के साथ सफलतापूर्वक लाइव हो गई! 🚀')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('प्रोसेस त्रुटि: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _selectedTrack = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isProcessing) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.orangeAccent),
              const SizedBox(height: 20),
              Text(
                _processStatus,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        CameraAwesomeBuilder.awesome(
          saveConfig: SaveConfig.video(
            videoOptions: VideoOptions(enableAudio: true),
            mirrorFrontCamera: true,
          ),
          previewFit: CameraPreviewFit.cover,
          onMediaTap: (media) {
            // Camerawesome 2.5.0+ Compatible Media Path
            final recordedPath = media.captureRequest.path;
            if (media.isVideo && recordedPath != null) {
              _processAndUpload(recordedPath);
            }
          },
        ),

        IgnorePointer(
          child: Container(color: _filters[_selectedFilterIndex]),
        ),

        Positioned(
          top: 45,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              onTap: _openMusicBottomSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white30),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.music_note, color: Colors.amberAccent, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      _selectedTrack != null ? _selectedTrack!['title']! : 'Add Music',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        Positioned(
          bottom: 120,
          left: 0,
          right: 0,
          child: SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _filters.length,
              itemBuilder: (ctx, i) {
                final isSelected = _selectedFilterIndex == i;
                final labels = ['Normal', 'Vintage', 'Cool', 'Cyberpunk', 'Noir'];
                return GestureDetector(
                  onTap: () => setState(() => _selectedFilterIndex = i),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.white : Colors.black45,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Center(
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          color: isSelected ? Colors.black : Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
