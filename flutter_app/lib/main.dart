import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'firebase_options.dart';

const _mediaMimeTypesByExtension = <String, String>{
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  'wmv': 'video/x-ms-wmv',
  'asf': 'video/x-ms-asf',
  '3gp': 'video/3gpp',
  '3g2': 'video/3gpp2',
  'mpeg': 'video/mpeg',
  'mpg': 'video/mpeg',
  'ogv': 'video/ogg',
  'flv': 'video/x-flv',
  'ts': 'video/mp2t',
  'm2ts': 'video/mp2t',
  'mts': 'video/mp2t',
  'vob': 'video/dvd',
  'm3u8': 'application/vnd.apple.mpegurl',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
};

String videoContentTypeForName(String name, {String? mimeType}) {
  final suppliedMimeType = mimeType?.toLowerCase();
  if (suppliedMimeType != null &&
      (suppliedMimeType.startsWith('video/') ||
          suppliedMimeType == 'application/vnd.apple.mpegurl')) {
    return suppliedMimeType;
  }
  final extension = name.split('.').last.toLowerCase();
  return _mediaMimeTypesByExtension[extension] ??
      suppliedMimeType ??
      'application/octet-stream';
}

String _videoExtensionForMime(String mimeType) {
  for (final entry in _mediaMimeTypesByExtension.entries) {
    if (entry.value == mimeType.toLowerCase()) return entry.key;
  }
  return 'bin';
}

bool hasPlayableMediaSource(String? source) {
  final value = source?.trim() ?? '';
  if (value.isEmpty) return false;
  final normalized = value.toLowerCase();
  return normalized.startsWith('http://') ||
      normalized.startsWith('https://') ||
      normalized.startsWith('data:video/') ||
      normalized.startsWith('data:audio/') ||
      normalized.startsWith('data:application/octet-stream;') &&
          normalized.contains('video');
}

bool _flicksGlobalMuted = true;

Future<VideoPlayerController> _buildVideoController(String rawUrl) async {
  final value = rawUrl.trim();
  if (kIsWeb) {
    return VideoPlayerController.networkUrl(Uri.parse(value));
  }
  if (value.startsWith('data:video/') || value.startsWith('data:audio/')) {
    final data = UriData.fromUri(Uri.parse(value));
    if (data.mimeType.startsWith('video/') ||
        data.mimeType.startsWith('audio/')) {
      final bytes = data.contentAsBytes();
      final extension = _videoExtensionForMime(data.mimeType);
      final file = File(
        '${(await getTemporaryDirectory()).path}/viyou_video_${DateTime.now().millisecondsSinceEpoch}.$extension',
      );
      await file.writeAsBytes(bytes);
      return VideoPlayerController.file(file);
    }
  }
  return VideoPlayerController.networkUrl(Uri.parse(value));
}

Future<File> _downloadVideoToTemporaryFile(String source) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(source));
    request.headers.set(HttpHeaders.acceptHeader, 'video/*,audio/*,*/*;q=0.8');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw HttpException('Video server returned HTTP ${response.statusCode}');
    }

    final contentType = response.headers.contentType?.mimeType.toLowerCase();
    if (contentType != null &&
        (contentType.startsWith('text/') ||
            contentType == 'application/json')) {
      await response.drain<void>();
      throw FormatException('Video server returned $contentType');
    }

    var extension = contentType == null
        ? 'bin'
        : _videoExtensionForMime(contentType);
    if (extension == 'bin') {
      final pathExtension = Uri.parse(
        source,
      ).pathSegments.last.split('.').last.toLowerCase();
      extension = _mediaMimeTypesByExtension.containsKey(pathExtension)
          ? pathExtension
          : 'mp4';
    }
    final file = File(
      '${(await getTemporaryDirectory()).path}/viyou_stream_${DateTime.now().millisecondsSinceEpoch}.$extension',
    );
    await response.pipe(file.openWrite());
    return file;
  } finally {
    client.close(force: true);
  }
}

Future<VideoPlayerController> _initializeVideoControllerWithFallback(
  String source,
) async {
  final controller = await _buildVideoController(source);
  try {
    await controller.initialize();
    return controller;
  } catch (networkError) {
    await controller.dispose();
    final uri = Uri.tryParse(source);
    if (kIsWeb ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      rethrow;
    }
    try {
      final file = await _downloadVideoToTemporaryFile(source);
      final fileController = VideoPlayerController.file(file);
      await fileController.initialize();
      return fileController;
    } catch (fileError) {
      throw StateError(
        'Network playback failed: $networkError. Local stream playback failed: $fileError',
      );
    }
  }
}

Future<bool> _requestAppPermission(
  BuildContext context,
  Permission permission, {
  required String title,
  required String explanation,
}) async {
  var status = await permission.status;
  if (status.isGranted || status.isLimited || status.isProvisional) return true;
  if (!context.mounted) return false;

  final mustOpenSettings = status.isPermanentlyDenied || status.isRestricted;
  final proceed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(explanation),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(mustOpenSettings ? 'Open settings' : 'Continue'),
        ),
      ],
    ),
  );
  if (proceed != true) return false;
  if (mustOpenSettings) {
    await openAppSettings();
    return false;
  }

  status = await permission.request();
  if (status.isGranted || status.isLimited || status.isProvisional) return true;
  if ((status.isPermanentlyDenied || status.isRestricted) && context.mounted) {
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Permission is off'),
        content: const Text(
          'You can enable this permission later in the app settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (openSettings == true) await openAppSettings();
  }
  return false;
}

Future<XFile?> _pickImageWithCameraChoice(
  BuildContext context, {
  required String purpose,
}) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    backgroundColor: const Color(0xff151515),
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
          ),
        ],
      ),
    ),
  );
  if (source == null) return null;
  if (source == ImageSource.camera &&
      !kIsWeb &&
      !await _requestAppPermission(
        context,
        Permission.camera,
        title: 'Allow camera access?',
        explanation: 'Viyou needs camera access to $purpose.',
      )) {
    return null;
  }
  return ImagePicker().pickImage(source: source);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ViyouApp());
}

class ViyouApp extends StatelessWidget {
  const ViyouApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Viyou.in',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xff050505),
        fontFamily: 'Arial',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff6366f1),
          brightness: Brightness.dark,
        ),
      ),
      home: const ViyouEntryGate(),
    );
  }
}

class ViyouEntryGate extends StatelessWidget {
  const ViyouEntryGate({super.key});

  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    builder: (context, authSnapshot) {
      if (authSnapshot.connectionState == ConnectionState.waiting) {
        return const _ViyouLoadingScreen();
      }
      final user = authSnapshot.data;
      if (user == null) return const ViyouHomePage();

      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots(),
        builder: (context, profileSnapshot) {
          if (profileSnapshot.connectionState == ConnectionState.waiting &&
              !profileSnapshot.hasData) {
            return const _ViyouLoadingScreen();
          }
          if (profileSnapshot.hasError) {
            return _ViyouGateError(user: user);
          }

          final profile = profileSnapshot.data?.data() ?? {};
          final name = '${profile['name'] ?? ''}'.trim();
          final username = '${profile['username'] ?? ''}'.trim();
          if (name.isEmpty || username.isEmpty) {
            return ViyouProfileSetupPage(
              key: ValueKey(user.uid),
              user: user,
              initialName: name.isEmpty ? user.displayName ?? '' : name,
              initialUsername: username,
              initialBio: '${profile['bio'] ?? ''}',
            );
          }
          return const ViyouHomePage();
        },
      );
    },
  );
}

class _ViyouLoadingScreen extends StatelessWidget {
  const _ViyouLoadingScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _ViyouGateError extends StatelessWidget {
  const _ViyouGateError({required this.user});

  final User user;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Could not load your profile. Check your connection and try again.',
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => FirebaseAuth.instance.signOut(),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<bool> _isUsernameAvailable(String username, String currentUid) async {
  final normalized = username.trim().toLowerCase();
  final matches = await FirebaseFirestore.instance
      .collection('users')
      .where('usernameLower', isEqualTo: normalized)
      .get();
  return matches.docs.every((document) => document.id == currentUid);
}

class ViyouProfileSetupPage extends StatefulWidget {
  const ViyouProfileSetupPage({
    required this.user,
    required this.initialName,
    required this.initialUsername,
    required this.initialBio,
    super.key,
  });

  final User user;
  final String initialName;
  final String initialUsername;
  final String initialBio;

  @override
  State<ViyouProfileSetupPage> createState() => _ViyouProfileSetupPageState();
}

class _ViyouProfileSetupPageState extends State<ViyouProfileSetupPage> {
  late final _name = TextEditingController(text: widget.initialName);
  late final _username = TextEditingController(text: widget.initialUsername);
  late final _bio = TextEditingController(text: widget.initialBio);
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _errorMessage = null;
    });

    final name = _name.text.trim();
    final username = _username.text.trim();
    try {
      if (!await _isUsernameAvailable(username, widget.user.uid)) {
        setState(() {
          _saving = false;
          _errorMessage = 'That Unique ID is already taken. Try another one.';
        });
        return;
      }

      await widget.user.updateDisplayName(name);
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.user.uid)
          .set({
            'name': name,
            'username': username,
            'usernameLower': username.toLowerCase(),
            'bio': _bio.text.trim(),
            'email': widget.user.email,
            'photoURL': widget.user.photoURL,
          }, SetOptions(merge: true));
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errorMessage = 'Could not save your profile. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Set up your profile'),
      actions: [
        IconButton(
          tooltip: 'Sign out',
          onPressed: _saving ? null : () => FirebaseAuth.instance.signOut(),
          icon: const Icon(Icons.logout_rounded),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Text(
                  'Create your Viyou identity',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text('Choose a name and a unique ID to continue.'),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _name,
                  enabled: !_saving,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name *'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Name is required'
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _username,
                  enabled: !_saving,
                  maxLength: 30,
                  decoration: const InputDecoration(
                    labelText: 'Unique ID *',
                    prefixText: '@',
                  ),
                  validator: (value) {
                    final username = value?.trim() ?? '';
                    if (username.isEmpty) return 'Unique ID is required';
                    if (username.length > 30) {
                      return 'Unique ID can be at most 30 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _bio,
                  enabled: !_saving,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Bio (optional)',
                  ),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class ViyouSearchPage extends StatefulWidget {
  const ViyouSearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  State<ViyouSearchPage> createState() => _ViyouSearchPageState();
}

class _ViyouSearchPageState extends State<ViyouSearchPage> {
  static final SpeechToText _speech = SpeechToText();
  static final ValueNotifier<bool> _speechListening = ValueNotifier(false);
  static Future<bool>? _speechInitialization;

  late final TextEditingController _queryController;
  Timer? _debounce;
  Future<List<BlogRecord>>? _resultsFuture;
  Future<List<BlogRecord>>? _suggestionsFuture;
  bool _showSuggestions = false;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery.trim().isNotEmpty) {
      _resultsFuture = _search(widget.initialQuery);
    }
  }

  Future<List<BlogRecord>> _search(String rawQuery) async {
    final query = _normalizeSearchText(rawQuery);
    final collection = FirebaseFirestore.instance.collection('blogs');
    if (query.isEmpty) {
      final recent = await collection
          .where('status', isEqualTo: 'published')
          .limit(40)
          .get();
      final results = recent.docs.map(BlogRecord.fromDocument).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      return results.take(20).toList();
    }

    final terms = _searchTerms(query);
    final searchQueries = <Future<QuerySnapshot<Map<String, dynamic>>>>[
      collection
          .where('titleLower', isGreaterThanOrEqualTo: query)
          .where('titleLower', isLessThan: '$query\uf8ff')
          .limit(30)
          .get(),
      collection.where('keywords', arrayContains: query).limit(30).get(),
    ];
    for (final term in terms.take(5)) {
      if (term == query) continue;
      searchQueries.addAll([
        collection
            .where('titleLower', isGreaterThanOrEqualTo: term)
            .where('titleLower', isLessThan: '$term\uf8ff')
            .limit(20)
            .get(),
        collection.where('keywords', arrayContains: term).limit(20).get(),
      ]);
    }

    final snapshots = await Future.wait(searchQueries);
    final documents = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final snapshot in snapshots) {
      for (final document in snapshot.docs) {
        documents[document.id] = document;
      }
    }

    final results = <BlogRecord>[];
    final scores = <String, int>{};
    void addRankedResults(
      Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    ) {
      for (final document in docs) {
        if (scores.containsKey(document.id)) continue;
        final data = document.data();
        if (data['status'] != 'published') continue;
        final post = BlogRecord.fromDocument(document);
        final score = _searchScore(post, data, query, terms);
        if (score <= 0) continue;
        scores[document.id] = score;
        results.add(post);
      }
    }

    addRankedResults(documents.values);
    if (results.length < 5) {
      final recent = await collection
          .where('status', isEqualTo: 'published')
          .limit(120)
          .get();
      addRankedResults(recent.docs);
    }
    results.sort((a, b) {
      final byRelevance = (scores[b.id] ?? 0).compareTo(scores[a.id] ?? 0);
      if (byRelevance != 0) return byRelevance;
      return b.date.compareTo(a.date);
    });
    return results.take(30).toList();
  }

  String _normalizeSearchText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'''[.,!?;:()\[\]{}"'“”‘’/\\_|+।-]+'''), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  List<String> _searchTerms(String query) {
    const ignoredWords = {
      'find',
      'search',
      'show',
      'please',
      'me',
      'the',
      'a',
      'an',
      'for',
      'with',
      'in',
      'on',
      'of',
      'and',
      'to',
      'hai',
      'hain',
      'ka',
      'ki',
      'ke',
      'mein',
      'mujhe',
      'dikhao',
      'batao',
      'chahiye',
      'karo',
      'kar',
      'do',
      'wala',
      'wali',
      'wale',
    };
    final terms = query
        .split(' ')
        .where((term) => term.length > 1 && !ignoredWords.contains(term))
        .toSet()
        .toList();
    return terms.isEmpty ? [query] : terms;
  }

  int _searchScore(
    BlogRecord post,
    Map<String, dynamic> data,
    String query,
    List<String> terms,
  ) {
    final title = _normalizeSearchText(post.title);
    final creator = _normalizeSearchText(post.author);
    final category = _normalizeSearchText(post.category);
    final content = _normalizeSearchText(post.content);
    final keywordsValue = data['keywords'];
    final keywords = keywordsValue is Iterable
        ? keywordsValue.whereType<String>().map(_normalizeSearchText).toList()
        : keywordsValue is String
        ? [_normalizeSearchText(keywordsValue)]
        : const <String>[];
    final keywordText = keywords.join(' ');

    var score = 0;
    if (title == query) {
      score += 500;
    } else if (title.startsWith(query)) {
      score += 350;
    } else if (title.contains(query)) {
      score += 240;
    }
    if (keywordText.contains(query)) score += 180;

    var matchedTerms = 0;
    for (final term in terms) {
      var termScore = 0;
      if (title.split(' ').contains(term)) {
        termScore += 30;
      } else if (title.contains(term)) {
        termScore += 20;
      }
      if (keywords.any((keyword) => keyword.split(' ').contains(term))) {
        termScore += 22;
      }
      if (creator.contains(term) || category.contains(term)) termScore += 8;
      if (content.contains(term)) termScore += 3;
      if (termScore > 0) {
        matchedTerms++;
        score += termScore;
      }
    }

    final minimumMatches = terms.length <= 2
        ? terms.length
        : (terms.length * 0.6).ceil();
    if (matchedTerms < minimumMatches) return 0;
    if (matchedTerms == terms.length) score += 25;
    return score;
  }

  void _scheduleSearch(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _showSuggestions = false;
        _suggestionsFuture = null;
        _resultsFuture = null;
      });
      return;
    }
    setState(() {
      _showSuggestions = true;
      _suggestionsFuture = _loadSuggestions(value);
    });
    _debounce = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      setState(() => _resultsFuture = _search(value));
    });
  }

  Future<List<BlogRecord>> _loadSuggestions(String rawQuery) async {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return const <BlogRecord>[];
    final collection = FirebaseFirestore.instance.collection('blogs');
    final snapshots = await Future.wait([
      collection
          .where('titleLower', isGreaterThanOrEqualTo: query)
          .where('titleLower', isLessThan: '$query\uf8ff')
          .limit(8)
          .get(),
      collection.where('keywords', arrayContains: query).limit(8).get(),
    ]);
    final documents = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final snapshot in snapshots) {
      for (final document in snapshot.docs) {
        documents[document.id] = document;
      }
    }
    return documents.values
        .map(BlogRecord.fromDocument)
        .where((post) => post.status == 'published')
        .take(6)
        .toList();
  }

  Future<void> _toggleVoiceSearch() async {
    if (_speech.isListening) {
      await _speech.stop();
      _speechListening.value = false;
      return;
    }

    final allowed = await _requestAppPermission(
      context,
      Permission.microphone,
      title: 'Allow microphone access?',
      explanation:
          'Viyou uses your microphone only while you dictate a content search.',
    );
    if (!allowed || !mounted) return;

    try {
      final available = await (_speechInitialization ??= _speech.initialize(
        onStatus: (status) {
          _speechListening.value = status == SpeechToText.listeningStatus;
        },
        onError: (_) => _speechListening.value = false,
        options: [SpeechToText.androidNoBluetooth],
      ));
      if (!mounted) return;
      if (!available) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Voice search is unavailable on this device'),
          ),
        );
        return;
      }

      final systemLocale = await _speech.systemLocale();
      await _speech.listen(
        localeId: systemLocale?.localeId,
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.search,
        onResult: (result) {
          final transcript = result.recognizedWords.trim();
          if (transcript.isNotEmpty && mounted) {
            _queryController.value = TextEditingValue(
              text: transcript,
              selection: TextSelection.collapsed(offset: transcript.length),
            );
            _scheduleSearch(transcript);
          }
          if (result.finalResult) _speechListening.value = false;
        },
      );
      _speechListening.value = _speech.isListening;
    } catch (error) {
      _speechListening.value = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice search could not start: $error')),
        );
      }
    }
  }

  @override
  void dispose() {
    if (_speech.isListening) unawaited(_speech.stop());
    _debounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _openResult(List<BlogRecord> results, int index) async {
    final post = results[index];
    if (post.isFlicker) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => _SearchFlickViewerPage(
            flicks: results.where((item) => item.isFlicker).toList(),
            initialIndex: results
                .where((item) => item.isFlicker)
                .toList()
                .indexOf(post),
          ),
        ),
      );
      return;
    }
    if (post.video != null || post.youtubeUrl != null) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => ViyouVideoPlayer(video: post)),
      );
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => _SearchContentPage(blog: post)),
    );
  }

  void _applySuggestion(BlogRecord suggestion) {
    final query = suggestion.title;
    _queryController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    setState(() {
      _showSuggestions = false;
      _resultsFuture = _search(query);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: TextField(
          controller: _queryController,
          autofocus: widget.initialQuery.isEmpty,
          textInputAction: TextInputAction.search,
          onChanged: _scheduleSearch,
          onSubmitted: (value) => setState(() {
            _showSuggestions = false;
            _resultsFuture = _search(value);
          }),
          onTap: () {
            if (_queryController.text.trim().isNotEmpty) {
              setState(() => _showSuggestions = true);
            }
          },
          decoration: const InputDecoration(
            hintText: 'Search videos, creators, topics',
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: _speechListening,
            builder: (context, listening, _) => IconButton(
              onPressed: _toggleVoiceSearch,
              tooltip: listening ? 'Stop voice search' : 'Voice search',
              icon: Icon(
                listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                color: listening ? Colors.redAccent : null,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_showSuggestions && _suggestionsFuture != null)
            FutureBuilder<List<BlogRecord>>(
              future: _suggestionsFuture,
              builder: (context, snapshot) {
                final suggestions = snapshot.data ?? const <BlogRecord>[];
                if (suggestions.isEmpty) return const SizedBox.shrink();
                return Material(
                  color: const Color(0xff151515),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: suggestions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final suggestion = suggestions[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.search_rounded, size: 20),
                        title: Text(
                          suggestion.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${suggestion.author} • ${suggestion.category}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => _applySuggestion(suggestion),
                      );
                    },
                  ),
                );
              },
            ),
          Expanded(
            child: _resultsFuture == null
                ? const Center(child: Text('Search Viyou content'))
                : FutureBuilder<List<BlogRecord>>(
                    future: _resultsFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return Center(
                          child: Text('Search failed: ${snapshot.error}'),
                        );
                      }
                      final results = snapshot.data ?? const <BlogRecord>[];
                      if (results.isEmpty) {
                        return const Center(
                          child: Text('No matching content found'),
                        );
                      }
                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
                        itemCount: results.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final post = results[index];
                          return _SearchResultTile(
                            post: post,
                            onTap: () => _openResult(results, index),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.post, required this.onTap});

  final BlogRecord post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final media = post.primaryImage;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              SizedBox(
                width: 128,
                height: 76,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: media == null || media.isEmpty
                      ? const ColoredBox(
                          color: Color(0xff202020),
                          child: Icon(Icons.play_circle_outline),
                        )
                      : media.startsWith('data:image/')
                      ? Image.memory(
                          base64Decode(media.substring(media.indexOf(',') + 1)),
                          fit: BoxFit.cover,
                        )
                      : Image.network(media, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${post.author} • ${post.category}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      post.isFlicker
                          ? '${post.viewsCount} views • Flick'
                          : post.video != null || post.youtubeUrl != null
                          ? '${post.viewsCount} views • Video'
                          : 'Blog',
                      style: TextStyle(color: Colors.grey[500], fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchFlickViewerPage extends StatefulWidget {
  const _SearchFlickViewerPage({
    required this.flicks,
    required this.initialIndex,
  });

  final List<BlogRecord> flicks;
  final int initialIndex;

  @override
  State<_SearchFlickViewerPage> createState() => _SearchFlickViewerPageState();
}

class _SearchFlickViewerPageState extends State<_SearchFlickViewerPage> {
  late final PageController _controller;
  late int _activeIndex;

  @override
  void initState() {
    super.initState();
    _activeIndex = widget.initialIndex.clamp(0, widget.flicks.length - 1);
    _controller = PageController(initialPage: _activeIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Flicks'),
      ),
      body: PageView.builder(
        controller: _controller,
        scrollDirection: Axis.vertical,
        itemCount: widget.flicks.length,
        onPageChanged: (index) => setState(() => _activeIndex = index),
        itemBuilder: (context, index) => _FlickPage(
          blog: widget.flicks[index],
          isActive: index == _activeIndex,
        ),
      ),
    );
  }
}

class _SearchContentPage extends StatelessWidget {
  const _SearchContentPage({required this.blog});

  final BlogRecord blog;

  @override
  Widget build(BuildContext context) {
    final image = blog.primaryImage;
    return Scaffold(
      appBar: AppBar(title: const Text('Content')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            blog.title,
            style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            '${blog.author} • ${blog.category}',
            style: TextStyle(color: Colors.grey[400]),
          ),
          if (image != null && image.isNotEmpty) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: image.startsWith('data:image/')
                  ? Image.memory(
                      base64Decode(image.substring(image.indexOf(',') + 1)),
                      fit: BoxFit.cover,
                    )
                  : Image.network(image, fit: BoxFit.cover),
            ),
          ],
          const SizedBox(height: 18),
          Text(
            blog.content.isEmpty ? 'No description available.' : blog.content,
            style: const TextStyle(fontSize: 16, height: 1.55),
          ),
          const SizedBox(height: 22),
          BlogComments(blog: blog),
        ],
      ),
    );
  }
}

class ViyouHomePage extends StatefulWidget {
  const ViyouHomePage({super.key});

  @override
  State<ViyouHomePage> createState() => _ViyouHomePageState();
}

class _ViyouHomePageState extends State<ViyouHomePage> {
  int _selectedTab = 0;
  int _currentFlickIndex = 0;
  String _selectedCategory = 'All';
  bool _likedFirstPost = false;
  int _profileSection = 0;
  final Set<String> _likedBlogIds = <String>{};
  final Map<String, int> _likeCounts = <String, int>{};
  late Future<List<BlogRecord>> _blogsFuture;
  late Future<List<BlogRecord>> _videosFuture;
  late Future<List<BlogRecord>> _flicksFuture;
  late Future<UserProfile> _profileFuture;
  final _searchController = TextEditingController();
  final _messageSearchController = TextEditingController();
  final PageController _flicksPageController = PageController();

  final _categories = const [
    'All',
    'Entertainment',
    'Music',
    'Vlogs',
    'Gaming',
    'Education',
    'Sports',
    'News & Politics',
    'Science & Technology',
    'Comedy',
    'Travel & Events',
    'Fashion & Beauty',
    'Food',
    'Devotional',
    'Gym & Fitness',
    'Health',
    'Podcasts',
    'Others',
  ];

  @override
  void initState() {
    super.initState();
    _blogsFuture = _loadBlogs();
    _videosFuture = _loadVideos();
    _flicksFuture = _loadFlicks();
    _profileFuture = _loadProfile();
  }

  Future<String?> _compressProfileImage(XFile file) async {
    final decoded = img.decodeImage(await file.readAsBytes());
    if (decoded == null) return null;
    final square = img.copyResizeCropSquare(decoded, size: 320);
    var quality = 85;
    List<int> encoded = img.encodeJpg(square, quality: quality);
    while (encoded.length > 100000 && quality > 15) {
      quality -= 5;
      encoded = img.encodeJpg(square, quality: quality);
    }
    if (encoded.length > 100000) return null;
    return 'data:image/jpeg;base64,${base64Encode(encoded)}';
  }

  Future<void> _changeProfilePhoto() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final file = await _pickImageWithCameraChoice(
      context,
      purpose: 'take your profile photo',
    );
    if (file == null) return;
    final dataUrl = await _compressProfileImage(file);
    if (dataUrl == null) {
      if (mounted)
        _showMessage(context, 'Image could not be compressed below 100 KB');
      return;
    }
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'photoURL': dataUrl,
    }, SetOptions(merge: true));
    final blogs = await FirebaseFirestore.instance
        .collection('blogs')
        .where('authorUid', isEqualTo: user.uid)
        .get();
    await Future.wait(
      blogs.docs.map((blog) => blog.reference.update({'authorPhoto': dataUrl})),
    );
    if (!mounted) return;
    setState(() => _profileFuture = _loadProfile());
    _showMessage(context, 'Profile photo updated');
  }

  Future<void> _savePostToPlaylist(BlogRecord blog) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final playlists = await FirebaseFirestore.instance
        .collection('playlists')
        .where('authorUid', isEqualTo: user.uid)
        .get();
    if (!mounted) return;
    if (playlists.docs.isEmpty) {
      _showMessage(context, 'Create a playlist first from your profile');
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xff151515),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Save to playlist',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            ...playlists.docs.map(
              (playlist) => ListTile(
                leading: const Icon(Icons.playlist_play_rounded),
                title: Text('${playlist.data()['name'] ?? 'Playlist'}'),
                onTap: () => Navigator.pop(sheetContext, playlist.id),
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await FirebaseFirestore.instance
        .collection('playlists')
        .doc(selected)
        .update({
          'items': FieldValue.arrayUnion([blog.id]),
        });
    if (mounted) _showMessage(context, 'Added to playlist');
  }

  Future<void> _copyPostLink(BlogRecord blog) async {
    final link = blog.video ?? blog.image ?? blog.id;
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) _showMessage(context, 'Link copied');
  }

  Future<void> _createPlaylistFromProfile() async {
    if (FirebaseAuth.instance.currentUser == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const ViyouPlaylistsPage()),
    );
  }

  Future<void> _showScheduledContent() async {
    if (FirebaseAuth.instance.currentUser == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const ViyouScheduledPage()),
    );
  }

  Future<void> _openConnections(String field) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ViyouConnectionsPage(userId: user.uid, field: field),
      ),
    );
  }

  Widget _profileActionChip({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => ActionChip(
    avatar: Icon(icon, size: 18),
    label: Text(label),
    onPressed: onPressed,
  );

  Widget _storyToolButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 72,
          height: 56,
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xfff59e0b)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: active ? Colors.black : Colors.white),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: active ? Colors.black : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _storyAlignButton(
    String label,
    IconData icon,
    VoidCallback onPressed,
  ) {
    return Expanded(
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
      ),
    );
  }

  Widget _profileTabChip(int value, IconData icon, String label) {
    final selected = _profileSection == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        avatar: Icon(icon, size: 17),
        label: Text(label),
        selectedColor: const Color(0xfff59e0b),
        labelStyle: TextStyle(
          color: selected ? Colors.black : Colors.white,
          fontWeight: FontWeight.w700,
        ),
        onSelected: (_) => setState(() => _profileSection = value),
      ),
    );
  }

  Future<List<BlogRecord>> _loadBlogs() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('blogs')
        .where('status', isEqualTo: 'published')
        .limit(30)
        .get();
    final blogs = snapshot.docs.map(BlogRecord.fromDocument).toList();
    blogs.sort((a, b) => b.date.compareTo(a.date));
    return blogs;
  }

  Future<List<BlogRecord>> _loadVideos() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('blogs')
        .where('status', isEqualTo: 'published')
        .limit(50)
        .get();
    final videos = snapshot.docs
        .map(BlogRecord.fromDocument)
        .where(
          (blog) =>
              !blog.isFlicker &&
              (blog.video != null || blog.youtubeUrl != null),
        )
        .toList();
    videos.sort((a, b) => b.date.compareTo(a.date));
    return videos;
  }

  Future<List<BlogRecord>> _loadFlicks() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final currentUserDoc = currentUser == null
        ? null
        : await FirebaseFirestore.instance
              .collection('users')
              .doc(currentUser.uid)
              .get();
    final blockedByMe = currentUserDoc?.data()?['blockedUsers'] is List
        ? List<String>.from(currentUserDoc!.data()!['blockedUsers'])
        : <String>[];

    final snapshot = await FirebaseFirestore.instance
        .collection('blogs')
        .where('status', isEqualTo: 'published')
        .where('isFlicker', isEqualTo: true)
        .limit(100)
        .get();

    final allFlicks = snapshot.docs
        .map(BlogRecord.fromDocument)
        .where(
          (blog) =>
              !blockedByMe.contains(blog.authorUid) &&
              (hasPlayableMediaSource(blog.video) ||
                  hasPlayableMediaSource(blog.youtubeUrl)),
        )
        .toList();

    allFlicks.shuffle();
    return allFlicks;
  }

  Future<UserProfile> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return UserProfile.empty;
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final postsSnapshot = await FirebaseFirestore.instance
        .collection('blogs')
        .where('authorUid', isEqualTo: user.uid)
        .limit(30)
        .get();
    final posts = postsSnapshot.docs.map(BlogRecord.fromDocument).toList();
    return UserProfile.fromDocument(snapshot, user, posts);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _messageSearchController.dispose();
    _flicksPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 850;
        return Scaffold(
          appBar: _buildHeader(isDesktop),
          body: SafeArea(
            top: false,
            bottom: false,
            child: switch (_selectedTab) {
              0 => _buildHome(isDesktop),
              1 => _buildFlicks(),
              3 => _buildMessages(),
              4 => _buildProfile(),
              _ => _buildPlaceholderTab(),
            },
          ),
          bottomNavigationBar: isDesktop ? null : _buildBottomNavigation(),
        );
      },
    );
  }

  Widget _buildNotificationsButton() => IconButton(
    onPressed: _showNotifications,
    icon: const Icon(Icons.notifications_none_rounded),
    tooltip: 'Notifications',
  );

  Future<void> _showNotifications() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await _showAuthDialog();
      return;
    }
    await _requestAppPermission(
      context,
      Permission.notification,
      title: 'Allow notifications?',
      explanation:
          'Enable notifications to hear about new messages and activity on Viyou. You can change this later in app settings.',
    );
    if (!mounted) return;
    final snapshot = await FirebaseFirestore.instance
        .collection('notifications')
        .where('recipientUid', isEqualTo: user.uid)
        .limit(50)
        .get();
    final notifications = snapshot.docs.toList()
      ..sort((a, b) {
        final aDate = '${a.data()['date'] ?? ''}';
        final bDate = '${b.data()['date'] ?? ''}';
        return bDate.compareTo(aDate);
      });
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xff151515),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .72,
          child: Column(
            children: [
              const ListTile(
                leading: Icon(Icons.notifications_active_outlined),
                title: Text(
                  'Notifications',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Expanded(
                child: notifications.isEmpty
                    ? const Center(child: Text('No notifications yet'))
                    : ListView.builder(
                        itemCount: notifications.length,
                        itemBuilder: (context, index) {
                          final data = notifications[index].data();
                          return ListTile(
                            leading: Icon(
                              data['type'] == 'follow'
                                  ? Icons.person_add_alt_1_rounded
                                  : Icons.favorite_border_rounded,
                              color: const Color(0xffff0050),
                            ),
                            title: Text(
                              '${data['senderName'] ?? 'Someone'} ${data['type'] == 'follow' ? 'started following you' : 'liked your content'}',
                            ),
                            subtitle: Text('${data['blogTitle'] ?? ''}'),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildHeader(bool isDesktop) {
    return AppBar(
      elevation: 0,
      backgroundColor: const Color(0xff0f0f0f),
      titleSpacing: isDesktop ? 22 : 14,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ViyouSettingsHubPage(onLogin: _showAuthDialog),
              ),
            ),
            icon: const Icon(Icons.settings_outlined, size: 25),
            tooltip: 'Settings',
          ),
          const SizedBox(width: 4),
          Image.asset(
            'assets/viyou_logo.png',
            width: 30,
            height: 30,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 8),
          const Text(
            'Viyou.in',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
          ),
        ],
      ),
      actions: [
        if (isDesktop) SizedBox(width: 360, child: _searchField()),
        if (!isDesktop)
          IconButton(
            onPressed: () => _openSearchPage(),
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Search',
          ),
        _buildNotificationsButton(),
      ],
    );
  }

  Widget _searchField() {
    return TextField(
      controller: _searchController,
      textInputAction: TextInputAction.search,
      onSubmitted: (value) => _openSearchPage(initialQuery: value),
      decoration: InputDecoration(
        hintText: 'Search',
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        filled: true,
        fillColor: const Color(0xff181818),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Future<void> _openSearchPage({String initialQuery = ''}) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ViyouSearchPage(initialQuery: initialQuery),
      ),
    );
  }

  Widget _buildHome(bool isDesktop) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 28 : 14,
        20,
        isDesktop ? 28 : 14,
        100,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1220),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStories(),
              const SizedBox(height: 28),
              _sectionTitle(
                'Latest from creators',
                Icons.auto_awesome_rounded,
                const Color(0xff6366f1),
              ),
              const SizedBox(height: 14),
              _buildCategories(),
              const SizedBox(height: 18),
              _buildFlickSuggestions(),
              _buildLiveFeed(isDesktop),
              const SizedBox(height: 34),
              Center(
                child: Text(
                  '© Viyou.in  Empowering Creators',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveFeed(bool isDesktop) {
    return FutureBuilder<List<BlogRecord>>(
      future: _blogsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final blogs = snapshot.data ?? const <BlogRecord>[];
        final filtered = _selectedCategory == 'All'
            ? blogs
            : blogs
                  .where((blog) => blog.category == _selectedCategory)
                  .toList();
        if (filtered.isEmpty)
          return _emptyState(
            'No published posts in this category yet. Please check back later.',
          );
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: _loadActiveInFeedAds(),
          builder: (context, adSnapshot) {
            final ads = adSnapshot.data ?? const <Map<String, dynamic>>[];
            final children = <Widget>[];
            for (var index = 0; index < filtered.length; index++) {
              children.add(_livePostCard(filtered[index]));
              final postNumber = index + 1;
              final dueAds = ads
                  .where((ad) => postNumber % _promotionFrequency(ad) == 0)
                  .toList();
              if (dueAds.isNotEmpty) {
                children.add(
                  _promotionCard(dueAds[(postNumber - 1) % dueAds.length]),
                );
              }
            }
            final feed = Column(children: children);
            return isDesktop
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: feed),
                      const SizedBox(width: 24),
                      SizedBox(width: 290, child: _buildSidebar()),
                    ],
                  )
                : feed;
          },
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _loadActiveInFeedAds() async {
    final adsSettings = await FirebaseFirestore.instance
        .collection('settings')
        .doc('ads')
        .get();
    final settings = adsSettings.data() ?? const <String, dynamic>{};
    if (settings['showAds'] == false || settings['enableInFeedAds'] == false)
      return [];
    final snapshot = await FirebaseFirestore.instance
        .collection('promotions')
        .where('status', isEqualTo: 'approved')
        .limit(30)
        .get();
    final items = snapshot.docs.map((doc) => doc.data()).toList();
    return ViyouPromotionHelper.filterApprovedPromotions(
      items,
      type: 'external',
      category: _selectedCategory == 'All' ? null : _selectedCategory,
    );
  }

  int _promotionFrequency(Map<String, dynamic> ad) {
    final value = (ad['frequency'] ?? ad['promoFrequency']) as num?;
    final frequency = value?.toInt() ?? 4;
    return frequency.clamp(1, 4);
  }

  Future<Map<String, dynamic>?> _loadActiveBlogAd(String category) async {
    final settings =
        (await FirebaseFirestore.instance
                .collection('settings')
                .doc('ads')
                .get())
            .data();
    if (settings?['showAds'] == false) return null;
    final snapshot = await FirebaseFirestore.instance
        .collection('promotions')
        .where('status', isEqualTo: 'approved')
        .limit(30)
        .get();
    final items = snapshot.docs.map((doc) => doc.data()).toList();
    final matches = ViyouPromotionHelper.filterApprovedPromotions(
      items,
      type: 'blog_ad',
      category: category,
    );
    return matches.isEmpty ? null : matches.first;
  }

  Widget _promotionCard(Map<String, dynamic> ad) => Card(
    clipBehavior: Clip.antiAlias,
    color: const Color(0xff1b1724),
    child: InkWell(
      onTap: () {
        final url = ad['targetUrl'];
        if (url is String) _openWebsite(url);
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: _promotionMedia(ad),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(
                        Icons.storefront_outlined,
                        color: Color(0xff87ceeb),
                        size: 19,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'External Sponsor',
                        style: TextStyle(
                          color: Color(0xff87ceeb),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Ad • Every ${_promotionFrequency(ad)} post${_promotionFrequency(ad) == 1 ? '' : 's'}',
                        style: TextStyle(color: Colors.grey[500], fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${ad['title'] ?? 'Sponsored'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Sponsored content',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.open_in_new, size: 20),
          ],
        ),
      ),
    ),
  );

  Widget _promotionMedia(Map<String, dynamic> ad) {
    final media = [ad['mediaData'], ad['image'], ad['imageUrl'], ad['mediaUrl']]
        .whereType<String>()
        .firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
    if (media.startsWith('data:image/')) {
      final comma = media.indexOf(',');
      if (comma > 0) {
        try {
          return Image.memory(
            base64Decode(media.substring(comma + 1)),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _promotionPlaceholder(),
          );
        } catch (_) {
          return _promotionPlaceholder();
        }
      }
    }
    if (media.startsWith('http://') || media.startsWith('https://')) {
      return Image.network(
        media,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _promotionPlaceholder(),
      );
    }
    return _promotionPlaceholder();
  }

  Widget _promotionPlaceholder() => const ColoredBox(
    color: Color(0xff2a2035),
    child: Center(
      child: Icon(Icons.campaign_outlined, color: Color(0xfff59e0b)),
    ),
  );

  Widget _buildFlickSuggestions() => FutureBuilder<List<BlogRecord>>(
    future: _flicksFuture,
    builder: (context, snapshot) {
      final flicks = snapshot.data ?? const <BlogRecord>[];
      if (flicks.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            'Flicks for you',
            Icons.bolt_rounded,
            const Color(0xffff0050),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: flicks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) =>
                  _flickSuggestionCard(flicks[index]),
            ),
          ),
          const SizedBox(height: 22),
        ],
      );
    },
  );

  Widget _flickSuggestionCard(BlogRecord flick) {
    final preview = flick.primaryImage;
    return GestureDetector(
      onTap: () => _openFlickInFeed(flick),
      child: SizedBox(
        width: 142,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_isImageSource(preview))
                      _imageSource(preview, fit: BoxFit.cover)
                    else
                      Container(
                        color: const Color(0xff202020),
                        child: const Icon(
                          Icons.bolt_rounded,
                          color: Color(0xffff0050),
                          size: 34,
                        ),
                      ),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.15),
                            Colors.black.withValues(alpha: 0.7),
                          ],
                        ),
                      ),
                    ),
                    const Positioned(
                      right: 8,
                      bottom: 8,
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              flick.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFlickInFeed(BlogRecord flick) async {
    final flicks = await _flicksFuture;
    final index = flicks.indexWhere((item) => item.id == flick.id);
    if (!mounted || index < 0) return;
    setState(() {
      _selectedTab = 1;
      _currentFlickIndex = index;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _flicksPageController.hasClients) {
        _flicksPageController.jumpToPage(index);
      }
    });
  }

  Widget _emptyState(String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 42),
    child: Center(
      child: Text(message, style: TextStyle(color: Colors.grey[500])),
    ),
  );

  bool _isImageSource(String? source) =>
      source != null &&
      (source.startsWith('http://') ||
          source.startsWith('https://') ||
          source.startsWith('data:image/'));

  Widget _imageSource(String? source, {BoxFit fit = BoxFit.cover}) {
    if (source == null || source.isEmpty) return _mediaFallback(false);
    if (source.startsWith('data:image/')) {
      final comma = source.indexOf(',');
      if (comma > 0) {
        try {
          return Image.memory(
            base64Decode(source.substring(comma + 1)),
            fit: fit,
            errorBuilder: (_, __, ___) => _mediaFallback(false),
          );
        } catch (_) {
          return _mediaFallback(false);
        }
      }
    }
    return Image.network(
      source,
      fit: fit,
      errorBuilder: (_, __, ___) => _mediaFallback(false),
    );
  }

  String _formatUploadAge(DateTime date) {
    final age = DateTime.now().difference(date);
    if (age.inMinutes < 1) return 'Just now';
    if (age.inHours < 1) return '${age.inMinutes} minutes ago';
    if (age.inDays < 1) return '${age.inHours} hours ago';
    if (age.inDays < 30) return '${age.inDays} days ago';
    if (age.inDays < 365) return '${age.inDays ~/ 30} months ago';
    return '${age.inDays ~/ 365} years ago';
  }

  Widget _livePostCard(BlogRecord blog) {
    final media = blog.primaryImage;
    final hasImage = _isImageSource(media);
    final hasVideo = blog.video != null || blog.youtubeUrl != null;
    final isLiked = _likedBlogIds.contains(blog.id) || blog.isLiked;
    final likeCount = _likeCounts[blog.id] ?? blog.likesCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: GestureDetector(
        onTap: () => blog.video != null || blog.youtubeUrl != null
            ? _openVideo(blog)
            : _showBlogDetail(blog),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xff101010),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: .06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 21,
                    backgroundImage: blog.authorPhoto == null
                        ? null
                        : NetworkImage(blog.authorPhoto!),
                    child: blog.authorPhoto == null
                        ? Text(blog.author[0])
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          blog.author,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '${blog.category} • ${_formatUploadAge(blog.date)}',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: blog.authorUid == null
                        ? null
                        : () => _openPublicProfile(blog.authorUid!),
                    icon: const Icon(Icons.person_outline_rounded),
                    tooltip: 'Profile',
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                blog.title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (hasImage) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _BlogImageCarousel(images: blog.imageSources),
                ),
              ],
              if (!hasImage && blog.video != null) ...[
                const SizedBox(height: 12),
                _VideoFramePreview(url: blog.video!),
              ],
              if (blog.content.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  blog.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.grey[300], height: 1.4),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  if (hasVideo) ...[
                    const Icon(Icons.visibility_outlined, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '${blog.viewsCount} views',
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                  ] else ...[
                    IconButton(
                      onPressed: () => _toggleBlogLike(blog),
                      icon: Icon(
                        isLiked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: isLiked ? Colors.redAccent : null,
                        size: 20,
                      ),
                      tooltip: 'Like',
                    ),
                    Text(
                      '$likeCount',
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                  ],
                  const SizedBox(width: 18),
                  const Icon(Icons.mode_comment_outlined, size: 20),
                  const SizedBox(width: 6),
                  Text(
                    '${blog.commentsCount}',
                    style: TextStyle(color: Colors.grey[400]),
                  ),
                  IconButton(
                    onPressed: () => _savePostToPlaylist(blog),
                    icon: const Icon(Icons.playlist_add_rounded, size: 21),
                    tooltip: 'Save to playlist',
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => _copyPostLink(blog),
                    icon: const Icon(Icons.share_outlined, size: 20),
                    tooltip: 'Share',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openPublicProfile(String uid) async {
    final userSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    final postsSnapshot = await FirebaseFirestore.instance
        .collection('blogs')
        .where('authorUid', isEqualTo: uid)
        .where('status', isEqualTo: 'published')
        .limit(30)
        .get();
    if (!mounted) return;
    final profile = UserProfile.fromDocument(
      userSnapshot,
      FirebaseAuth.instance.currentUser,
      postsSnapshot.docs.map(BlogRecord.fromDocument).toList(),
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ViyouPublicProfilePage(profile: profile),
      ),
    );
  }

  Future<void> _showBlogDetail(BlogRecord blog) async {
    final media = blog.primaryImage;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xff101010),
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .82,
        maxChildSize: .95,
        builder: (_, controller) => FutureBuilder<Map<String, dynamic>?>(
          future: _loadActiveBlogAd(blog.category),
          builder: (context, adSnapshot) {
            final ad = adSnapshot.data;
            return ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[700],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  blog.title,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${blog.author}  •  ${blog.category}',
                  style: TextStyle(color: Colors.grey[500]),
                ),
                if (_isImageSource(media)) ...[
                  const SizedBox(height: 18),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _BlogImageCarousel(images: blog.imageSources),
                  ),
                ],
                const SizedBox(height: 18),
                Text(
                  blog.content.isEmpty
                      ? 'No description available.'
                      : blog.content,
                  style: const TextStyle(fontSize: 16, height: 1.55),
                ),
                if (ad != null) ...[
                  const SizedBox(height: 20),
                  _brandSponsoredArticleCard(ad),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    IconButton(
                      onPressed: () => _toggleBlogLike(blog),
                      icon: const Icon(Icons.favorite_border_rounded),
                      tooltip: 'Like',
                    ),
                    const SizedBox(width: 8),
                    Text('${blog.likesCount} likes'),
                    const SizedBox(width: 20),
                    const Icon(Icons.mode_comment_outlined),
                    const SizedBox(width: 8),
                    Text('${blog.commentsCount} comments'),
                  ],
                ),
                const SizedBox(height: 20),
                BlogComments(blog: blog),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _brandSponsoredArticleCard(Map<String, dynamic> ad) => Card(
    color: const Color(0xff1c1b2a),
    child: InkWell(
      onTap: () {
        final url = ad['targetUrl'];
        if (url is String && url.isNotEmpty) _openWebsite(url);
      },
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 92,
                height: 92,
                child: _sponsoredAdImage(ad),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sponsored',
                    style: TextStyle(
                      color: Color(0xfff59e0b),
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${ad['title'] ?? 'Brand promotion'}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${ad['targetCategories'] ?? 'All categories'}',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_outward_rounded),
          ],
        ),
      ),
    ),
  );

  Widget _sponsoredAdImage(Map<String, dynamic> ad) {
    final media = ad['mediaData'];
    if (media is String &&
        (media.startsWith('http://') ||
            media.startsWith('https://') ||
            media.startsWith('data:image/'))) {
      if (media.startsWith('data:image/')) {
        final comma = media.indexOf(',');
        if (comma > 0) {
          return Image.memory(
            base64Decode(media.substring(comma + 1)),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.campaign_outlined),
          );
        }
      }
      return Image.network(
        media,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.campaign_outlined),
      );
    }
    if (media is String && media.startsWith('data:image/')) {
      final comma = media.indexOf(',');
      if (comma > 0) {
        return Image.memory(
          base64Decode(media.substring(comma + 1)),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Icon(Icons.campaign_outlined),
        );
      }
    }
    return const ColoredBox(
      color: Color(0xff202020),
      child: Icon(Icons.campaign_outlined, size: 40),
    );
  }

  Future<void> _toggleBlogLike(BlogRecord blog) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showMessage(context, 'Please login to like this post');
      return;
    }
    final liked = _likedBlogIds.contains(blog.id) || blog.isLiked;
    final previousCount = _likeCounts[blog.id] ?? blog.likesCount;
    final nextCount = (previousCount + (liked ? -1 : 1)).clamp(0, 1 << 30);
    if (mounted) {
      setState(() {
        _likeCounts[blog.id] = nextCount;
        if (liked) {
          _likedBlogIds.remove(blog.id);
        } else {
          _likedBlogIds.add(blog.id);
        }
      });
    }
    try {
      await FirebaseFirestore.instance.collection('blogs').doc(blog.id).update({
        'likes': liked
            ? FieldValue.arrayRemove([user.uid])
            : FieldValue.arrayUnion([user.uid]),
      });
      if (mounted) _showMessage(context, liked ? 'Like removed' : 'Post liked');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _likeCounts[blog.id] = previousCount;
        if (liked) {
          _likedBlogIds.add(blog.id);
        } else {
          _likedBlogIds.remove(blog.id);
        }
      });
      _showMessage(context, 'Like update failed. Please try again.');
    }
  }

  Widget _mediaFallback(bool isFlicker) => AspectRatio(
    aspectRatio: isFlicker ? 9 / 16 : 16 / 9,
    child: Container(
      color: const Color(0xff202020),
      child: const Icon(Icons.image_not_supported_outlined, size: 46),
    ),
  );

  Future<List<List<Map<String, dynamic>>>> _loadStoryGroups() async {
    final now = DateTime.now();
    final currentUser = FirebaseAuth.instance.currentUser;
    final currentUserUid = currentUser?.uid;
    String currentUserName = 'You';
    String? currentUserPhoto;

    if (currentUserUid == null) {
      return const <List<Map<String, dynamic>>>[];
    }

    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUserUid)
        .get();
    final userData = userDoc.data() ?? const <String, dynamic>{};
    currentUserName =
        '${userData['name'] ?? currentUser?.displayName ?? 'You'}';
    currentUserPhoto = userData['photoURL'] as String? ?? currentUser?.photoURL;
    final following = List<String>.from(
      userData['following'] ?? const <dynamic>[],
    );
    final allowedUids = <String>{currentUserUid, ...following};

    final snapshot = await FirebaseFirestore.instance
        .collection('stories')
        .orderBy('timestamp', descending: true)
        .limit(200)
        .get();

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final authorUid = '${data['authorUid'] ?? ''}';
      if (authorUid.isEmpty || !allowedUids.contains(authorUid)) continue;

      final timestampValue = data['timestamp'];
      DateTime? timestamp;
      if (timestampValue is Timestamp) {
        timestamp = timestampValue.toDate();
      } else if (timestampValue is String) {
        timestamp = DateTime.tryParse(timestampValue);
      }
      if (timestamp == null) continue;
      if (now.difference(timestamp).inHours > 24) continue;

      groups.putIfAbsent(authorUid, () => <Map<String, dynamic>>[]).add({
        'id': doc.id,
        ...data,
      });
    }

    final orderedGroups = groups.values.toList();
    for (final group in orderedGroups) {
      group.sort((a, b) {
        final aTime = a['timestamp'] is Timestamp
            ? (a['timestamp'] as Timestamp).toDate()
            : DateTime.tryParse('${a['timestamp'] ?? ''}') ?? DateTime(1970);
        final bTime = b['timestamp'] is Timestamp
            ? (b['timestamp'] as Timestamp).toDate()
            : DateTime.tryParse('${b['timestamp'] ?? ''}') ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });
    }

    orderedGroups.sort((a, b) {
      final aTime = a.first['timestamp'] is Timestamp
          ? (a.first['timestamp'] as Timestamp).toDate()
          : DateTime.tryParse('${a.first['timestamp'] ?? ''}') ??
                DateTime(1970);
      final bTime = b.first['timestamp'] is Timestamp
          ? (b.first['timestamp'] as Timestamp).toDate()
          : DateTime.tryParse('${b.first['timestamp'] ?? ''}') ??
                DateTime(1970);
      return bTime.compareTo(aTime);
    });

    final ownerGroup = groups[currentUserUid];
    final otherGroups = orderedGroups
        .where((group) => '${group.first['authorUid'] ?? ''}' != currentUserUid)
        .toList();

    if (ownerGroup != null) {
      final ownerList = [...ownerGroup];
      ownerList.sort((a, b) {
        final aTime = a['timestamp'] is Timestamp
            ? (a['timestamp'] as Timestamp).toDate()
            : DateTime.tryParse('${a['timestamp'] ?? ''}') ?? DateTime(1970);
        final bTime = b['timestamp'] is Timestamp
            ? (b['timestamp'] as Timestamp).toDate()
            : DateTime.tryParse('${b['timestamp'] ?? ''}') ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });
      return [ownerList, ...otherGroups];
    }

    return [
      [
        {
          'id': 'owner-placeholder',
          'authorUid': currentUserUid,
          'authorName': currentUserName,
          'authorPhoto': currentUserPhoto,
          'status': 'empty',
          'timestamp': Timestamp.fromDate(now),
          'statusMessage': '',
          'storyText': '',
        },
      ],
      ...otherGroups,
    ];
  }

  bool _isStorySeenByCurrentUser(Map<String, dynamic> story) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    final seenBy = story['seenBy'];
    if (seenBy is List) {
      return seenBy.any((item) => item == uid);
    }
    return false;
  }

  Future<void> _markStoryAsSeen(String storyId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || storyId.isEmpty) return;
    try {
      final ref = FirebaseFirestore.instance.collection('stories').doc(storyId);
      final snapshot = await ref.get();
      final seenBy = snapshot.data()?['seenBy'] as List? ?? const <dynamic>[];
      if (seenBy.contains(uid)) return;
      await ref.update({
        'seenBy': FieldValue.arrayUnion([uid]),
      });
    } catch (_) {
      // safe no-op to keep the UX smooth even if Firestore update fails
    }
  }

  Future<bool> _userHasActiveStory(String userId) async {
    if (userId.isEmpty) return false;
    final snapshot = await FirebaseFirestore.instance
        .collection('stories')
        .where('authorUid', isEqualTo: userId)
        .orderBy('timestamp', descending: true)
        .limit(10)
        .get();

    final now = DateTime.now();
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final timestampValue = data['timestamp'];
      DateTime? timestamp;
      if (timestampValue is Timestamp) {
        timestamp = timestampValue.toDate();
      } else if (timestampValue is String) {
        timestamp = DateTime.tryParse(timestampValue);
      }
      if (timestamp != null && now.difference(timestamp).inHours <= 24) {
        return true;
      }
    }
    return false;
  }

  Future<void> _showCreateStorySheet() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await _showAuthDialog();
      return;
    }

    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final userData = userDoc.data() ?? const <String, dynamic>{};
    final authorName = userData['name'] ?? user.displayName ?? 'Creator';
    final authorPhoto = userData['photoURL'] ?? user.photoURL;

    final picker = ImagePicker();
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xff121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Create story',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.text_fields_rounded),
              title: const Text('Text story'),
              onTap: () => Navigator.pop(sheetContext, 'text'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Photo story'),
              onTap: () => Navigator.pop(sheetContext, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Video story'),
              onTap: () => Navigator.pop(sheetContext, 'video'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;

    String? mediaUrl;
    String? storyText;
    int storyBackgroundColor = const Color(0xff1f2937).value;
    int storyTextColor = 0xffffffff;
    double storyTextSize = 22;
    List<Map<String, dynamic>> textStickers = <Map<String, dynamic>>[];
    final List<Color> palette = [
      const Color(0xff1f2937),
      const Color(0xff111827),
      const Color(0xff7c3aed),
      const Color(0xff0f766e),
      const Color(0xfff59e0b),
      const Color(0xffef4444),
      const Color(0xff2563eb),
      const Color(0xffdb2777),
      const Color(0xffffffff),
      const Color(0xfffacc15),
    ];
    final List<String> emojiList = const ['✨', '❤️', '🎉', '🔥', '🌟', '🚀'];

    try {
      if (result == 'text') {
        final textResult = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (dialogContext) {
            final controller = TextEditingController();
            Color selectedColor = const Color(0xff1f2937);
            Color selectedTextColor = const Color(0xffffffff);
            String selectedFont = 'Bold';
            String selectedEffect = 'Glow';
            double fontSize = 30;
            String activeTool = 'text';

            return Dialog.fullscreen(
              child: StatefulBuilder(
                builder: (context, setState) {
                  return Scaffold(
                    backgroundColor: selectedColor,
                    body: SafeArea(
                      child: Row(
                        children: [
                          Container(
                            width: 110,
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            color: Colors.black.withValues(alpha: 0.2),
                            child: Column(
                              children: [
                                IconButton(
                                  onPressed: () => Navigator.pop(dialogContext),
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _storyToolButton(
                                  icon: Icons.text_fields_rounded,
                                  label: 'Aa',
                                  active: activeTool == 'text',
                                  onTap: () =>
                                      setState(() => activeTool = 'text'),
                                ),
                                const SizedBox(height: 10),
                                _storyToolButton(
                                  icon: Icons.emoji_emotions_outlined,
                                  label: '😊',
                                  active: activeTool == 'emoji',
                                  onTap: () =>
                                      setState(() => activeTool = 'emoji'),
                                ),
                                const SizedBox(height: 10),
                                _storyToolButton(
                                  icon: Icons.palette_outlined,
                                  label: '🎨',
                                  active: activeTool == 'style',
                                  onTap: () =>
                                      setState(() => activeTool = 'style'),
                                ),
                                const Spacer(),
                                FilledButton(
                                  onPressed: () {
                                    final value = controller.text.trim();
                                    if (value.isEmpty) return;
                                    Navigator.pop(dialogContext, {
                                      'text': value,
                                      'backgroundColor': selectedColor.value,
                                      'textColor': selectedTextColor.value,
                                      'fontSize': fontSize,
                                      'fontStyle': selectedFont,
                                      'effect': selectedEffect,
                                    });
                                  },
                                  child: const Text('Post'),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                Expanded(
                                  child: Container(
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.all(18),
                                    child: Text(
                                      controller.text.trim().isEmpty
                                          ? 'Tap on the left to add text'
                                          : controller.text.trim(),
                                      textAlign: TextAlign.center,
                                      maxLines: 12,
                                      style: TextStyle(
                                        color: selectedTextColor,
                                        fontSize: fontSize,
                                        fontWeight: selectedFont == 'Bold'
                                            ? FontWeight.w800
                                            : (selectedFont == 'Italic'
                                                  ? FontWeight.w500
                                                  : FontWeight.w700),
                                        fontStyle: selectedFont == 'Italic'
                                            ? FontStyle.italic
                                            : FontStyle.normal,
                                        letterSpacing: selectedFont == 'Classic'
                                            ? 0.4
                                            : 0.0,
                                        shadows: selectedEffect == 'Glow'
                                            ? const [
                                                Shadow(
                                                  color: Colors.black38,
                                                  blurRadius: 18,
                                                  offset: Offset(0, 2),
                                                ),
                                              ]
                                            : null,
                                      ),
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    10,
                                    12,
                                    14,
                                  ),
                                  color: Colors.black.withValues(alpha: 0.18),
                                  child: Column(
                                    children: [
                                      if (activeTool == 'text')
                                        TextField(
                                          controller: controller,
                                          maxLines: 5,
                                          textAlign: TextAlign.center,
                                          onChanged: (_) => setState(() {}),
                                          style: TextStyle(
                                            color: selectedTextColor,
                                            fontSize: fontSize,
                                            fontWeight: FontWeight.w700,
                                          ),
                                          decoration: InputDecoration(
                                            filled: true,
                                            fillColor: Colors.black.withValues(
                                              alpha: 0.18,
                                            ),
                                            hintText: 'Write your story',
                                            hintStyle: TextStyle(
                                              color: selectedTextColor
                                                  .withValues(alpha: 0.7),
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                              borderSide: BorderSide.none,
                                            ),
                                          ),
                                        ),
                                      if (activeTool == 'emoji')
                                        Wrap(
                                          spacing: 10,
                                          runSpacing: 10,
                                          children: emojiList.map((emoji) {
                                            return GestureDetector(
                                              onTap: () {
                                                final value = controller.text
                                                    .trim();
                                                controller.text = value.isEmpty
                                                    ? emoji
                                                    : '$value $emoji';
                                                controller.selection =
                                                    TextSelection.fromPosition(
                                                      TextPosition(
                                                        offset: controller
                                                            .text
                                                            .length,
                                                      ),
                                                    );
                                                setState(() {});
                                              },
                                              child: Text(
                                                emoji,
                                                style: const TextStyle(
                                                  fontSize: 28,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      if (activeTool == 'style')
                                        Column(
                                          children: [
                                            Row(
                                              children: [
                                                const Text('Style'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: SingleChildScrollView(
                                                    scrollDirection:
                                                        Axis.horizontal,
                                                    child: Row(
                                                      children:
                                                          [
                                                            'Classic',
                                                            'Bold',
                                                            'Italic',
                                                          ].map((style) {
                                                            final active =
                                                                selectedFont ==
                                                                style;
                                                            return Padding(
                                                              padding:
                                                                  const EdgeInsets.only(
                                                                    right: 8,
                                                                  ),
                                                              child: ChoiceChip(
                                                                label: Text(
                                                                  style,
                                                                ),
                                                                selected:
                                                                    active,
                                                                onSelected: (_) =>
                                                                    setState(
                                                                      () => selectedFont =
                                                                          style,
                                                                    ),
                                                                selectedColor:
                                                                    const Color(
                                                                      0xfff59e0b,
                                                                    ),
                                                              ),
                                                            );
                                                          }).toList(),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Text('Effect'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: SingleChildScrollView(
                                                    scrollDirection:
                                                        Axis.horizontal,
                                                    child: Row(
                                                      children:
                                                          [
                                                            'Glow',
                                                            'Bounce',
                                                            'None',
                                                          ].map((effect) {
                                                            final active =
                                                                selectedEffect ==
                                                                effect;
                                                            return Padding(
                                                              padding:
                                                                  const EdgeInsets.only(
                                                                    right: 8,
                                                                  ),
                                                              child: ChoiceChip(
                                                                label: Text(
                                                                  effect,
                                                                ),
                                                                selected:
                                                                    active,
                                                                onSelected: (_) =>
                                                                    setState(
                                                                      () => selectedEffect =
                                                                          effect,
                                                                    ),
                                                                selectedColor:
                                                                    const Color(
                                                                      0xff8b5cf6,
                                                                    ),
                                                              ),
                                                            );
                                                          }).toList(),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Text('Size'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Slider(
                                                    min: 18,
                                                    max: 48,
                                                    value: fontSize,
                                                    activeColor: const Color(
                                                      0xfff59e0b,
                                                    ),
                                                    onChanged: (value) =>
                                                        setState(
                                                          () =>
                                                              fontSize = value,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Text('Text color'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Wrap(
                                                    spacing: 8,
                                                    runSpacing: 8,
                                                    children: palette.map((
                                                      color,
                                                    ) {
                                                      final active =
                                                          selectedTextColor ==
                                                          color;
                                                      return GestureDetector(
                                                        onTap: () => setState(
                                                          () =>
                                                              selectedTextColor =
                                                                  color,
                                                        ),
                                                        child: Container(
                                                          width: 28,
                                                          height: 28,
                                                          decoration: BoxDecoration(
                                                            color: color,
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  8,
                                                                ),
                                                            border: Border.all(
                                                              color: active
                                                                  ? Colors.white
                                                                  : Colors
                                                                        .transparent,
                                                              width: 2,
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    }).toList(),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Text('Background'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Wrap(
                                                    spacing: 8,
                                                    runSpacing: 8,
                                                    children: palette.map((
                                                      color,
                                                    ) {
                                                      final active =
                                                          selectedColor ==
                                                          color;
                                                      return GestureDetector(
                                                        onTap: () => setState(
                                                          () => selectedColor =
                                                              color,
                                                        ),
                                                        child: Container(
                                                          width: 28,
                                                          height: 28,
                                                          decoration: BoxDecoration(
                                                            color: color,
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  8,
                                                                ),
                                                            border: Border.all(
                                                              color: active
                                                                  ? Colors.white
                                                                  : Colors
                                                                        .transparent,
                                                              width: 2,
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    }).toList(),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
        if (textResult == null) return;
        storyText = textResult['text'] as String?;
        storyBackgroundColor =
            (textResult['backgroundColor'] as int?) ??
            const Color(0xff1f2937).value;
        storyTextColor = (textResult['textColor'] as int?) ?? 0xffffffff;
        storyTextSize = (textResult['fontSize'] as num?)?.toDouble() ?? 22;
        if (storyText == null || storyText.isEmpty) return;
      } else {
        final media = result == 'image'
            ? await _pickImageWithCameraChoice(
                context,
                purpose: 'capture a story photo',
              )
            : await picker.pickVideo(source: ImageSource.gallery);
        if (media == null) return;

        final mediaBytes = await media.readAsBytes();

        final editorResult = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (previewContext) {
            final defaultText = 'Tap to add text';
            final canvasKey = GlobalKey();
            final textController = TextEditingController();
            List<Map<String, dynamic>> stickers = <Map<String, dynamic>>[];
            Color selectedColor = const Color(0xff101827);
            Color selectedTextColor = const Color(0xffffffff);
            String selectedFont = 'Bold';
            String selectedEffect = 'Glow';
            double fontSize = 30;
            String activeTool = 'text';
            int selectedStickerIndex = -1;

            Future<void> showPreview() async {
              final preview = await showDialog<Map<String, dynamic>>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: const Color(0xff111827),
                  title: const Text('Preview story'),
                  content: SizedBox(
                    width: 280,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 220,
                          height: 360,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            color: selectedColor,
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: result == 'image'
                                    ? Image.memory(
                                        mediaBytes,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(
                                        color: const Color(0xff111827),
                                        child: const Center(
                                          child: Icon(
                                            Icons.videocam_outlined,
                                            size: 64,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ),
                              ),
                              ...stickers.asMap().entries.map((entry) {
                                final sticker = entry.value;
                                final color = Color(sticker['color'] as int);
                                final scale =
                                    (sticker['scale'] as num?)?.toDouble() ??
                                    1.0;
                                final style = sticker['fontStyle'] as String;
                                final effect = sticker['effect'] as String;
                                final text = sticker['text'] as String;
                                return Positioned(
                                  left: (sticker['x'] as double) * 170,
                                  top: (sticker['y'] as double) * 250,
                                  child: Transform.scale(
                                    scale: scale,
                                    child: Text(
                                      text,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: color,
                                        fontSize: (sticker['fontSize'] as num)
                                            .toDouble(),
                                        fontWeight: style == 'Bold'
                                            ? FontWeight.w800
                                            : (style == 'Italic'
                                                  ? FontWeight.w500
                                                  : FontWeight.w700),
                                        fontStyle: style == 'Italic'
                                            ? FontStyle.italic
                                            : FontStyle.normal,
                                        shadows: effect == 'Glow'
                                            ? const [
                                                Shadow(
                                                  color: Colors.black38,
                                                  blurRadius: 14,
                                                  offset: Offset(0, 2),
                                                ),
                                              ]
                                            : null,
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                        if (stickers.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              stickers
                                  .map((item) => item['text'] as String)
                                  .join('\n'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, null),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, {
                        'text': stickers
                            .map((item) => item['text'] as String)
                            .join('\n'),
                        'backgroundColor': selectedColor.value,
                        'textColor': selectedTextColor.value,
                        'fontSize': fontSize,
                        'mediaBytes': mediaBytes,
                        'storyStickers': stickers,
                      }),
                      child: const Text('Publish'),
                    ),
                  ],
                ),
              );
              if (preview == null) return;
              Navigator.pop(previewContext, preview);
            }

            return Dialog.fullscreen(
              child: StatefulBuilder(
                builder: (context, setState) {
                  void addSticker(String text, {bool isEmoji = false}) {
                    final box =
                        canvasKey.currentContext?.findRenderObject()
                            as RenderBox?;
                    final size = box?.size ?? const Size(300, 500);
                    final x = size.width > 0 ? 0.5 : 0.5;
                    final y = size.height > 0 ? 0.5 : 0.5;
                    stickers.add({
                      'text': text,
                      'x': x,
                      'y': y,
                      'color': selectedTextColor.value,
                      'fontSize': fontSize,
                      'fontStyle': selectedFont,
                      'effect': selectedEffect,
                      'emoji': isEmoji,
                      'align': 'center',
                      'scale': 1.0,
                    });
                    selectedStickerIndex = stickers.length - 1;
                    setState(() {});
                  }

                  void addStickerAtPoint(Offset localPosition) {
                    final box =
                        canvasKey.currentContext?.findRenderObject()
                            as RenderBox?;
                    if (box == null) return;
                    final size = box.size;
                    final dx = (localPosition.dx / size.width).clamp(0.0, 1.0);
                    final dy = (localPosition.dy / size.height).clamp(0.0, 1.0);
                    stickers.add({
                      'text': activeTool == 'emoji' ? '✨' : 'Add text',
                      'x': dx,
                      'y': dy,
                      'color': selectedTextColor.value,
                      'fontSize': fontSize,
                      'fontStyle': selectedFont,
                      'effect': selectedEffect,
                      'emoji': activeTool == 'emoji',
                      'align': 'center',
                      'scale': 1.0,
                    });
                    selectedStickerIndex = stickers.length - 1;
                    setState(() {});
                  }

                  return Scaffold(
                    backgroundColor: selectedColor,
                    body: SafeArea(
                      child: Row(
                        children: [
                          Container(
                            width: 110,
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            color: Colors.black.withValues(alpha: 0.2),
                            child: Column(
                              children: [
                                IconButton(
                                  onPressed: () =>
                                      Navigator.pop(previewContext),
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _storyToolButton(
                                  icon: Icons.text_fields_rounded,
                                  label: 'Aa',
                                  active: activeTool == 'text',
                                  onTap: () =>
                                      setState(() => activeTool = 'text'),
                                ),
                                const SizedBox(height: 10),
                                _storyToolButton(
                                  icon: Icons.emoji_emotions_outlined,
                                  label: '😊',
                                  active: activeTool == 'emoji',
                                  onTap: () =>
                                      setState(() => activeTool = 'emoji'),
                                ),
                                const SizedBox(height: 10),
                                _storyToolButton(
                                  icon: Icons.palette_outlined,
                                  label: '🎨',
                                  active: activeTool == 'style',
                                  onTap: () =>
                                      setState(() => activeTool = 'style'),
                                ),
                                const Spacer(),
                                FilledButton(
                                  onPressed: showPreview,
                                  child: const Text('Post'),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                Expanded(
                                  child: Stack(
                                    key: canvasKey,
                                    children: [
                                      Positioned.fill(
                                        child: result == 'image'
                                            ? Image.memory(
                                                mediaBytes,
                                                fit: BoxFit.cover,
                                              )
                                            : Container(
                                                color: const Color(0xff111827),
                                                child: const Center(
                                                  child: Icon(
                                                    Icons.videocam_outlined,
                                                    size: 64,
                                                    color: Colors.white70,
                                                  ),
                                                ),
                                              ),
                                      ),
                                      Positioned.fill(
                                        child: GestureDetector(
                                          onTapDown: (details) {
                                            if (activeTool == 'text' ||
                                                activeTool == 'emoji') {
                                              addStickerAtPoint(
                                                details.localPosition,
                                              );
                                            }
                                          },
                                          child: Stack(
                                            children: stickers.asMap().entries.map((
                                              entry,
                                            ) {
                                              final index = entry.key;
                                              final sticker = entry.value;
                                              final isSelected =
                                                  index == selectedStickerIndex;
                                              final left =
                                                  (sticker['x'] as double) *
                                                  (MediaQuery.of(
                                                        context,
                                                      ).size.width -
                                                      120);
                                              final top =
                                                  (sticker['y'] as double) *
                                                  (MediaQuery.of(
                                                        context,
                                                      ).size.height -
                                                      180);
                                              final text =
                                                  sticker['text'] as String;
                                              final style =
                                                  sticker['fontStyle']
                                                      as String;
                                              final effect =
                                                  sticker['effect'] as String;
                                              final stickerFontSize =
                                                  (sticker['fontSize'] as num)
                                                      .toDouble();
                                              final scale =
                                                  (sticker['scale'] as num?)
                                                      ?.toDouble() ??
                                                  1.0;
                                              final color = Color(
                                                sticker['color'] as int,
                                              );
                                              final isEmoji =
                                                  sticker['emoji'] == true;

                                              return Positioned(
                                                left: left,
                                                top: top,
                                                child: GestureDetector(
                                                  onTap: () => setState(
                                                    () => selectedStickerIndex =
                                                        index,
                                                  ),
                                                  onPanUpdate: (event) {
                                                    final rect =
                                                        context.findRenderObject()
                                                            as RenderBox?;
                                                    if (rect == null) return;
                                                    final size = rect.size;
                                                    final dx =
                                                        ((left +
                                                                    event
                                                                        .delta
                                                                        .dx) /
                                                                size.width)
                                                            .clamp(0.0, 1.0);
                                                    final dy =
                                                        ((top +
                                                                    event
                                                                        .delta
                                                                        .dy) /
                                                                size.height)
                                                            .clamp(0.0, 1.0);
                                                    stickers[index]['x'] = dx;
                                                    stickers[index]['y'] = dy;
                                                    setState(() {});
                                                  },
                                                  child: Transform.scale(
                                                    scale: scale,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            6,
                                                          ),
                                                      decoration: isSelected
                                                          ? BoxDecoration(
                                                              border: Border.all(
                                                                color: Colors
                                                                    .white,
                                                                width: 2,
                                                              ),
                                                              borderRadius:
                                                                  BorderRadius.circular(
                                                                    10,
                                                                  ),
                                                            )
                                                          : null,
                                                      child: Text(
                                                        text,
                                                        textAlign:
                                                            TextAlign.center,
                                                        style: TextStyle(
                                                          color: color,
                                                          fontSize:
                                                              stickerFontSize,
                                                          fontWeight:
                                                              style == 'Bold'
                                                              ? FontWeight.w800
                                                              : (style ==
                                                                        'Italic'
                                                                    ? FontWeight
                                                                          .w500
                                                                    : FontWeight
                                                                          .w700),
                                                          fontStyle:
                                                              style == 'Italic'
                                                              ? FontStyle.italic
                                                              : FontStyle
                                                                    .normal,
                                                          letterSpacing: isEmoji
                                                              ? 0
                                                              : 0.5,
                                                          shadows:
                                                              effect == 'Glow'
                                                              ? const [
                                                                  Shadow(
                                                                    color: Colors
                                                                        .black38,
                                                                    blurRadius:
                                                                        16,
                                                                    offset:
                                                                        Offset(
                                                                          0,
                                                                          2,
                                                                        ),
                                                                  ),
                                                                ]
                                                              : null,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            }).toList(),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    10,
                                    12,
                                    14,
                                  ),
                                  color: Colors.black.withValues(alpha: 0.18),
                                  child: Column(
                                    children: [
                                      if (selectedStickerIndex >= 0) ...[
                                        Row(
                                          children: [
                                            const Text('Align'),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Row(
                                                children: [
                                                  _storyAlignButton(
                                                    'Left',
                                                    Icons.format_align_left,
                                                    () {
                                                      stickers[selectedStickerIndex]['align'] =
                                                          'left';
                                                      setState(() {});
                                                    },
                                                  ),
                                                  _storyAlignButton(
                                                    'Center',
                                                    Icons.format_align_center,
                                                    () {
                                                      stickers[selectedStickerIndex]['align'] =
                                                          'center';
                                                      setState(() {});
                                                    },
                                                  ),
                                                  _storyAlignButton(
                                                    'Right',
                                                    Icons.format_align_right,
                                                    () {
                                                      stickers[selectedStickerIndex]['align'] =
                                                          'right';
                                                      setState(() {});
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                            IconButton(
                                              onPressed: () {
                                                stickers.removeAt(
                                                  selectedStickerIndex,
                                                );
                                                selectedStickerIndex = -1;
                                                setState(() {});
                                              },
                                              icon: const Icon(
                                                Icons.delete_outline_rounded,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            const Text('Resize'),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Slider(
                                                min: 0.6,
                                                max: 1.8,
                                                value:
                                                    ((stickers[selectedStickerIndex]['scale']
                                                                as num?) ??
                                                            1.0)
                                                        .toDouble(),
                                                activeColor: const Color(
                                                  0xfff59e0b,
                                                ),
                                                onChanged: (value) {
                                                  stickers[selectedStickerIndex]['scale'] =
                                                      value;
                                                  setState(() {});
                                                },
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                      if (activeTool == 'text')
                                        TextField(
                                          controller: textController,
                                          decoration: InputDecoration(
                                            hintText: 'Type text on the story',
                                            filled: true,
                                            fillColor: Colors.black.withValues(
                                              alpha: 0.18,
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              borderSide: BorderSide.none,
                                            ),
                                          ),
                                          onSubmitted: (value) {
                                            if (value.trim().isEmpty) return;
                                            addSticker(value.trim());
                                            textController.clear();
                                          },
                                        ),
                                      if (activeTool == 'emoji')
                                        Wrap(
                                          spacing: 10,
                                          runSpacing: 10,
                                          children: emojiList.map((emoji) {
                                            return GestureDetector(
                                              onTap: () => addSticker(
                                                emoji,
                                                isEmoji: true,
                                              ),
                                              child: Text(
                                                emoji,
                                                style: const TextStyle(
                                                  fontSize: 28,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      if (activeTool == 'style')
                                        Column(
                                          children: [
                                            Row(
                                              children: [
                                                const Text('Style'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: SingleChildScrollView(
                                                    scrollDirection:
                                                        Axis.horizontal,
                                                    child: Row(
                                                      children:
                                                          [
                                                            'Classic',
                                                            'Bold',
                                                            'Italic',
                                                          ].map((style) {
                                                            final active =
                                                                selectedFont ==
                                                                style;
                                                            return Padding(
                                                              padding:
                                                                  const EdgeInsets.only(
                                                                    right: 8,
                                                                  ),
                                                              child: ChoiceChip(
                                                                label: Text(
                                                                  style,
                                                                ),
                                                                selected:
                                                                    active,
                                                                onSelected: (_) =>
                                                                    setState(
                                                                      () => selectedFont =
                                                                          style,
                                                                    ),
                                                                selectedColor:
                                                                    const Color(
                                                                      0xfff59e0b,
                                                                    ),
                                                              ),
                                                            );
                                                          }).toList(),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Text('Text color'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Wrap(
                                                    spacing: 8,
                                                    runSpacing: 8,
                                                    children: palette.map((
                                                      color,
                                                    ) {
                                                      final active =
                                                          selectedTextColor ==
                                                          color;
                                                      return GestureDetector(
                                                        onTap: () => setState(
                                                          () =>
                                                              selectedTextColor =
                                                                  color,
                                                        ),
                                                        child: Container(
                                                          width: 28,
                                                          height: 28,
                                                          decoration: BoxDecoration(
                                                            color: color,
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  8,
                                                                ),
                                                            border: Border.all(
                                                              color: active
                                                                  ? Colors.white
                                                                  : Colors
                                                                        .transparent,
                                                              width: 2,
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    }).toList(),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Text('Size'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Slider(
                                                    min: 18,
                                                    max: 54,
                                                    value: fontSize,
                                                    activeColor: const Color(
                                                      0xfff59e0b,
                                                    ),
                                                    onChanged: (value) =>
                                                        setState(
                                                          () =>
                                                              fontSize = value,
                                                        ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Text('Effect'),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: SingleChildScrollView(
                                                    scrollDirection:
                                                        Axis.horizontal,
                                                    child: Row(
                                                      children:
                                                          [
                                                            'Glow',
                                                            'Bounce',
                                                            'None',
                                                          ].map((effect) {
                                                            final active =
                                                                selectedEffect ==
                                                                effect;
                                                            return Padding(
                                                              padding:
                                                                  const EdgeInsets.only(
                                                                    right: 8,
                                                                  ),
                                                              child: ChoiceChip(
                                                                label: Text(
                                                                  effect,
                                                                ),
                                                                selected:
                                                                    active,
                                                                onSelected: (_) =>
                                                                    setState(
                                                                      () => selectedEffect =
                                                                          effect,
                                                                    ),
                                                                selectedColor:
                                                                    const Color(
                                                                      0xff8b5cf6,
                                                                    ),
                                                              ),
                                                            );
                                                          }).toList(),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
        if (editorResult == null) return;

        storyText = editorResult['text'] as String?;
        storyBackgroundColor =
            (editorResult['backgroundColor'] as int?) ??
            const Color(0xff111827).value;
        storyTextColor = (editorResult['textColor'] as int?) ?? 0xffffffff;
        storyTextSize = (editorResult['fontSize'] as num?)?.toDouble() ?? 26;
        textStickers =
            (editorResult['storyStickers'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];

        final storyMediaBytes = editorResult['mediaBytes'] as Uint8List?;
        if (storyMediaBytes == null || storyMediaBytes.isEmpty) {
          _showMessage(context, 'Story media is missing. Please try again.');
          return;
        }

        final storageRef = FirebaseStorage.instance.ref(
          'stories/${user.uid}_${DateTime.now().millisecondsSinceEpoch}_${media.name}',
        );
        await storageRef.putData(
          storyMediaBytes,
          SettableMetadata(
            contentType: result == 'image' ? 'image/jpeg' : 'video/mp4',
          ),
        );
        mediaUrl = await storageRef.getDownloadURL();
      }

      final serializedStickers = textStickers.isEmpty
          ? null
          : jsonEncode(textStickers);
      await FirebaseFirestore.instance.collection('stories').add({
        'authorUid': user.uid,
        'authorName': authorName,
        'authorPhoto': authorPhoto,
        'status': 'active',
        'timestamp': FieldValue.serverTimestamp(),
        'mediaType': result,
        'statusImage': result == 'image' ? mediaUrl : null,
        'statusVideo': result == 'video' ? mediaUrl : null,
        'statusMessage': storyText ?? null,
        'storyText': storyText ?? null,
        'storyBackgroundColor': storyBackgroundColor,
        'storyTextColor': storyTextColor,
        'storyTextSize': storyTextSize,
        'storyTextData': serializedStickers,
        'seenBy': const <String>[],
      });

      if (!mounted) return;
      setState(() {});
      _showMessage(context, 'Story published');
    } catch (error) {
      if (!mounted) return;
      _showMessage(context, 'Story upload failed. Please try again.');
    }
  }

  Future<void> _openStoryViewer(
    String authorUid,
    List<Map<String, dynamic>> stories, {
    int startIndex = 0,
  }) async {
    if (stories.isEmpty) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      for (final story in stories) {
        final storyId = '${story['id'] ?? ''}';
        if (storyId.isNotEmpty && story['authorUid'] != uid) {
          unawaited(_markStoryAsSeen(storyId));
        }
      }
    }
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => _StoryViewerDialog(
        authorUid: authorUid,
        stories: stories,
        initialIndex: startIndex,
      ),
    );
  }

  Widget _buildStories() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Stories',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (FirebaseAuth.instance.currentUser != null)
              IconButton(
                onPressed: _showCreateStorySheet,
                icon: const Icon(
                  Icons.add_circle_rounded,
                  color: Color(0xfff59e0b),
                ),
                tooltip: 'Add story',
              ),
          ],
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<List<Map<String, dynamic>>>>(
          future: _loadStoryGroups(),
          builder: (context, snapshot) {
            final groups =
                snapshot.data ?? const <List<Map<String, dynamic>>>[];
            if (groups.isEmpty) return _emptyState('No active stories');
            return SizedBox(
              height: 128,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: groups.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (context, index) {
                  final group = groups[index];
                  final authorUid = '${group.first['authorUid'] ?? ''}';
                  final name = '${group.first['authorName'] ?? 'Creator'}';
                  final photo = group.first['authorPhoto'] as String?;
                  final currentUserUid = FirebaseAuth.instance.currentUser?.uid;
                  final isCurrentUser = authorUid == currentUserUid;
                  final storyCount = group.length;
                  final hasStory =
                      storyCount > 0 &&
                      '${group.first['status'] ?? ''}' != 'empty';
                  final groupSeen = group.any(_isStorySeenByCurrentUser);

                  return GestureDetector(
                    onTap: () {
                      if (isCurrentUser && !hasStory) {
                        _showCreateStorySheet();
                        return;
                      }
                      if (group.isEmpty) {
                        _showCreateStorySheet();
                        return;
                      }
                      _openStoryViewer(authorUid, group, startIndex: 0);
                    },
                    child: SizedBox(
                      width: 82,
                      child: Column(
                        children: [
                          TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0.96, end: 1),
                            duration: const Duration(milliseconds: 650),
                            curve: Curves.elasticOut,
                            builder: (context, scale, child) {
                              return AnimatedScale(
                                scale: scale,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOutCubic,
                                child: child,
                              );
                            },
                            child: Stack(
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  padding: const EdgeInsets.all(2.25),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: groupSeen
                                        ? const LinearGradient(
                                            colors: [
                                              Color(0xff3a3a3a),
                                              Color(0xff6b7280),
                                              Color(0xff9ca3af),
                                            ],
                                          )
                                        : const LinearGradient(
                                            colors: [
                                              Color(0xfff59e0b),
                                              Color(0xffec4899),
                                              Color(0xff8b5cf6),
                                            ],
                                          ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: groupSeen
                                            ? Colors.grey.withValues(
                                                alpha: 0.18,
                                              )
                                            : Colors.purple.withValues(
                                                alpha: 0.32,
                                              ),
                                        blurRadius: hasStory ? 10 : 0,
                                        spreadRadius: hasStory ? 1.5 : 0,
                                      ),
                                    ],
                                  ),
                                  child: CircleAvatar(
                                    radius: 31,
                                    backgroundColor: const Color(0xff262626),
                                    backgroundImage:
                                        photo == null || photo.isEmpty
                                        ? null
                                        : NetworkImage(photo),
                                    child: photo == null || photo.isEmpty
                                        ? Text(
                                            name.isNotEmpty
                                                ? name[0].toUpperCase()
                                                : 'C',
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          )
                                        : null,
                                  ),
                                ),
                                if (isCurrentUser && !hasStory)
                                  Positioned(
                                    right: -2,
                                    bottom: 2,
                                    child: Container(
                                      width: 22,
                                      height: 22,
                                      decoration: const BoxDecoration(
                                        color: Color(0xfff59e0b),
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black54,
                                            blurRadius: 6,
                                            offset: Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: const Icon(
                                        Icons.add,
                                        size: 16,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: 72,
                            child: Text(
                              isCurrentUser ? 'Your Story' : name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _sectionTitle(String title, IconData icon, Color color) => Row(
    children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(width: 8),
      Text(
        title,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),
    ],
  );

  Widget _buildCategories() => SizedBox(
    height: 38,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _categories.length,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final category = _categories[index];
        final active = category == _selectedCategory;
        return ChoiceChip(
          label: Text(category),
          selected: active,
          onSelected: (_) => setState(() => _selectedCategory = category),
          selectedColor: const Color(0xff6366f1),
          backgroundColor: const Color(0xff151515),
          labelStyle: TextStyle(
            color: active ? Colors.white : Colors.grey[400],
            fontWeight: FontWeight.w600,
          ),
        );
      },
    ),
  );

  Widget _buildVideos() => FutureBuilder<List<BlogRecord>>(
    future: _videosFuture,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Center(child: CircularProgressIndicator());
      }
      final videos = snapshot.data ?? [];
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 24, 14, 100),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle(
                  'Videos',
                  Icons.play_circle_fill_rounded,
                  const Color(0xff6366f1),
                ),
                const SizedBox(height: 18),
                if (videos.isEmpty) _emptyState('No videos published yet'),
                ...videos.map(_videoCard),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _buildFlicks() => FutureBuilder<List<BlogRecord>>(
    future: _flicksFuture,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting)
        return const Center(child: CircularProgressIndicator());
      final flicks = snapshot.data ?? const <BlogRecord>[];
      if (flicks.isEmpty) {
        return _emptyState('No Flicks published yet');
      }
      return PageView.builder(
        controller: _flicksPageController,
        scrollDirection: Axis.vertical,
        itemCount: flicks.length,
        onPageChanged: (index) => setState(() => _currentFlickIndex = index),
        itemBuilder: (context, index) => _FlickPage(
          blog: flicks[index],
          isActive: index == _currentFlickIndex,
        ),
      );
    },
  );

  Widget _videoCard(BlogRecord video) {
    final image = video.primaryImage;
    return GestureDetector(
      onTap: () => _openVideo(video),
      child: Container(
        margin: const EdgeInsets.only(bottom: 18),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xff101010),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isImageSource(image))
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: _imageSource(image),
              ),
            if (!_isImageSource(image) && video.video != null)
              _VideoFramePreview(url: video.video!),
            const SizedBox(height: 12),
            Text(
              video.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              '${video.author}  •  ${video.category}',
              style: TextStyle(color: Colors.grey[500]),
            ),
            if (video.video != null || video.youtubeUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Video available in Viyou Watch',
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openVideo(BlogRecord video) async {
    if (hasPlayableMediaSource(video.video) ||
        hasPlayableMediaSource(video.youtubeUrl)) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => ViyouVideoPlayer(video: video)),
      );
      if (mounted) {
        setState(() {
          _videosFuture = _loadVideos();
          _blogsFuture = _loadBlogs();
        });
      }
      return;
    }
    _showMessage(context, 'This flick is not playable yet');
  }

  Future<void> _openWebsite(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      _showMessage(context, 'Unable to open this link');
    }
  }

  Future<void> _showUploadDialog() async {
    if (FirebaseAuth.instance.currentUser == null) {
      await _showAuthDialog();
      return;
    }

    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ViyouCreatePage(
          onPublished: () {
            setState(() {
              _blogsFuture = _loadBlogs();
              _videosFuture = _loadVideos();
              _flicksFuture = _loadFlicks();
              _profileFuture = _loadProfile();
            });
          },
        ),
      ),
    );
  }

  Widget _buildProfile() => FutureBuilder<UserProfile>(
    future: _profileFuture,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Center(child: CircularProgressIndicator());
      }
      final profile = snapshot.data ?? UserProfile.empty;
      final blogs = profile.postsList
          .where(
            (post) =>
                post.status == 'published' &&
                !post.isFlicker &&
                post.video == null,
          )
          .toList();
      final flicks = profile.postsList
          .where((post) => post.status == 'published' && post.isFlicker)
          .toList();
      final videos = profile.postsList
          .where(
            (post) =>
                post.status == 'published' &&
                !post.isFlicker &&
                post.video != null,
          )
          .toList();
      final tabs = [blogs, flicks, videos];
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 100),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            CircleAvatar(
                              radius: 46,
                              backgroundImage: profile.photoUrl == null
                                  ? null
                                  : NetworkImage(profile.photoUrl!),
                              child: profile.photoUrl == null
                                  ? Text(
                                      profile.name.isEmpty
                                          ? '?'
                                          : profile.name[0].toUpperCase(),
                                      style: const TextStyle(fontSize: 30),
                                    )
                                  : null,
                            ),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: Material(
                                color: const Color(0xfff59e0b),
                                shape: const CircleBorder(),
                                child: IconButton(
                                  onPressed: _changeProfilePhoto,
                                  icon: const Icon(
                                    Icons.camera_alt_outlined,
                                    color: Colors.black,
                                    size: 18,
                                  ),
                                  tooltip: 'Change profile photo',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  profile.name.isEmpty
                                      ? 'Viyou creator'
                                      : profile.name,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (profile.username.isNotEmpty)
                            Text(
                              '@${profile.username}',
                              style: TextStyle(color: Colors.grey[500]),
                            ),
                          if (profile.userId.isNotEmpty)
                            Text(
                              'ID: ${profile.userId}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 16,
                            runSpacing: 6,
                            children: [
                              Text('${profile.posts} Posts'),
                              InkWell(
                                onTap: () => _openConnections('followers'),
                                child: Text('${profile.followers} Followers'),
                              ),
                              InkWell(
                                onTap: () => _openConnections('following'),
                                child: Text('${profile.following} Following'),
                              ),
                            ],
                          ),
                          if (profile.bio.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              profile.bio,
                              style: TextStyle(color: Colors.grey[300]),
                            ),
                          ],
                          if (profile.email.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              profile.email,
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _profileActionChip(
                        icon: Icons.playlist_play_rounded,
                        label: 'Playlist',
                        onPressed: _createPlaylistFromProfile,
                      ),
                      const SizedBox(width: 8),
                      _profileActionChip(
                        icon: Icons.schedule_rounded,
                        label: 'Schedule',
                        onPressed: _showScheduledContent,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _profileTabChip(0, Icons.article_outlined, 'Blogs'),
                      _profileTabChip(1, Icons.bolt, 'Flicks'),
                      _profileTabChip(2, Icons.play_circle_outline, 'Videos'),
                      _profileTabChip(3, Icons.edit_note, 'Drafts'),
                      _profileTabChip(4, Icons.favorite_border, 'Liked'),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                if (_profileSection < 3 && tabs[_profileSection].isEmpty)
                  _emptyState(
                    _profileSection == 1
                        ? 'No flicks published yet'
                        : 'Nothing here yet',
                  ),
                if (_profileSection < 3)
                  ...tabs[_profileSection].map(_livePostCard),
                if (_profileSection == 3)
                  _profileCollection('draft', 'No drafts yet'),
                if (_profileSection == 4)
                  _profileCollection('liked', 'No liked videos yet'),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _profileCollection(String type, String emptyMessage) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return _emptyState('Please login to view this tab');
    final query = type == 'draft'
        ? FirebaseFirestore.instance
              .collection('blogs')
              .where('authorUid', isEqualTo: user.uid)
              .where('status', isEqualTo: 'draft')
              .limit(30)
        : FirebaseFirestore.instance
              .collection('blogs')
              .where('likes', arrayContains: user.uid)
              .limit(30);
    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: query.get(),
      builder: (context, snapshot) {
        final posts =
            snapshot.data?.docs
                .map(BlogRecord.fromDocument)
                .where(
                  (post) => type == 'draft'
                      ? post.status == 'draft'
                      : post.status == 'published',
                )
                .toList() ??
            [];
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        if (posts.isEmpty) return _emptyState(emptyMessage);
        return Column(children: posts.map(_livePostCard).toList());
      },
    );
  }

  Widget _buildMessages() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return _emptyState('Please login to view messages');
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('conversations')
          .where('participants', arrayContains: user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        final search = _messageSearchController.text.trim().toLowerCase();
        final conversations =
            (snapshot.data?.docs ?? []).where((conversation) {
              final data = conversation.data();
              final participants = List<String>.from(
                data['participants'] ?? const [],
              );
              final otherUid = participants.firstWhere(
                (id) => id != user.uid,
                orElse: () => '',
              );
              final details = Map<String, dynamic>.from(
                data['participantDetails'] ?? const {},
              );
              final other = Map<String, dynamic>.from(
                details[otherUid] ?? const {},
              );
              final last = Map<String, dynamic>.from(
                data['lastMessage'] ?? const {},
              );
              final searchable =
                  '${other['name'] ?? ''} ${other['username'] ?? ''} ${last['text'] ?? ''}'
                      .toLowerCase();
              return search.isEmpty || searchable.contains(search);
            }).toList()..sort((a, b) {
              final aLast = Map<String, dynamic>.from(
                a.data()['lastMessage'] ?? const {},
              );
              final bLast = Map<String, dynamic>.from(
                b.data()['lastMessage'] ?? const {},
              );
              return _messageDate(
                bLast['timestamp'],
              ).compareTo(_messageDate(aLast['timestamp']));
            });
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Messages',
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: _showNewChatDialog,
                    icon: const Icon(Icons.edit_rounded),
                    tooltip: 'New chat',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _messageSearchController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search chats',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: const Color(0xff181818),
                  suffixIcon: _messageSearchController.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _messageSearchController.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: conversations.isEmpty
                  ? _emptyState(
                      search.isEmpty
                          ? 'No conversations yet'
                          : 'No chats match your search',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 100),
                      itemCount: conversations.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final data = conversations[index].data();
                        final participants = List<String>.from(
                          data['participants'] ?? const [],
                        );
                        final otherUid = participants.firstWhere(
                          (id) => id != user.uid,
                          orElse: () => '',
                        );
                        final details = Map<String, dynamic>.from(
                          data['participantDetails'] ?? const {},
                        );
                        final other = Map<String, dynamic>.from(
                          details[otherUid] ?? const {},
                        );
                        final last = Map<String, dynamic>.from(
                          data['lastMessage'] ?? const {},
                        );
                        final unread =
                            last['isRead'] == false &&
                            last['senderUid'] != user.uid;
                        final time = _messageDate(last['timestamp']);
                        return Card(
                          margin: EdgeInsets.zero,
                          color: unread
                              ? const Color(0xff19162a)
                              : const Color(0xff111111),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            leading: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                CircleAvatar(
                                  radius: 26,
                                  backgroundImage: other['photoURL'] is String
                                      ? NetworkImage(other['photoURL'])
                                      : null,
                                  child: other['photoURL'] == null
                                      ? const Icon(Icons.person_outline_rounded)
                                      : null,
                                ),
                                if (unread)
                                  Positioned(
                                    right: -2,
                                    bottom: -1,
                                    child: Container(
                                      width: 13,
                                      height: 13,
                                      decoration: const BoxDecoration(
                                        color: Color(0xff10b981),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${other['name'] ?? 'User'}',
                                    style: TextStyle(
                                      fontWeight: unread
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  _formatMessageTime(time),
                                  style: TextStyle(
                                    color: unread
                                        ? const Color(0xff10b981)
                                        : Colors.grey[500],
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${last['text'] ?? last['content'] ?? 'Start a conversation'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: unread
                                      ? Colors.white
                                      : Colors.grey[500],
                                  fontWeight: unread
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ViyouChatPage(
                                  partnerUid: otherUid,
                                  partnerName: '${other['name'] ?? 'User'}',
                                  partnerPhoto: other['photoURL'] as String?,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  DateTime _messageDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    return DateTime.tryParse('$value') ?? DateTime(1970);
  }

  String _formatMessageTime(DateTime value) {
    if (value.year == 1970) return '';
    final now = DateTime.now();
    if (now.difference(value).inDays == 0) {
      final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
      final minute = value.minute.toString().padLeft(2, '0');
      return '$hour:$minute ${value.hour >= 12 ? 'PM' : 'AM'}';
    }
    return '${value.day}/${value.month}/${value.year}';
  }

  Future<void> _showNewChatDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final currentUser = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final following = List<String>.from(
      currentUser.data()?['following'] ?? const <dynamic>[],
    );
    final snapshots = await Future.wait(
      following.map(
        (uid) => FirebaseFirestore.instance.collection('users').doc(uid).get(),
      ),
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff151515),
      builder: (_) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Start a new chat',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            if (snapshots.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Follow someone to start a chat.'),
              ),
            ...snapshots.where((doc) => doc.exists).map((doc) {
              final data = doc.data() ?? <String, dynamic>{};
              return ListTile(
                leading: CircleAvatar(
                  backgroundImage: data['photoURL'] is String
                      ? NetworkImage(data['photoURL'])
                      : null,
                  child: data['photoURL'] == null
                      ? const Icon(Icons.person)
                      : null,
                ),
                title: Text('${data['name'] ?? 'User'}'),
                subtitle: Text('@${data['username'] ?? ''}'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ViyouChatPage(
                        partnerUid: doc.id,
                        partnerName: '${data['name'] ?? 'User'}',
                        partnerPhoto: data['photoURL'] as String?,
                      ),
                    ),
                  );
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xff101010),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white.withValues(alpha: .06)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Your profile',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const CircleAvatar(
            child: Icon(Icons.person_outline_rounded),
          ),
          title: Text(
            FirebaseAuth.instance.currentUser?.email ?? 'Login to view profile',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const Text('Open Profile'),
          onTap: () => setState(() => _selectedTab = 4),
        ),
      ],
    ),
  );

  Widget _buildPlaceholderTab() => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          [
            Icons.home_rounded,
            Icons.bolt_rounded,
            Icons.add_box_outlined,
            Icons.chat_bubble_outline_rounded,
            Icons.person_outline_rounded,
          ][_selectedTab],
          size: 58,
          color: const Color(0xff6366f1),
        ),
        const SizedBox(height: 14),
        Text(
          ['Home', 'Flicks', 'Create', 'Messages', 'Profile'][_selectedTab],
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'This screen is ready for the next UI pass',
          style: TextStyle(color: Colors.grey[500]),
        ),
      ],
    ),
  );

  Widget _buildBottomNavigation() => FutureBuilder<UserProfile>(
    future: _profileFuture,
    builder: (context, snapshot) {
      final profile = snapshot.data ?? UserProfile.empty;
      final photo =
          profile.photoUrl ?? FirebaseAuth.instance.currentUser?.photoURL;
      final hasPhoto = photo != null && photo.isNotEmpty;
      final profileIcon = CircleAvatar(
        radius: 12,
        backgroundColor: const Color(0xff2a2a2a),
        backgroundImage: hasPhoto ? NetworkImage(photo) : null,
        child: hasPhoto
            ? null
            : const Icon(Icons.person_outline_rounded, size: 17),
      );
      return NavigationBar(
        backgroundColor: const Color(0xff0f0f0f),
        indicatorColor: const Color(0xff28215a),
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) {
          if (index == 2) {
            _showUploadDialog();
          } else {
            setState(() => _selectedTab = index);
          }
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt_rounded),
            label: 'Flicks',
          ),
          const NavigationDestination(
            icon: Icon(Icons.add_circle_outline_rounded),
            selectedIcon: Icon(Icons.add_circle_rounded),
            label: 'Create',
          ),
          const NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Messages',
          ),
          NavigationDestination(
            icon: profileIcon,
            selectedIcon: profileIcon,
            label: 'Profile',
          ),
        ],
      );
    },
  );

  void _showMenu(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xff151515),
    builder: (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Watch History'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ViyouHistoryPage()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About Viyou.in'),
            onTap: () {
              Navigator.pop(context);
              _openWebsite('https://viyou.in/about-us.html');
            },
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Privacy Policy'),
            onTap: () {
              Navigator.pop(context);
              _openWebsite('https://viyou.in/privacy.html');
            },
          ),
          ListTile(
            leading: const Icon(Icons.account_balance_outlined),
            title: const Text('Monetization Policy'),
            onTap: () {
              Navigator.pop(context);
              _openWebsite('https://viyou.in/monetization-policy.html');
            },
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Terms of Service'),
            onTap: () {
              Navigator.pop(context);
              _openWebsite('https://viyou.in/terms.html');
            },
          ),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Contact Us'),
            onTap: () {
              Navigator.pop(context);
              _openWebsite('https://viyou.in/contact-us.html');
            },
          ),
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: const Text('Advertise with Us'),
            onTap: () {
              Navigator.pop(context);
              _openWebsite('https://viyou.in/advertise.html');
            },
          ),
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('Create post / upload video'),
            onTap: () {
              Navigator.pop(context);
              _showUploadDialog();
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ViyouSettingsPage()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.insights_rounded),
            title: const Text('Creator Studio'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const ViyouStudioDashboardPage(),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Admin Panel'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ViyouAdminPage()),
              );
            },
          ),
          ListTile(
            leading: Icon(
              FirebaseAuth.instance.currentUser == null
                  ? Icons.login_rounded
                  : Icons.logout_rounded,
            ),
            title: Text(
              FirebaseAuth.instance.currentUser == null
                  ? 'Login / Sign up'
                  : 'Logout',
            ),
            onTap: () async {
              Navigator.pop(context);
              if (FirebaseAuth.instance.currentUser == null) {
                await _showAuthDialog();
              } else {
                await FirebaseAuth.instance.signOut();
                if (mounted) setState(() {});
              }
            },
          ),
        ],
      ),
    ),
  );

  Future<void> _showAuthDialog() async {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    var isSignup = false;
    var isBusy = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xff151515),
          title: Text(
            isSignup ? 'Create Viyou.in account' : 'Login to Viyou.in',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
            ],
          ),
          actions: [
            FilledButton.icon(
              onPressed: isBusy ? null : () => _signInWithGoogle(dialogContext),
              icon: const Icon(Icons.login_rounded),
              label: const Text('Continue with Google'),
            ),
            TextButton(
              onPressed: isBusy
                  ? null
                  : () => setDialogState(() => isSignup = !isSignup),
              child: Text(
                isSignup ? 'Already have an account?' : 'Create account',
              ),
            ),
            FilledButton(
              onPressed: isBusy
                  ? null
                  : () async {
                      final email = emailController.text.trim();
                      final password = passwordController.text;
                      if (email.isEmpty || password.length < 6) {
                        _showMessage(
                          context,
                          'Enter a valid email and 6+ character password',
                        );
                        return;
                      }
                      setDialogState(() => isBusy = true);
                      try {
                        UserCredential result;
                        if (isSignup) {
                          result = await FirebaseAuth.instance
                              .createUserWithEmailAndPassword(
                                email: email,
                                password: password,
                              );
                          await FirebaseFirestore.instance
                              .collection('users')
                              .doc(result.user!.uid)
                              .set({
                                'email': email,
                                'name': email.split('@').first,
                                'createdAt': FieldValue.serverTimestamp(),
                              }, SetOptions(merge: true));
                        } else {
                          result = await FirebaseAuth.instance
                              .signInWithEmailAndPassword(
                                email: email,
                                password: password,
                              );
                        }
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                        if (mounted) setState(() {});
                        _showMessage(
                          context,
                          isSignup ? 'Account created' : 'Welcome back',
                        );
                      } on FirebaseAuthException catch (error) {
                        setDialogState(() => isBusy = false);
                        _showMessage(
                          context,
                          error.message ?? 'Authentication failed',
                        );
                      }
                    },
              child: Text(isSignup ? 'Sign up' : 'Login'),
            ),
          ],
        ),
      ),
    );
    emailController.dispose();
    passwordController.dispose();
  }

  Future<void> _signInWithGoogle(BuildContext dialogContext) async {
    try {
      await GoogleSignIn.instance.initialize();
      final googleUser = await GoogleSignIn.instance.authenticate();
      final googleAuth = googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
      );
      final result = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      await FirebaseFirestore.instance
          .collection('users')
          .doc(result.user!.uid)
          .set({
            'name': result.user!.displayName,
            'email': result.user!.email,
            'photoURL': result.user!.photoURL,
          }, SetOptions(merge: true));
      if (dialogContext.mounted) Navigator.pop(dialogContext);
      if (mounted) {
        setState(() {
          _profileFuture = _loadProfile();
        });
        _showMessage(context, 'Welcome to Viyou.in');
      }
    } on GoogleSignInException catch (error) {
      _showMessage(context, error.description ?? 'Google sign-in cancelled');
    } on FirebaseAuthException catch (error) {
      _showMessage(context, error.message ?? 'Google sign-in failed');
    }
  }

  void _showMessage(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
        );
}

class ViyouPromotionHelper {
  static bool _isWithinExpiry(String? value) {
    if (value == null || value.isEmpty) return true;
    final expiry = DateTime.tryParse(value);
    return expiry == null || expiry.isAfter(DateTime.now());
  }

  static bool _matchesCategory(
    String? category,
    List<dynamic>? targetCategories,
  ) {
    if (category == null || category.isEmpty) return true;
    if (targetCategories == null || targetCategories.isEmpty) return true;
    final values = targetCategories.whereType<String>().toList();
    return values.contains(category) || values.contains('All');
  }

  static List<String> normalizeMediaGallery(
    List<dynamic>? images, {
    int maxCount = 5,
  }) {
    if (images == null || images.isEmpty) return const <String>[];
    final unique = <String>[];
    for (final image in images) {
      final value = image?.toString().trim() ?? '';
      if (value.isEmpty) continue;
      if (!unique.contains(value)) unique.add(value);
      if (unique.length >= maxCount) break;
    }
    return unique;
  }

  static bool isMediaGalleryValid(List<dynamic>? images, {int maxCount = 5}) {
    final normalized = normalizeMediaGallery(images, maxCount: maxCount);
    return normalized.isNotEmpty && normalized.length <= maxCount;
  }

  static bool isVideoDurationValid(
    num? durationSeconds, {
    int maxSeconds = 60,
  }) {
    if (durationSeconds == null) return true;
    final value = durationSeconds.toDouble();
    return value <= maxSeconds;
  }

  static List<Map<String, dynamic>> filterApprovedPromotions(
    List<Map<String, dynamic>> promos, {
    required String type,
    String? category,
  }) {
    final normalizedType = type == 'blogad' ? 'blog_ad' : type;
    final now = DateTime.now();
    final filtered = promos.where((promo) {
      final rawType = '${promo['type'] ?? ''}';
      final promoType = rawType == 'blogad' ? 'blog_ad' : rawType;
      final promoStatus = '${promo['status'] ?? ''}';
      if (promoStatus != 'approved' || promoType != normalizedType)
        return false;
      if (!_matchesCategory(
        category,
        (promo['targetCategories'] as List?) ?? const [],
      )) {
        return false;
      }
      final expiry = promo['promoExpiry'];
      if (expiry is String && expiry.isNotEmpty) {
        final parsed = DateTime.tryParse(expiry);
        if (parsed != null && parsed.isBefore(now)) return false;
      }
      if (promoType == 'preroll' || promoType == 'blog_ad') {
        final goal = (promo['impressions_goal'] as num?)?.toInt() ?? 0;
        final served = (promo['impressions_served'] as num?)?.toInt() ?? 0;
        if (goal > 0 && served >= goal) return false;
      }
      return true;
    }).toList();
    return filtered;
  }
}

class BlogRecord {
  const BlogRecord({
    required this.id,
    required this.title,
    required this.category,
    required this.author,
    required this.content,
    required this.date,
    required this.isFlicker,
    required this.likesCount,
    this.viewsCount = 0,
    required this.commentsCount,
    required this.status,
    this.isPromoted = false,
    this.promoFrequency = 0,
    this.promoExpiry,
    this.isLiked = false,
    this.authorPhoto,
    this.image,
    this.images = const [],
    this.thumbnail,
    this.video,
    this.videoQualities = const {},
    this.youtubeUrl,
    this.authorUid,
    this.audioUrl,
    this.audioTitle,
    this.isOriginalAudio = true,
    this.duration = 0,
    this.flickStartTime = 0,
    this.flickEndTime,
  });

  final String title;
  final String id;
  final String category;
  final String author;
  final String content;
  final DateTime date;
  final bool isFlicker;
  final int likesCount;
  final int viewsCount;
  final int commentsCount;
  final String status;
  final bool isPromoted;
  final int promoFrequency;
  final DateTime? promoExpiry;
  final bool isLiked;
  final String? authorPhoto;
  final String? image;
  final List<String> images;
  final String? thumbnail;
  final String? video;
  final Map<String, String> videoQualities;
  final String? youtubeUrl;
  final String? authorUid;
  final String? audioUrl;
  final String? audioTitle;
  final bool isOriginalAudio;
  final double duration;
  final double flickStartTime;
  final double? flickEndTime;

  String? get primaryImage {
    if (thumbnail != null && thumbnail!.isNotEmpty) return thumbnail;
    if (image != null && image!.isNotEmpty) return image;
    return images.isEmpty ? null : images.first;
  }

  List<String> get imageSources {
    final sources = <String>[];
    void add(String? value) {
      if (value != null && value.isNotEmpty && !sources.contains(value)) {
        sources.add(value);
      }
    }

    add(thumbnail);
    add(image);
    for (final value in images) {
      add(value);
    }
    return sources;
  }

  factory BlogRecord.fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    final dateValue = data['date'];
    final parsedDate = dateValue is Timestamp
        ? dateValue.toDate()
        : DateTime.tryParse('$dateValue') ?? DateTime(1970);
    final likes = data['likes'];
    final comments = data['comments'];
    return BlogRecord(
      id: document.id,
      title: '${data['title'] ?? 'Untitled'}',
      category: '${data['category'] ?? 'Others'}',
      author: '${data['author'] ?? 'Viyou creator'}',
      content: '${data['content'] ?? ''}',
      date: parsedDate,
      isFlicker: data['isFlicker'] == true,
      likesCount: likes is List ? likes.length : (likes is int ? likes : 0),
      viewsCount:
          ((data['longVideoViews'] ?? data['views']) as num?)?.toInt() ?? 0,
      commentsCount: comments is List
          ? comments.length
          : (comments is int ? comments : 0),
      status: '${data['status'] ?? 'published'}',
      isPromoted: data['isPromoted'] == true,
      promoFrequency: (data['promoFrequency'] as num?)?.toInt() ?? 0,
      promoExpiry: DateTime.tryParse('${data['promoExpiry'] ?? ''}'),
      isLiked: _currentUserLikes(data['likes']),
      authorPhoto: data['authorPhoto'] as String?,
      image: data['image'] as String?,
      images: data['images'] is List
          ? (data['images'] as List).whereType<String>().toList()
          : const [],
      thumbnail: data['thumbnail'] as String?,
      video: data['video'] as String?,
      videoQualities: data['videoQualities'] is Map
          ? Map<String, String>.from(
              (data['videoQualities'] as Map).map(
                (key, value) => MapEntry('$key', '$value'),
              ),
            )
          : const {},
      youtubeUrl: data['youtubeUrl'] as String?,
      authorUid: data['authorUid'] as String?,
      audioUrl: data['audioUrl'] as String?,
      audioTitle: data['audioTitle'] as String?,
      isOriginalAudio: data['isOriginalAudio'] != false,
      duration: (data['duration'] as num?)?.toDouble() ?? 0,
      flickStartTime: (data['flickStartTime'] as num?)?.toDouble() ?? 0,
      flickEndTime: (data['flickEndTime'] as num?)?.toDouble(),
    );
  }

  factory BlogRecord.fromMap(String id, Map<String, dynamic> data) {
    final dateValue = data['date'];
    return BlogRecord(
      id: id,
      title: '${data['title'] ?? 'Untitled'}',
      category: '${data['category'] ?? 'Others'}',
      author: '${data['author'] ?? 'Viyou creator'}',
      content: '${data['content'] ?? ''}',
      date: dateValue is Timestamp
          ? dateValue.toDate()
          : DateTime.tryParse('$dateValue') ?? DateTime(1970),
      isFlicker: data['isFlicker'] == true,
      likesCount: data['likes'] is List
          ? (data['likes'] as List).length
          : (data['likes'] is int ? data['likes'] : 0),
      viewsCount:
          ((data['longVideoViews'] ?? data['views']) as num?)?.toInt() ?? 0,
      commentsCount: data['comments'] is List
          ? (data['comments'] as List).length
          : 0,
      status: '${data['status'] ?? 'published'}',
      isPromoted: data['isPromoted'] == true,
      promoFrequency: (data['promoFrequency'] as num?)?.toInt() ?? 0,
      promoExpiry: DateTime.tryParse('${data['promoExpiry'] ?? ''}'),
      isLiked: _currentUserLikes(data['likes']),
      authorPhoto: data['authorPhoto'] as String?,
      image: data['image'] as String?,
      images: data['images'] is List
          ? (data['images'] as List).whereType<String>().toList()
          : const [],
      thumbnail: data['thumbnail'] as String?,
      video: data['video'] as String?,
      videoQualities: data['videoQualities'] is Map
          ? Map<String, String>.from(
              (data['videoQualities'] as Map).map(
                (key, value) => MapEntry('$key', '$value'),
              ),
            )
          : const {},
      youtubeUrl: data['youtubeUrl'] as String?,
      authorUid: data['authorUid'] as String?,
      audioUrl: data['audioUrl'] as String?,
      audioTitle: data['audioTitle'] as String?,
      isOriginalAudio: data['isOriginalAudio'] != false,
      duration: (data['duration'] as num?)?.toDouble() ?? 0,
      flickStartTime: (data['flickStartTime'] as num?)?.toDouble() ?? 0,
      flickEndTime: (data['flickEndTime'] as num?)?.toDouble(),
    );
  }

  static bool _currentUserLikes(Object? value) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return uid != null &&
        value is List &&
        value.whereType<String>().contains(uid);
  }
}

class _BlogImageCarousel extends StatefulWidget {
  const _BlogImageCarousel({required this.images});

  final List<String> images;

  @override
  State<_BlogImageCarousel> createState() => _BlogImageCarouselState();
}

class _BlogImageCarouselState extends State<_BlogImageCarousel> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Widget _image(String source) {
    if (source.startsWith('data:image/')) {
      final comma = source.indexOf(',');
      if (comma > 0) {
        try {
          return Image.memory(
            base64Decode(source.substring(comma + 1)),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallback(),
          );
        } catch (_) {
          return _fallback();
        }
      }
    }
    return Image.network(
      source,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _fallback(),
    );
  }

  Widget _fallback() => Container(
    color: const Color(0xff202020),
    alignment: Alignment.center,
    child: const Icon(Icons.image_not_supported_outlined, size: 42),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) return _fallback();
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.images.length,
            physics: const PageScrollPhysics(),
            allowImplicitScrolling: true,
            onPageChanged: (page) => setState(() => _currentPage = page),
            itemBuilder: (_, index) => _image(widget.images[index]),
          ),
          if (widget.images.length > 1)
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .68),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${_currentPage + 1}/${widget.images.length}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (widget.images.length > 1 && _currentPage > 0)
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: _carouselButton(
                  Icons.chevron_left_rounded,
                  () => _goToPage(_currentPage - 1),
                ),
              ),
            ),
          if (widget.images.length > 1 &&
              _currentPage < widget.images.length - 1)
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: _carouselButton(
                  Icons.chevron_right_rounded,
                  () => _goToPage(_currentPage + 1),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _goToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Widget _carouselButton(IconData icon, VoidCallback onPressed) => Material(
    color: Colors.black.withValues(alpha: .55),
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 24),
      ),
    ),
  );
}

class ViyouCreatePage extends StatefulWidget {
  const ViyouCreatePage({super.key, this.onPublished});

  final VoidCallback? onPublished;

  @override
  State<ViyouCreatePage> createState() => _ViyouCreatePageState();
}

class _ViyouCreatePageState extends State<ViyouCreatePage> {
  final Map<String, TextEditingController> _tabTitleControllers = {
    'blog': TextEditingController(),
    'video': TextEditingController(),
    'flick': TextEditingController(),
  };
  final Map<String, TextEditingController> _tabDescriptionControllers = {
    'blog': TextEditingController(),
    'video': TextEditingController(),
    'flick': TextEditingController(),
  };
  final List<XFile> _selectedImages = <XFile>[];
  final Map<String, XFile?> _tabVideos = {'video': null, 'flick': null};
  final Map<String, XFile?> _tabThumbnails = {'video': null, 'flick': null};
  final Map<String, Uint8List?> _tabThumbnailBytes = {
    'video': null,
    'flick': null,
  };
  final Map<String, VideoPlayerController?> _tabVideoControllers = {
    'video': null,
    'flick': null,
  };
  final Map<String, double?> _tabVideoDurations = {
    'video': null,
    'flick': null,
  };
  final Map<String, double> _tabTrimStart = {'video': 0, 'flick': 0};
  final Map<String, double> _tabTrimEnd = {'video': 60, 'flick': 60};
  String _category = 'Entertainment';
  String _contentType = 'blog';
  List<Uint8List> _imagePreviewBytes = <Uint8List>[];
  bool _uploading = false;

  TextEditingController get _titleController =>
      _tabTitleControllers[_contentType] ?? _tabTitleControllers['blog']!;
  TextEditingController get _descriptionController =>
      _tabDescriptionControllers[_contentType] ??
      _tabDescriptionControllers['blog']!;

  XFile? get _selectedVideo => _tabVideos[_contentType];
  XFile? get _selectedThumbnail => _tabThumbnails[_contentType];
  Uint8List? get _selectedThumbnailBytes => _tabThumbnailBytes[_contentType];
  VideoPlayerController? get _videoPreviewController =>
      _tabVideoControllers[_contentType];
  double? get _videoDurationSeconds => _tabVideoDurations[_contentType];
  double get _trimStart => _tabTrimStart[_contentType] ?? 0;
  double get _trimEnd => _tabTrimEnd[_contentType] ?? 60;

  set _selectedVideo(XFile? value) => _tabVideos[_contentType] = value;
  set _selectedThumbnail(XFile? value) => _tabThumbnails[_contentType] = value;
  set _thumbnailPreviewBytes(Uint8List? value) =>
      _tabThumbnailBytes[_contentType] = value;
  set _videoPreviewController(VideoPlayerController? value) =>
      _tabVideoControllers[_contentType] = value;
  set _videoDurationSeconds(double? value) =>
      _tabVideoDurations[_contentType] = value;
  set _trimStart(double value) => _tabTrimStart[_contentType] = value;
  set _trimEnd(double value) => _tabTrimEnd[_contentType] = value;

  static const int _blogTitleLimit = 100;
  static const int _blogDescriptionLimit = 10000;
  static const int _videoTitleLimit = 100;
  static const int _videoDescriptionLimit = 1000;
  static const int _blogImageMaxCount = 5;
  static const int _maxCompressedImageBytes = 100 * 1024;

  Future<Uint8List?> _compressImageToBytes(XFile file) async {
    final originalBytes = await file.readAsBytes();
    final decoded = img.decodeImage(originalBytes);
    if (decoded == null) return null;

    img.Image current = decoded;
    var quality = 90;

    while (true) {
      final encoded = img.encodeJpg(current, quality: quality);
      if (encoded.length <= _maxCompressedImageBytes) {
        return Uint8List.fromList(encoded);
      }

      if (current.width <= 400 || current.height <= 400) {
        final fallback = img.encodeJpg(current, quality: 15);
        return Uint8List.fromList(fallback);
      }

      current = img.copyResize(
        current,
        width: (current.width * 0.8).round(),
        height: (current.height * 0.8).round(),
      );
      quality -= 10;
      if (quality < 15) {
        final fallback = img.encodeJpg(current, quality: 15);
        return Uint8List.fromList(fallback);
      }
    }
  }

  Future<void> _pickMedia() async {
    if (_contentType == 'blog') {
      final media = await ImagePicker().pickMultiImage(
        limit: _blogImageMaxCount,
      );
      if (media.isEmpty) return;
      if (media.length > _blogImageMaxCount) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Select between 1 and 5 images only')),
          );
        }
        return;
      }
      final previewBytes = <Uint8List>[];
      for (final item in media) {
        final bytes = await _compressImageToBytes(item);
        if (bytes != null) previewBytes.add(bytes);
      }
      setState(() {
        _selectedImages
          ..clear()
          ..addAll(media);
        _imagePreviewBytes = previewBytes;
      });
      return;
    }

    final media = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (media == null) return;
    await _setSelectedVideo(media);
  }

  Future<void> _pickThumbnail() async {
    final image = await _pickImageWithCameraChoice(
      context,
      purpose: 'take a video thumbnail',
    );
    if (image == null) return;
    final bytes = await _compressImageToBytes(image);
    if (bytes == null) return;
    setState(() {
      _selectedThumbnail = image;
      _thumbnailPreviewBytes = bytes;
    });
  }

  Future<void> _setSelectedVideo(XFile video) async {
    _selectedVideo = video;
    _selectedThumbnail = null;
    _thumbnailPreviewBytes = null;

    final previousController = _videoPreviewController;
    previousController?.dispose();
    if (kIsWeb) {
      _videoPreviewController = VideoPlayerController.networkUrl(
        Uri.parse(video.path),
      );
    } else {
      _videoPreviewController = VideoPlayerController.file(File(video.path));
    }

    try {
      await _videoPreviewController!.initialize();
      final duration =
          _videoPreviewController!.value.duration.inMilliseconds / 1000.0;
      _videoDurationSeconds = duration;
      _trimStart = 0;
      _trimEnd = duration > 60 ? 60 : duration;
    } catch (_) {
      _videoDurationSeconds = null;
      _trimStart = 0;
      _trimEnd = 60;
    }

    if (mounted) setState(() {});
  }

  bool _isTitleLengthValid() {
    final text = _titleController.text.trim();
    if (text.isEmpty) return true;
    final limit = _contentType == 'blog' ? _blogTitleLimit : _videoTitleLimit;
    return text.length <= limit;
  }

  bool _isDescriptionLengthValid() {
    final text = _descriptionController.text.trim();
    if (text.isEmpty) return true;
    final limit = _contentType == 'blog'
        ? _blogDescriptionLimit
        : _videoDescriptionLimit;
    return text.length <= limit;
  }

  bool _isFlickClipValid() {
    if (_contentType != 'flick' || _selectedVideo == null) return true;
    final duration = _videoDurationSeconds ?? 0;
    if (duration <= 0) return false;
    final selectedLength = (_trimEnd - _trimStart).clamp(0.0, duration);
    return selectedLength <= 60;
  }

  Future<void> _publish() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Login first to publish')));
      }
      return;
    }

    final titleText = _titleController.text.trim();
    final descriptionText = _descriptionController.text.trim();

    if (_contentType == 'blog' && titleText.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Blog title is required')));
      return;
    }

    if (!_isTitleLengthValid()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _contentType == 'blog'
                ? 'Blog title must be 100 characters or less'
                : 'Video title must be 100 characters or less',
          ),
        ),
      );
      return;
    }

    if (!_isDescriptionLengthValid()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _contentType == 'blog'
                ? 'Blog description must be 10000 characters or less'
                : 'Video description must be 1000 characters or less',
          ),
        ),
      );
      return;
    }

    if (_contentType != 'blog' && _selectedVideo == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Choose a video first')));
      return;
    }

    if (_contentType == 'blog' && _selectedImages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose 1 to 5 blog images')),
      );
      return;
    }

    if (!_isFlickClipValid()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Flick clip must be 60 seconds or less')),
      );
      return;
    }

    setState(() => _uploading = true);

    try {
      String? videoUrl;
      String? imageUrl;
      String? thumbnailUrl;
      final imageUrls = <String>[];
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      if (_contentType == 'blog') {
        for (final image in _selectedImages) {
          final compressed = await _compressImageToBytes(image);
          if (compressed == null) continue;
          final fileName = '${timestamp}_${image.name}';
          final storageRef = FirebaseStorage.instance.ref(
            'user_images/${currentUser.uid}/$fileName',
          );
          await storageRef.putData(
            compressed,
            SettableMetadata(contentType: 'image/jpeg'),
          );
          imageUrls.add(await storageRef.getDownloadURL());
        }
      }

      if (_selectedVideo != null) {
        final fileName = '${timestamp}_${_selectedVideo!.name}';
        final storageRef = FirebaseStorage.instance.ref(
          'user_videos/${currentUser.uid}/$fileName',
        );
        await storageRef.putData(
          await _selectedVideo!.readAsBytes(),
          SettableMetadata(
            contentType: videoContentTypeForName(
              _selectedVideo!.name,
              mimeType: _selectedVideo!.mimeType,
            ),
          ),
        );
        videoUrl = await storageRef.getDownloadURL();
      }

      if (_selectedThumbnail != null) {
        final compressed = await _compressImageToBytes(_selectedThumbnail!);
        if (compressed != null) {
          final fileName = '${timestamp}_${_selectedThumbnail!.name}';
          final storageRef = FirebaseStorage.instance.ref(
            'user_thumbnails/${currentUser.uid}/$fileName',
          );
          await storageRef.putData(
            compressed,
            SettableMetadata(contentType: 'image/jpeg'),
          );
          thumbnailUrl = await storageRef.getDownloadURL();
        }
      }

      final finalTitle = titleText.isEmpty
          ? (_contentType == 'blog'
                ? 'Untitled blog'
                : (_contentType == 'flick'
                      ? 'Untitled flick'
                      : 'Untitled video'))
          : titleText;

      final payload = {
        'title': finalTitle,
        'titleLower': finalTitle.toLowerCase(),
        'category': _category,
        'author':
            currentUser.displayName ??
            currentUser.email?.split('@').first ??
            'Viyou creator',
        'authorUid': currentUser.uid,
        'authorPhoto': currentUser.photoURL,
        'content': descriptionText,
        'isFlicker': _contentType == 'flick',
        'video': videoUrl,
        'thumbnail': thumbnailUrl,
        'image': imageUrls.isNotEmpty ? imageUrls.first : null,
        'images': imageUrls,
        'date': DateTime.now().toIso8601String(),
        'comments': [],
        'likes': [],
        'views': 0,
        'status': 'published',
        'visibility': 'public',
        'trimStart': _contentType == 'flick' ? _trimStart : null,
        'trimEnd': _contentType == 'flick' ? _trimEnd : null,
        'videoDuration': _videoDurationSeconds,
      };

      await FirebaseFirestore.instance.collection('blogs').add(payload);

      widget.onPublished?.call();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Published successfully')));
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Publish failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Widget _typeTab(String value, IconData icon, String label) {
    final selected = _contentType == value;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _contentType = value),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border(
              bottom: BorderSide(
                color: selected ? const Color(0xff6366f1) : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : const Color(0xff8b8b8b),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : const Color(0xff8b8b8b),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewSection() {
    if (_contentType == 'blog') {
      if (_imagePreviewBytes.isEmpty) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.only(bottom: 14),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final bytes in _imagePreviewBytes)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  bytes,
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                ),
              ),
          ],
        ),
      );
    }

    final showVideoPreview =
        _selectedVideo != null && _videoPreviewController != null;
    final selectedDuration = _videoDurationSeconds == null
        ? 0.0
        : (_trimEnd - _trimStart).clamp(0.0, _videoDurationSeconds!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showVideoPreview)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: _contentType == 'flick' ? 9 / 16 : 16 / 9,
                child: VideoPlayer(_videoPreviewController!),
              ),
            ),
          ),
        if (_selectedThumbnailBytes != null)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: AspectRatio(
                  aspectRatio: _contentType == 'flick' ? 9 / 16 : 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      _selectedThumbnailBytes!,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (_contentType == 'flick' &&
            _selectedVideo != null &&
            _videoDurationSeconds != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xff171717),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Trim flick segment',
                  style: TextStyle(
                    color: Color(0xfff59e0b),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Selected length: ${selectedDuration.toStringAsFixed(1)}s / 60s',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xff6366f1),
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                    overlayColor: const Color(
                      0xff6366f1,
                    ).withValues(alpha: 0.2),
                  ),
                  child: Column(
                    children: [
                      Slider(
                        value: _trimStart,
                        min: 0,
                        max: (_videoDurationSeconds ?? 0) > 0
                            ? (_videoDurationSeconds! - 0.5).clamp(0.0, 9999.0)
                            : 0,
                        divisions:
                            ((_videoDurationSeconds ?? 0) > 0
                                    ? (_videoDurationSeconds! * 10).round()
                                    : 1)
                                .clamp(1, 600),
                        onChanged: (value) {
                          if (value >= _trimEnd) {
                            setState(() => _trimStart = _trimEnd - 0.5);
                          } else {
                            setState(() => _trimStart = value);
                          }
                        },
                        label: '${_trimStart.toStringAsFixed(1)}s',
                      ),
                      Slider(
                        value: _trimEnd,
                        min: _trimStart + 0.5,
                        max: _videoDurationSeconds ?? 60,
                        divisions:
                            ((_videoDurationSeconds ?? 0) > 0
                                    ? (_videoDurationSeconds! * 10).round()
                                    : 60)
                                .clamp(1, 600),
                        onChanged: (value) {
                          final maxAllowed = (_videoDurationSeconds ?? 60)
                              .clamp(0.0, 60.0);
                          if ((value - _trimStart) > 60) {
                            setState(() => _trimEnd = _trimStart + 60);
                          } else {
                            setState(
                              () => _trimEnd = value.clamp(
                                _trimStart + 0.5,
                                maxAllowed,
                              ),
                            );
                          }
                        },
                        label: '${_trimEnd.toStringAsFixed(1)}s',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final titleLimit = _contentType == 'blog'
        ? _blogTitleLimit
        : _videoTitleLimit;
    final descriptionLimit = _contentType == 'blog'
        ? _blogDescriptionLimit
        : _videoDescriptionLimit;
    final mediaLabel = _contentType == 'blog'
        ? (_selectedImages.isEmpty
              ? 'Choose 1–5 images'
              : '${_selectedImages.length} image${_selectedImages.length == 1 ? '' : 's'} selected')
        : (_selectedVideo == null ? 'Choose video' : _selectedVideo!.name);
    final thumbnailLabel = _selectedThumbnail == null
        ? 'Choose thumbnail (optional)'
        : _selectedThumbnail!.name;

    return Scaffold(
      backgroundColor: const Color(0xff0a0a0a),
      appBar: AppBar(
        backgroundColor: const Color(0xff0a0a0a),
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: const Text('Create'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      'Share Your Story ✨',
                      style: TextStyle(
                        color: Color(0xfff59e0b),
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Center(
                    child: Text(
                      'Publish blogs and Flicks, grow your audience, and build your community.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xffcfcfcf), fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: const Color(0xff121212),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Row(
                      children: [
                        _typeTab('blog', Icons.edit_note_rounded, 'Blog Post'),
                        _typeTab(
                          'video',
                          Icons.play_circle_outline_rounded,
                          'Long Video',
                        ),
                        _typeTab('flick', Icons.bolt_rounded, 'Flick'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _titleController,
                    maxLength: titleLimit,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: _contentType == 'blog'
                          ? 'Ex: भारत की शानदार जीत...'
                          : 'Ex: My Long Video Title...',
                      labelText: _contentType == 'blog'
                          ? 'Title'
                          : 'Title (Optional)',
                      counterText: '',
                      filled: true,
                      fillColor: const Color(0xff171717),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xff6366f1),
                          width: 1.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${_titleController.text.length} / $titleLimit',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    value: _category,
                    items:
                        [
                              'Entertainment',
                              'Music',
                              'Vlogs',
                              'Gaming',
                              'Education',
                              'Sports',
                              'News & Politics',
                              'Science & Technology',
                              'Comedy',
                              'Travel & Events',
                              'Fashion & Beauty',
                              'Food',
                              'Devotional',
                              'Gym & Fitness',
                              'Health',
                              'Podcasts',
                              'Others',
                            ]
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                    onChanged: (value) =>
                        setState(() => _category = value ?? _category),
                    decoration: InputDecoration(
                      labelText: 'Category',
                      filled: true,
                      fillColor: const Color(0xff171717),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xff6366f1),
                          width: 1.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _descriptionController,
                    maxLength: descriptionLimit,
                    onChanged: (_) => setState(() {}),
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: _contentType == 'blog'
                          ? 'Description'
                          : 'Description (Optional)',
                      hintText: _contentType == 'blog'
                          ? 'Write a clear description for your audience...'
                          : 'Description for your video... (Optional)',
                      counterText: '',
                      filled: true,
                      fillColor: const Color(0xff171717),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xff6366f1),
                          width: 1.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${_descriptionController.text.length} / $descriptionLimit',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildPreviewSection(),
                  if (_contentType == 'blog')
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xff161616),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.07),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.image_outlined,
                            color: Color(0xfff59e0b),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              mediaLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: _uploading ? null : _pickMedia,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xff6366f1)),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text('Browse'),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xff161616),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.07),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.video_library_outlined,
                            color: Color(0xfff59e0b),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              mediaLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: _uploading ? null : _pickMedia,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xff6366f1)),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text('Select'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xff161616),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.07),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.image_outlined,
                            color: Color(0xfff59e0b),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              thumbnailLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton(
                            onPressed: _uploading ? null : _pickThumbnail,
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xff6366f1)),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text('Thumbnail'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: _uploading
                              ? null
                              : () => Navigator.pop(context),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xffd1d5db),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: _uploading ? null : _publish,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xff6366f1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: _uploading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Publish'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final controller in _tabTitleControllers.values) {
      controller.dispose();
    }
    for (final controller in _tabDescriptionControllers.values) {
      controller.dispose();
    }
    for (final controller in _tabVideoControllers.values) {
      controller?.dispose();
    }
    super.dispose();
  }
}

class UserProfile {
  const UserProfile({
    this.userId = '',
    required this.name,
    required this.username,
    required this.photoUrl,
    required this.followers,
    required this.following,
    required this.postsList,
    this.bio = '',
    this.email = '',
  });

  static const empty = UserProfile(
    name: '',
    username: '',
    photoUrl: null,
    followers: 0,
    following: 0,
    postsList: [],
  );

  final String name;
  final String userId;
  final String username;
  final String? photoUrl;
  final int followers;
  final int following;
  final List<BlogRecord> postsList;
  final String bio;
  final String email;

  int get posts => postsList.length;

  factory UserProfile.fromDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
    User? user,
    List<BlogRecord> posts,
  ) {
    final data = document.data() ?? {};
    final followers = data['followers'];
    final following = data['following'];
    return UserProfile(
      userId: document.id,
      name:
          '${data['name'] ?? user?.displayName ?? user?.email?.split('@').first ?? ''}',
      username: '${data['username'] ?? ''}',
      photoUrl: data['photoURL'] as String? ?? user?.photoURL,
      followers: followers is List
          ? followers.length
          : (followers is int ? followers : 0),
      following: following is List
          ? following.length
          : (following is int ? following : 0),
      postsList: posts,
      bio: '${data['bio'] ?? ''}',
      email: '${data['email'] ?? user?.email ?? ''}',
    );
  }
}

class ViyouPublicProfilePage extends StatefulWidget {
  const ViyouPublicProfilePage({super.key, required this.profile});

  final UserProfile profile;

  @override
  State<ViyouPublicProfilePage> createState() => _ViyouPublicProfilePageState();
}

class ViyouConnectionsPage extends StatelessWidget {
  const ViyouConnectionsPage({
    super.key,
    required this.userId,
    required this.field,
  });

  final String userId;
  final String field;

  Future<List<Map<String, dynamic>>> _loadUsers() async {
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .get();
    final raw = profile.data()?[field];
    final ids = raw is List ? raw.whereType<String>().toList() : <String>[];
    final users = <Map<String, dynamic>>[];
    for (final id in ids) {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(id)
          .get();
      if (snapshot.exists) users.add({'id': id, ...?snapshot.data()});
    }
    return users;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(field == 'followers' ? 'Followers' : 'Following'),
    ),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: _loadUsers(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final users = snapshot.data ?? [];
        if (users.isEmpty) return const Center(child: Text('No users yet'));
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: users.length,
          separatorBuilder: (_, __) => const Divider(color: Colors.white12),
          itemBuilder: (context, index) {
            final data = users[index];
            final photo = data['photoURL'];
            return ListTile(
              leading: CircleAvatar(
                backgroundImage:
                    photo is String &&
                        (photo.startsWith('http://') ||
                            photo.startsWith('https://') ||
                            photo.startsWith('data:image/'))
                    ? (photo.startsWith('data:image/')
                          ? MemoryImage(
                              base64Decode(
                                photo.substring(photo.indexOf(',') + 1),
                              ),
                            )
                          : NetworkImage(photo))
                    : null,
                child: photo is String && photo.isNotEmpty
                    ? null
                    : const Icon(Icons.person),
              ),
              title: Text(
                '${data['name'] ?? data['username'] ?? 'Viyou user'}',
              ),
              subtitle: data['username'] == null
                  ? null
                  : Text('@${data['username']}'),
            );
          },
        );
      },
    ),
  );
}

class _ViyouPublicProfilePageState extends State<ViyouPublicProfilePage> {
  bool following = false;
  int _section = 0;
  late Future<QuerySnapshot<Map<String, dynamic>>> _publicPlaylists;

  @override
  void initState() {
    super.initState();
    _loadFollowing();
    _publicPlaylists = FirebaseFirestore.instance
        .collection('playlists')
        .where('authorUid', isEqualTo: widget.profile.userId)
        .get();
  }

  Future<void> _loadFollowing() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null || current.uid == widget.profile.userId) return;
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(current.uid)
        .get();
    if (mounted)
      setState(
        () => following = List<String>.from(
          snap.data()?['following'] ?? const [],
        ).contains(widget.profile.userId),
      );
  }

  Future<void> _toggleFollowing() async {
    final current = FirebaseAuth.instance.currentUser;
    if (current == null || widget.profile.userId.isEmpty) return;
    final next = !following;
    setState(() => following = next);
    await FirebaseFirestore.instance
        .collection('users')
        .doc(current.uid)
        .update({
          'following': next
              ? FieldValue.arrayUnion([widget.profile.userId])
              : FieldValue.arrayRemove([widget.profile.userId]),
        });
    await FirebaseFirestore.instance
        .collection('users')
        .doc(widget.profile.userId)
        .update({
          'followers': next
              ? FieldValue.arrayUnion([current.uid])
              : FieldValue.arrayRemove([current.uid]),
        });
  }

  Future<void> _markStoryAsSeen(String storyId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || storyId.isEmpty) return;
    try {
      final ref = FirebaseFirestore.instance.collection('stories').doc(storyId);
      final snapshot = await ref.get();
      final seenBy = snapshot.data()?['seenBy'] as List? ?? const <dynamic>[];
      if (seenBy.contains(uid)) return;
      await ref.update({
        'seenBy': FieldValue.arrayUnion([uid]),
      });
    } catch (_) {
      // ignore Firestore write issues
    }
  }

  Future<bool> _userHasActiveStory(String userId) async {
    if (userId.isEmpty) return false;
    final snapshot = await FirebaseFirestore.instance
        .collection('stories')
        .where('authorUid', isEqualTo: userId)
        .orderBy('timestamp', descending: true)
        .limit(10)
        .get();

    final now = DateTime.now();
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final timestampValue = data['timestamp'];
      DateTime? timestamp;
      if (timestampValue is Timestamp) {
        timestamp = timestampValue.toDate();
      } else if (timestampValue is String) {
        timestamp = DateTime.tryParse(timestampValue);
      }
      if (timestamp != null && now.difference(timestamp).inHours <= 24) {
        return true;
      }
    }
    return false;
  }

  Future<void> _openStoryViewer(
    String authorUid,
    List<Map<String, dynamic>> stories, {
    int startIndex = 0,
  }) async {
    if (stories.isEmpty) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      for (final story in stories) {
        final storyId = '${story['id'] ?? ''}';
        if (storyId.isNotEmpty && story['authorUid'] != uid) {
          unawaited(_markStoryAsSeen(storyId));
        }
      }
    }
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => _StoryViewerDialog(
        authorUid: authorUid,
        stories: stories,
        initialIndex: startIndex,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOwner =
        FirebaseAuth.instance.currentUser?.uid == widget.profile.userId;
    final blogs = widget.profile.postsList
        .where(
          (post) =>
              post.status == 'published' &&
              !post.isFlicker &&
              post.video == null,
        )
        .toList();
    final videos = widget.profile.postsList
        .where(
          (post) =>
              post.status == 'published' &&
              !post.isFlicker &&
              (post.video != null || post.youtubeUrl != null),
        )
        .toList();
    final flicks = widget.profile.postsList
        .where((post) => post.status == 'published' && post.isFlicker)
        .toList();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back',
        ),
        title: const Text('Profile'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () async {
                  final hasStory = await _userHasActiveStory(
                    widget.profile.userId,
                  );
                  if (!hasStory) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ViyouPublicProfilePage(profile: widget.profile),
                      ),
                    );
                    return;
                  }

                  final choice = await showDialog<String>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: const Color(0xff171717),
                      title: const Text('Open profile or story?'),
                      content: Text(
                        'This creator has an active story. Open story or profile?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, 'profile'),
                          child: const Text('Profile'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, 'story'),
                          child: const Text('Story'),
                        ),
                      ],
                    ),
                  );

                  if (choice == 'story') {
                    final stories = await FirebaseFirestore.instance
                        .collection('stories')
                        .where('authorUid', isEqualTo: widget.profile.userId)
                        .orderBy('timestamp', descending: true)
                        .limit(20)
                        .get();
                    final items = stories.docs
                        .map((doc) => {'id': doc.id, ...doc.data()})
                        .toList();
                    if (items.isNotEmpty && mounted) {
                      await _openStoryViewer(
                        widget.profile.userId,
                        items,
                        startIndex: 0,
                      );
                    }
                    return;
                  }

                  if (!mounted) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ViyouPublicProfilePage(profile: widget.profile),
                    ),
                  );
                },
                child: CircleAvatar(
                  radius: 42,
                  backgroundImage: widget.profile.photoUrl == null
                      ? null
                      : NetworkImage(widget.profile.photoUrl!),
                  child: widget.profile.photoUrl == null
                      ? Text(
                          widget.profile.name.isEmpty
                              ? '?'
                              : widget.profile.name[0].toUpperCase(),
                        )
                      : null,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.profile.name.isEmpty
                          ? 'Viyou creator'
                          : widget.profile.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (widget.profile.username.isNotEmpty)
                      Text(
                        '@${widget.profile.username}',
                        style: TextStyle(color: Colors.grey[500]),
                      ),
                    if (widget.profile.bio.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          widget.profile.bio,
                          style: TextStyle(color: Colors.grey[300]),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '${widget.profile.posts} Posts  •  ${widget.profile.followers} Followers${isOwner ? '  •  ${widget.profile.following} Following' : ''}',
                    ),
                    if (FirebaseAuth.instance.currentUser?.uid !=
                        widget.profile.userId)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: FilledButton(
                          onPressed: _toggleFollowing,
                          child: Text(following ? 'Following' : 'Follow'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _publicTab(0, Icons.article_outlined, 'Blogs'),
                _publicTab(1, Icons.play_circle_outline, 'Videos'),
                _publicTab(2, Icons.bolt, 'Flicks'),
                _publicTab(3, Icons.playlist_play_rounded, 'Playlists'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_section < 3)
            ...(_section == 0
                    ? blogs
                    : _section == 1
                    ? videos
                    : flicks)
                .map(
                  (post) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PublicPostTile(blog: post),
                  ),
                ),
          if (_section == 3) _publicPlaylistSection(),
        ],
      ),
    );
  }

  Widget _publicTab(int value, IconData icon, String label) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      selected: _section == value,
      avatar: Icon(icon, size: 17),
      label: Text(label),
      selectedColor: const Color(0xfff59e0b),
      labelStyle: TextStyle(
        color: _section == value ? Colors.black : Colors.white,
        fontWeight: FontWeight.w700,
      ),
      onSelected: (_) => setState(() => _section = value),
    ),
  );

  Widget _publicPlaylistSection() =>
      FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
        future: _publicPlaylists,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs =
              snapshot.data?.docs
                  .where((doc) => doc.data()['visibility'] == 'public')
                  .toList() ??
              [];
          if (docs.isEmpty)
            return const Center(child: Text('No public playlists'));
          return Column(
            children: docs.map((doc) {
              final data = doc.data();
              final ids = List<String>.from(data['items'] ?? const []);
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.playlist_play_rounded),
                  ),
                  title: Text('${data['name'] ?? 'Playlist'}'),
                  subtitle: Text('${ids.length} saved items'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ViyouPlaylistDetailPage(
                        title: '${data['name'] ?? 'Playlist'}',
                        itemIds: ids,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        },
      );
}

class ViyouPlaylistsPage extends StatefulWidget {
  const ViyouPlaylistsPage({super.key});

  @override
  State<ViyouPlaylistsPage> createState() => _ViyouPlaylistsPageState();
}

class _ViyouPlaylistsPageState extends State<ViyouPlaylistsPage> {
  late Future<QuerySnapshot<Map<String, dynamic>>> _playlists;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final user = FirebaseAuth.instance.currentUser;
    _playlists = user == null
        ? Future.value(null)
        : FirebaseFirestore.instance
              .collection('playlists')
              .where('authorUid', isEqualTo: user.uid)
              .get();
  }

  Future<void> _createPlaylist() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await FirebaseFirestore.instance.collection('playlists').add({
      'authorUid': user.uid,
      'authorName':
          user.displayName ?? user.email?.split('@').first ?? 'Viyou creator',
      'name': name,
      'description': '',
      'visibility': 'public',
      'items': [],
      'createdAt': DateTime.now().toIso8601String(),
    });
    if (!mounted) return;
    setState(_reload);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Playlist created')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Playlists')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _createPlaylist,
      icon: const Icon(Icons.add),
      label: const Text('New playlist'),
    ),
    body: FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: _playlists,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Center(child: Text('No playlists yet'));
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final data = docs[index].data();
            final items = data['items'] is List
                ? (data['items'] as List).length
                : 0;
            return Card(
              child: ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.playlist_play_rounded),
                ),
                title: Text('${data['name'] ?? 'Untitled playlist'}'),
                subtitle: Text(
                  '$items saved items  •  ${data['visibility'] ?? 'public'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ViyouPlaylistDetailPage(
                      title: '${data['name'] ?? 'Playlist'}',
                      itemIds: List<String>.from(data['items'] ?? const []),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class ViyouPlaylistDetailPage extends StatelessWidget {
  const ViyouPlaylistDetailPage({
    super.key,
    required this.title,
    required this.itemIds,
  });

  final String title;
  final List<String> itemIds;

  Future<List<BlogRecord>> _loadItems() async {
    final records = <BlogRecord>[];
    for (final id in itemIds) {
      final snapshot = await FirebaseFirestore.instance
          .collection('blogs')
          .doc(id)
          .get();
      if (snapshot.exists && snapshot.data() != null) {
        records.add(BlogRecord.fromMap(snapshot.id, snapshot.data()!));
      }
    }
    return records;
  }

  void _openItem(BuildContext context, BlogRecord post) {
    if (hasPlayableMediaSource(post.video) ||
        hasPlayableMediaSource(post.youtubeUrl)) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ViyouVideoPlayer(video: post)),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff151515),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(22),
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              post.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Text(
              post.content.isEmpty ? 'No description available.' : post.content,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: FutureBuilder<List<BlogRecord>>(
      future: _loadItems(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final posts = snapshot.data ?? const <BlogRecord>[];
        if (posts.isEmpty)
          return const Center(child: Text('This playlist is empty'));
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
          itemCount: posts.length,
          separatorBuilder: (_, __) => const Divider(color: Colors.white12),
          itemBuilder: (context, index) {
            final post = posts[index];
            return ListTile(
              leading: Icon(
                post.isFlicker
                    ? Icons.bolt
                    : post.video != null
                    ? Icons.play_circle_outline
                    : Icons.article_outlined,
              ),
              title: Text(
                post.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('${post.author}  •  ${post.category}'),
              trailing: const Icon(Icons.play_arrow_rounded),
              onTap: () => _openItem(context, post),
            );
          },
        );
      },
    ),
  );
}

class ViyouScheduledPage extends StatelessWidget {
  const ViyouScheduledPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please login to view scheduled content')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled content')),
      body: FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
        future: FirebaseFirestore.instance
            .collection('blogs')
            .where('authorUid', isEqualTo: user.uid)
            .limit(50)
            .get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final posts =
              snapshot.data?.docs
                  .where((doc) => doc.data()['status'] == 'scheduled')
                  .map(BlogRecord.fromDocument)
                  .toList() ??
              [];
          if (posts.isEmpty)
            return const Center(child: Text('No scheduled content'));
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            itemCount: posts.length,
            separatorBuilder: (_, __) => const Divider(color: Colors.white12),
            itemBuilder: (context, index) {
              final post = posts[index];
              return ListTile(
                leading: Icon(
                  post.isFlicker ? Icons.bolt : Icons.schedule_rounded,
                ),
                title: Text(post.title),
                subtitle: Text(
                  post.date.year == 1970
                      ? 'Scheduled'
                      : post.date.toLocal().toString(),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

Future<void> _recordSyncedWatchHistory(String blogId) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;
  try {
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    if (profile.data()?['historyPaused'] == true) return;
    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('watchHistory')
        .doc(blogId)
        .set({
          'blogId': blogId,
          'viewedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  } catch (error) {
    debugPrint('Could not sync watch history: $error');
  }
}

class ViyouHistoryPage extends StatefulWidget {
  const ViyouHistoryPage({super.key});

  @override
  State<ViyouHistoryPage> createState() => _ViyouHistoryPageState();
}

class _ViyouHistoryPageState extends State<ViyouHistoryPage> {
  final Map<String, Future<_HistoryEntry?>> _entries = {};
  bool _busy = false;

  Future<_HistoryEntry?> _loadEntry(
    QueryDocumentSnapshot<Map<String, dynamic>> historyDocument,
  ) {
    final history = historyDocument.data();
    final blogId = '${history['blogId'] ?? historyDocument.id}';
    final viewedAt = history['viewedAt'];
    final cacheKey =
        '$blogId-${viewedAt is Timestamp ? viewedAt.microsecondsSinceEpoch : viewedAt}';
    return _entries.putIfAbsent(cacheKey, () async {
      final post = await FirebaseFirestore.instance
          .collection('blogs')
          .doc(blogId)
          .get();
      if (!post.exists) return null;
      final time = viewedAt is Timestamp
          ? viewedAt.toDate()
          : DateTime.tryParse('$viewedAt') ?? DateTime.now();
      return _HistoryEntry(
        blog: BlogRecord.fromMap(blogId, post.data() ?? const {}),
        viewedAt: time,
      );
    });
  }

  Future<void> _removeHistoryItem(String blogId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('watchHistory')
          .doc(blogId)
          .delete();
    } catch (error) {
      _showHistoryMessage('Could not remove history item: $error');
    }
  }

  Future<void> _clearHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
          'This removes watched videos and Flicks from your synced history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final reference = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('watchHistory');
      final snapshot = await reference.get();
      for (var start = 0; start < snapshot.docs.length; start += 450) {
        final batch = FirebaseFirestore.instance.batch();
        for (final document in snapshot.docs.skip(start).take(450)) {
          batch.delete(document.reference);
        }
        await batch.commit();
      }
      _entries.clear();
    } catch (error) {
      _showHistoryMessage('Could not clear history: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleHistoryPause(bool paused) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _busy) return;
    setState(() => _busy = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'historyPaused': !paused,
      }, SetOptions(merge: true));
    } catch (error) {
      _showHistoryMessage('Could not update history setting: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showHistoryMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Watch History')),
        body: const Center(child: Text('Log in to view synced history')),
      );
    }
    final historyReference = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('watchHistory');
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Watch History'),
          actions: [
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .snapshots(),
              builder: (context, snapshot) {
                final paused = snapshot.data?.data()?['historyPaused'] == true;
                return IconButton(
                  onPressed: _busy ? null : () => _toggleHistoryPause(paused),
                  icon: Icon(
                    paused
                        ? Icons.play_circle_outline
                        : Icons.pause_circle_outline,
                  ),
                  tooltip: paused ? 'Resume history' : 'Pause history',
                );
              },
            ),
            IconButton(
              onPressed: _busy ? null : _clearHistory,
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear all history',
            ),
          ],
          bottom: const TabBar(
            isScrollable: false,
            tabs: [
              Tab(text: 'All History'),
              Tab(text: 'Video History'),
              Tab(text: 'Flicks History'),
            ],
          ),
        ),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: historyReference
              .orderBy('viewedAt', descending: true)
              .limit(100)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text('Could not load history: ${snapshot.error}'),
              );
            }
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final documents = snapshot.data?.docs ?? const [];
            if (documents.isEmpty) {
              return const TabBarView(
                children: [
                  _HistoryEmptyState(),
                  _HistoryEmptyState(),
                  _HistoryEmptyState(),
                ],
              );
            }
            return FutureBuilder<List<_HistoryEntry>>(
              future: Future.wait(documents.map(_loadEntry)).then(
                (entries) =>
                    entries.whereType<_HistoryEntry>().toList()
                      ..sort((a, b) => b.viewedAt.compareTo(a.viewedAt)),
              ),
              builder: (context, entriesSnapshot) {
                if (entriesSnapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (entriesSnapshot.hasError) {
                  return Center(
                    child: Text(
                      'Could not load watched videos: ${entriesSnapshot.error}',
                    ),
                  );
                }
                final entries = entriesSnapshot.data ?? const <_HistoryEntry>[];
                return TabBarView(
                  children: [
                    _historyList(entries, null),
                    _historyList(entries, false),
                    _historyList(entries, true),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _historyList(List<_HistoryEntry> entries, bool? flicksOnly) {
    final filtered = entries.where((entry) {
      if (flicksOnly == null) {
        return entry.blog.isFlicker ||
            entry.blog.video != null ||
            entry.blog.youtubeUrl != null;
      }
      return flicksOnly
          ? entry.blog.isFlicker
          : !entry.blog.isFlicker &&
                (entry.blog.video != null || entry.blog.youtubeUrl != null);
    }).toList();
    if (filtered.isEmpty) {
      return _HistoryEmptyState(
        message: flicksOnly == true
            ? 'No Flicks in your history'
            : flicksOnly == false
            ? 'No videos in your history'
            : 'No watch history yet',
      );
    }

    final grouped = <DateTime, List<_HistoryEntry>>{};
    for (final entry in filtered) {
      final date = DateTime(
        entry.viewedAt.year,
        entry.viewedAt.month,
        entry.viewedAt.day,
      );
      grouped.putIfAbsent(date, () => []).add(entry);
    }
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    final rows = <Widget>[];
    for (final date in dates) {
      rows.add(_HistoryDateHeader(date: date));
      for (final entry in grouped[date]!) {
        rows.add(_historyTile(entry));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
      children: rows,
    );
  }

  Widget _historyTile(_HistoryEntry entry) {
    final blog = entry.blog;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: SizedBox(
          width: 78,
          height: 54,
          child: blog.primaryImage != null
              ? Image.network(blog.primaryImage!, fit: BoxFit.cover)
              : ColoredBox(
                  color: const Color(0xff202020),
                  child: Icon(
                    blog.isFlicker
                        ? Icons.bolt_rounded
                        : Icons.play_arrow_rounded,
                    color: blog.isFlicker
                        ? const Color(0xffff0050)
                        : Colors.white,
                  ),
                ),
        ),
      ),
      title: Text(blog.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${blog.author}  •  ${_historyTime(entry.viewedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          if (action == 'remove') _removeHistoryItem(blog.id);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'remove', child: Text('Remove from history')),
        ],
      ),
      onTap: () => Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => ViyouVideoPlayer(video: blog)),
      ),
    );
  }

  String _historyTime(DateTime time) =>
      '${time.hour % 12 == 0 ? 12 : time.hour % 12}:${time.minute.toString().padLeft(2, '0')} ${time.hour >= 12 ? 'PM' : 'AM'}';
}

class _HistoryEntry {
  const _HistoryEntry({required this.blog, required this.viewedAt});

  final BlogRecord blog;
  final DateTime viewedAt;
}

class _HistoryEmptyState extends StatelessWidget {
  const _HistoryEmptyState({this.message = 'No watch history yet'});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.history_rounded, size: 40, color: Colors.grey[600]),
        const SizedBox(height: 10),
        Text(message, style: TextStyle(color: Colors.grey[400])),
      ],
    ),
  );
}

class _HistoryDateHeader extends StatelessWidget {
  const _HistoryDateHeader({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final age = today.difference(date).inDays;
    final label = age == 0
        ? 'Today'
        : age == 1
        ? 'Yesterday'
        : age < 7
        ? const [
            'Monday',
            'Tuesday',
            'Wednesday',
            'Thursday',
            'Friday',
            'Saturday',
            'Sunday',
          ][date.weekday - 1]
        : '${date.day} ${const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][date.month - 1]} ${date.year}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 7),
      child: Text(
        label,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class ViyouSettingsHubPage extends StatelessWidget {
  const ViyouSettingsHubPage({super.key, required this.onLogin});

  final Future<void> Function() onLogin;

  Future<void> _openPage(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri))
      await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: Text(
            'Account',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white60,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.edit_outlined)),
            title: const Text('Edit profile'),
            subtitle: const Text('Update your name, username and bio'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ViyouSettingsPage()),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.history_rounded)),
            title: const Text('Watch History'),
            subtitle: const Text('Videos and Flicks you have watched'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ViyouHistoryPage()),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.insights_rounded)),
            title: const Text('Creator Studio'),
            subtitle: const Text('Views, content, promotions and wallet'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const ViyouStudioDashboardPage(),
              ),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: Icon(
              FirebaseAuth.instance.currentUser == null
                  ? Icons.login_rounded
                  : Icons.logout_rounded,
            ),
            title: Text(
              FirebaseAuth.instance.currentUser == null ? 'Login' : 'Logout',
            ),
            subtitle: Text(
              FirebaseAuth.instance.currentUser == null
                  ? 'Sync your profile and content'
                  : 'Sign out of this account',
            ),
            onTap: () async {
              if (FirebaseAuth.instance.currentUser == null) {
                await onLogin();
              } else {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ),
        const SizedBox(height: 20),
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: Text(
            'Viyou',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white60,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _link(
          context,
          Icons.info_outline,
          'About Viyou',
          'https://viyou.in/about-us.html',
        ),
        _link(
          context,
          Icons.shield_outlined,
          'Privacy Policy',
          'https://viyou.in/privacy.html',
        ),
        _link(
          context,
          Icons.description_outlined,
          'Terms of Service',
          'https://viyou.in/terms.html',
        ),
        _link(
          context,
          Icons.account_balance_outlined,
          'Monetization Policy',
          'https://viyou.in/monetization-policy.html',
        ),
        _link(
          context,
          Icons.mail_outline,
          'Contact Us',
          'https://viyou.in/contact-us.html',
        ),
        _link(
          context,
          Icons.campaign_outlined,
          'Advertise with Us',
          'https://viyou.in/advertise.html',
        ),
      ],
    ),
  );

  Widget _link(BuildContext context, IconData icon, String title, String url) =>
      Card(
        child: ListTile(
          leading: Icon(icon),
          title: Text(title),
          trailing: const Icon(Icons.open_in_new, size: 19),
          onTap: () => _openPage(url),
        ),
      );
}

class ViyouSettingsPage extends StatefulWidget {
  const ViyouSettingsPage({super.key});

  @override
  State<ViyouSettingsPage> createState() => _ViyouSettingsPageState();
}

class _ViyouSettingsPageState extends State<ViyouSettingsPage> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _bio = TextEditingController();
  bool _loading = true;
  bool _hideStories = false;
  bool _restrictUnknown = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final data = snap.data() ?? {};
      _name.text = '${data['name'] ?? user.displayName ?? ''}';
      _username.text = '${data['username'] ?? ''}';
      _bio.text = '${data['bio'] ?? ''}';
      _hideStories = List.from(data['hiddenStoryFrom'] ?? const []).isNotEmpty;
      _restrictUnknown = List.from(data['blockedUsers'] ?? const []).isNotEmpty;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'name': _name.text.trim(),
      'username': _username.text.trim(),
      'usernameLower': _username.text.trim().toLowerCase(),
      'bio': _bio.text.trim(),
    }, SetOptions(merge: true));
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile saved')));
  }

  Future<void> _togglePrivacy(String field, bool value) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() {
      if (field == 'hiddenStoryFrom')
        _hideStories = value;
      else
        _restrictUnknown = value;
    });
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      field: value ? ['__managed_from_app__'] : [],
    }, SetOptions(merge: true));
  }

  Future<void> _createPlaylist() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final controller = TextEditingController();
    final create = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Create playlist'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (create == true && controller.text.trim().isNotEmpty) {
      await FirebaseFirestore.instance.collection('playlists').add({
        'authorUid': user.uid,
        'authorName': _name.text.trim(),
        'name': controller.text.trim(),
        'description': '',
        'visibility': 'public',
        'items': [],
        'createdAt': DateTime.now().toIso8601String(),
      });
    }
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const Text(
                'Edit profile',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Display name'),
              ),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Unique ID'),
              ),
              TextField(
                controller: _bio,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Bio'),
              ),
              const SizedBox(height: 18),
              FilledButton(onPressed: _save, child: const Text('Save profile')),
              const SizedBox(height: 24),
              const Text(
                'Privacy controls',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              SwitchListTile(
                title: const Text('Hide stories list configured'),
                value: _hideStories,
                onChanged: (value) => _togglePrivacy('hiddenStoryFrom', value),
              ),
              SwitchListTile(
                title: const Text('Restricted accounts list configured'),
                value: _restrictUnknown,
                onChanged: (value) => _togglePrivacy('blockedUsers', value),
              ),
              const SizedBox(height: 20),
              const Text(
                'Playlists',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              FilledButton.icon(
                onPressed: _createPlaylist,
                icon: const Icon(Icons.playlist_add),
                label: const Text('Create playlist'),
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Colors.redAccent,
                ),
                title: const Text('Delete account'),
                onTap: () {},
              ),
            ],
          ),
  );
}

class ViyouCreatorStudioPage extends StatelessWidget {
  const ViyouCreatorStudioPage({super.key});

  Future<Map<String, dynamic>> _load() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return {};
    final snap = await FirebaseFirestore.instance
        .collection('blogs')
        .where('authorUid', isEqualTo: user.uid)
        .get();
    var views = 0;
    var longViews = 0;
    var flickViews = 0;
    for (final doc in snap.docs) {
      final data = doc.data();
      final count = (data['views'] as num?)?.toInt() ?? 0;
      views += count;
      if (data['isFlicker'] == true)
        flickViews += count;
      else if (data['video'] != null || data['youtubeUrl'] != null)
        longViews += count;
    }
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final followers = ((profile.data()?['followers'] as List?)?.length ?? 0);
    return {
      'posts': snap.size,
      'views': views,
      'longViews': longViews,
      'flickViews': flickViews,
      'followers': followers,
      'wallet': profile.data()?['walletBalance'] ?? 0,
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Creator Studio')),
    body: FutureBuilder<Map<String, dynamic>>(
      future: _load(),
      builder: (context, snapshot) {
        final data = snapshot.data ?? {};
        if (snapshot.connectionState == ConnectionState.waiting)
          return const Center(child: CircularProgressIndicator());
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Overview',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            _stat('Total views', data['views'] ?? 0, Icons.visibility_outlined),
            _stat(
              'Long video views',
              data['longViews'] ?? 0,
              Icons.play_circle_outline,
            ),
            _stat('Flicks views', data['flickViews'] ?? 0, Icons.bolt),
            _stat('Followers', data['followers'] ?? 0, Icons.people_outline),
            _stat(
              'Published content',
              data['posts'] ?? 0,
              Icons.video_library_outlined,
            ),
            _stat(
              'Wallet balance',
              '₹${data['wallet'] ?? 0}',
              Icons.account_balance_wallet_outlined,
            ),
            const SizedBox(height: 18),
            const Text(
              'Content, monetization, promotions and payment data are read from the same Firebase project as the website.',
              style: TextStyle(color: Colors.white60),
            ),
          ],
        );
      },
    ),
  );

  Widget _stat(String title, Object value, IconData icon) => Card(
    color: const Color(0xff101010),
    child: ListTile(
      leading: Icon(icon, color: const Color(0xfff59e0b)),
      title: Text(title),
      trailing: Text(
        '$value',
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
    ),
  );
}

class ViyouStudioDashboardPage extends StatefulWidget {
  const ViyouStudioDashboardPage({super.key});

  @override
  State<ViyouStudioDashboardPage> createState() =>
      _ViyouStudioDashboardPageState();
}

class _ViyouStudioDashboardPageState extends State<ViyouStudioDashboardPage> {
  int _section = 0;
  static const List<String> _promoCategories = [
    'Entertainment',
    'Music',
    'Vlogs',
    'Gaming',
    'Education',
    'Sports',
    'News & Politics',
    'Science & Technology',
    'Fashion & Beauty',
    'Comedy',
    'Travel & Events',
    'Food',
    'Devotional',
    'Gym & Fitness',
    'Health',
    'Podcasts',
  ];

  Future<Map<String, dynamic>> _loadDashboard() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return {};
    final posts = await FirebaseFirestore.instance
        .collection('blogs')
        .where('authorUid', isEqualTo: user.uid)
        .get();
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    var views = 0;
    var longViews = 0;
    var flickViews = 0;
    for (final post in posts.docs) {
      final data = post.data();
      final count = (data['views'] as num?)?.toInt() ?? 0;
      views += count;
      if (data['isFlicker'] == true) flickViews += count;
      if (data['video'] != null || data['youtubeUrl'] != null)
        longViews += count;
    }
    final paymentHistory = profile.data()?['paymentHistory'];
    final monetization = await FirebaseFirestore.instance
        .collection('settings')
        .doc('monetization')
        .get();
    final promotions = await FirebaseFirestore.instance
        .collection('settings')
        .doc('promotions')
        .get();
    return {
      'posts': posts.size,
      'views': views,
      'longViews': longViews,
      'flickViews': flickViews,
      'followers': (profile.data()?['followers'] as List?)?.length ?? 0,
      'wallet': profile.data()?['walletBalance'] ?? 0,
      'postDocs': posts.docs,
      'profile': profile.data() ?? const <String, dynamic>{},
      'paymentHistory': paymentHistory is List ? paymentHistory : const [],
      'monetization': monetization.data() ?? const <String, dynamic>{},
      'promotions': promotions.data() ?? const <String, dynamic>{},
    };
  }

  Future<List<String>> _compressGalleryImages(List<XFile> files) async {
    final compressed = <String>[];
    for (final file in files) {
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) continue;
      final resized = img.copyResize(decoded, width: 1200);
      var quality = 90;
      List<int> bytes = img.encodeJpg(resized, quality: quality);
      while (bytes.length > 200000 && quality > 12) {
        quality -= 5;
        bytes = img.encodeJpg(resized, quality: quality);
      }
      if (bytes.length <= 200000) {
        compressed.add('data:image/jpeg;base64,${base64Encode(bytes)}');
      }
    }
    return compressed;
  }

  Future<String?> _compressSingleImage(XFile file) async {
    final decoded = img.decodeImage(await file.readAsBytes());
    if (decoded == null) return null;
    final resized = img.copyResize(decoded, width: 1200);
    var quality = 90;
    List<int> bytes = img.encodeJpg(resized, quality: quality);
    while (bytes.length > 200000 && quality > 12) {
      quality -= 5;
      bytes = img.encodeJpg(resized, quality: quality);
    }
    return bytes.length <= 200000
        ? 'data:image/jpeg;base64,${base64Encode(bytes)}'
        : null;
  }

  Future<void> _requestPromotion() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final settings = await FirebaseFirestore.instance
        .collection('settings')
        .doc('promotions')
        .get();
    final promoSettings = settings.data() ?? const <String, dynamic>{};
    final pricing = Map<String, dynamic>.from(
      promoSettings['pricing'] ?? const {},
    );
    final baseHours = (pricing['baseHours'] as num?)?.toInt() ?? 50;
    final tier4 = (pricing['tier4'] as num?)?.toInt() ?? 50;
    final tier3 = (pricing['tier3'] as num?)?.toInt() ?? 70;
    final tier2 = (pricing['tier2'] as num?)?.toInt() ?? 80;
    final tier1 = (pricing['tier1'] as num?)?.toInt() ?? 100;
    final upiId = '${promoSettings['upiId'] ?? 'himanshusainiaggarwal@okaxis'}';
    final qrCodeUrl = '${promoSettings['qrCodeUrl'] ?? ''}';
    final prerollRate = (promoSettings['prerollRate'] as num?)?.toInt() ?? 100;
    final blogAdRate = (promoSettings['blogAdRate'] as num?)?.toInt() ?? 100;

    String selectedTab = 'infeed';
    final titleCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final utrCtrl = TextEditingController();
    final hoursCtrl = TextEditingController(text: '$baseHours');
    final budgetCtrl = TextEditingController(text: '$prerollRate');
    final categories = <String>[];
    final inFeedImages = <String>[];
    XFile? prerollVideo;
    XFile? blogVideo;
    XFile? paymentScreenshot;
    int selectedTier = 4;
    var totalAmount = tier4;

    Future<void> pickInFeedImages() async {
      final picker = ImagePicker();
      final files = await picker.pickMultiImage();
      if (files.isEmpty) return;
      if (files.length > 5) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Select between 1 and 5 images only')),
          );
        }
        return;
      }
      final compressed = await _compressGalleryImages(files);
      if (compressed.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Images could not be compressed under 200 KB'),
            ),
          );
        }
        return;
      }
      inFeedImages.clear();
      inFeedImages.addAll(compressed);
    }

    Future<void> pickVideoFor(String mode) async {
      final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      if (mode == 'preroll') {
        prerollVideo = file;
      } else {
        blogVideo = file;
      }
    }

    final dynamic totalPriceFromCurrentTab = () {
      if (selectedTab == 'infeed') {
        final tierPrice = switch (selectedTier) {
          3 => tier3,
          2 => tier2,
          1 => tier1,
          _ => tier4,
        };
        final hours = int.tryParse(hoursCtrl.text) ?? baseHours;
        totalAmount = tierPrice * ((hours / baseHours).ceil());
      } else if (selectedTab == 'preroll') {
        final budget = int.tryParse(budgetCtrl.text) ?? prerollRate;
        totalAmount = budget;
      } else {
        final budget = int.tryParse(budgetCtrl.text) ?? blogAdRate;
        totalAmount = budget;
      }
      return totalAmount;
    };

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          final activeTabStyle = BoxDecoration(
            color: const Color(0xfff59e0b),
            borderRadius: BorderRadius.circular(8),
          );
          final inertTabStyle = BoxDecoration(
            color: const Color(0xff1a1a1a),
            borderRadius: BorderRadius.circular(8),
          );

          return AlertDialog(
            backgroundColor: const Color(0xff101010),
            title: const Text('Promote Product Ad'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => selectedTab = 'infeed'),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 12,
                              ),
                              decoration: selectedTab == 'infeed'
                                  ? activeTabStyle
                                  : inertTabStyle,
                              child: const Text(
                                'In-Feed Ad',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                setState(() => selectedTab = 'preroll'),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 12,
                              ),
                              decoration: selectedTab == 'preroll'
                                  ? activeTabStyle
                                  : inertTabStyle,
                              child: const Text(
                                'Pre-Roll',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => selectedTab = 'blogad'),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 12,
                              ),
                              decoration: selectedTab == 'blogad'
                                  ? activeTabStyle
                                  : inertTabStyle,
                              child: const Text(
                                'Blog Ad',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (selectedTab == 'infeed') ...[
                      TextField(
                        controller: titleCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Ad title / product name',
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: pickInFeedImages,
                          icon: const Icon(Icons.image_outlined),
                          label: Text(
                            inFeedImages.isEmpty
                                ? 'Select 1-5 images'
                                : '${inFeedImages.length} image(s) selected',
                          ),
                        ),
                      ),
                      if (inFeedImages.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 12),
                          child: SizedBox(
                            height: 90,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: inFeedImages.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (context, index) => ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.memory(
                                  base64Decode(
                                    inFeedImages[index].split(',').last,
                                  ),
                                  width: 110,
                                  height: 90,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Target URL',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        value: selectedTier,
                        decoration: const InputDecoration(
                          labelText: 'Promotion frequency',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 4,
                            child: Text('Every 4th post (₹50 / 50 Hrs)'),
                          ),
                          DropdownMenuItem(
                            value: 3,
                            child: Text('Every 3rd post (₹70 / 50 Hrs)'),
                          ),
                          DropdownMenuItem(
                            value: 2,
                            child: Text('Every 2nd post (₹80 / 50 Hrs)'),
                          ),
                          DropdownMenuItem(
                            value: 1,
                            child: Text('Every 1st post (₹100 / 50 Hrs)'),
                          ),
                        ],
                        onChanged: (value) =>
                            setState(() => selectedTier = value ?? 4),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: hoursCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Duration (Hours) - Minimum $baseHours',
                        ),
                      ),
                    ] else if (selectedTab == 'preroll') ...[
                      TextField(
                        controller: titleCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Ad title / product name',
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => pickVideoFor('preroll'),
                          icon: const Icon(Icons.play_circle_outline),
                          label: Text(
                            prerollVideo == null
                                ? 'Select pre-roll video'
                                : 'Video selected',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Target URL',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: budgetCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Budget amount (₹)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Target categories (max 5)',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _promoCategories.map((category) {
                          final selected = categories.contains(category);
                          return ChoiceChip(
                            label: Text(category),
                            selected: selected,
                            onSelected: (_) {
                              setState(() {
                                if (selected) {
                                  categories.remove(category);
                                } else {
                                  if (categories.length < 5)
                                    categories.add(category);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                    ] else ...[
                      TextField(
                        controller: titleCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Ad title / product name',
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => pickVideoFor('blogad'),
                          icon: const Icon(Icons.article_outlined),
                          label: Text(
                            blogVideo == null
                                ? 'Select blog ad video'
                                : 'Video selected',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Target URL',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: budgetCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Budget amount (₹)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Target categories (max 5)',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _promoCategories.map((category) {
                          final selected = categories.contains(category);
                          return ChoiceChip(
                            label: Text(category),
                            selected: selected,
                            onSelected: (_) {
                              setState(() {
                                if (selected) {
                                  categories.remove(category);
                                } else {
                                  if (categories.length < 5)
                                    categories.add(category);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xff161616),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xfff59e0b).withOpacity(0.4),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Total Payable Amount',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '₹${totalPriceFromCurrentTab()}',
                            style: const TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              color: Color(0xff10b981),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xff181818),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            upiId,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (qrCodeUrl.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: SizedBox(
                                width: 150,
                                height: 150,
                                child: Image.network(
                                  qrCodeUrl,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: utrCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Transaction ID / UTR number',
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final screenshot = await ImagePicker().pickImage(
                          source: ImageSource.gallery,
                        );
                        if (screenshot != null) paymentScreenshot = screenshot;
                      },
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('Attach payment screenshot (optional)'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  final title = titleCtrl.text.trim();
                  final url = urlCtrl.text.trim();
                  final utr = utrCtrl.text.trim();
                  if (title.isEmpty || url.isEmpty || utr.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Please add title, URL and transaction ID',
                        ),
                      ),
                    );
                    return;
                  }
                  if (selectedTab == 'infeed' && inFeedImages.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Please select 1 to 5 images for the in-feed ad',
                        ),
                      ),
                    );
                    return;
                  }
                  if ((selectedTab == 'preroll' || selectedTab == 'blogad') &&
                      categories.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Select up to 5 target categories'),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(dialogContext, true);
                },
                child: const Text('Submit request'),
              ),
            ],
          );
        },
      ),
    );

    if (result != true) return;

    final campaignTitle = titleCtrl.text.trim();
    final targetUrl = urlCtrl.text.trim();
    final utr = utrCtrl.text.trim();
    final campaignType = switch (selectedTab) {
      'infeed' => 'external',
      'preroll' => 'preroll',
      'blogad' => 'blog_ad',
      _ => 'external',
    };

    var requestPayload = <String, dynamic>{
      'uid': user.uid,
      'title': campaignTitle,
      'type': campaignType,
      'targetUrl': targetUrl,
      'price': totalAmount,
      'utr': utr,
      'paymentScreenshot': paymentScreenshot == null
          ? null
          : await _compressSingleImage(paymentScreenshot!),
      'status': 'pending',
      'timestamp': FieldValue.serverTimestamp(),
    };

    if (selectedTab == 'infeed') {
      final compressedGallery = await _compressGalleryImages(
        inFeedImages
            .map((image) => XFile.fromData(base64Decode(image.split(',').last)))
            .toList(),
      );
      requestPayload.addAll({
        'mediaType': 'image',
        'mediaGallery': compressedGallery,
        'mediaData': compressedGallery.first,
        'frequency': selectedTier,
        'hours': int.tryParse(hoursCtrl.text) ?? baseHours,
      });
    } else {
      final budget =
          int.tryParse(budgetCtrl.text) ??
          (selectedTab == 'preroll' ? prerollRate : blogAdRate);
      requestPayload.addAll({
        'targetCategories': categories,
        'impressions_goal':
            ((budget / (selectedTab == 'preroll' ? prerollRate : blogAdRate)) *
                    1000)
                .round(),
        'impressions_served': 0,
        'budget': budget,
      });
      if (selectedTab == 'preroll' && prerollVideo != null) {
        requestPayload['mediaType'] = 'video';
        requestPayload['mediaData'] = await _compressSingleImage(prerollVideo!);
      }
      if (selectedTab == 'blogad' && blogVideo != null) {
        requestPayload['mediaType'] = 'video';
        requestPayload['mediaData'] = await _compressSingleImage(blogVideo!);
      }
    }

    await FirebaseFirestore.instance
        .collection('promotions')
        .add(requestPayload);
    if (mounted) _showStudioMessage('Promotion request sent for admin review');
    titleCtrl.dispose();
    urlCtrl.dispose();
    utrCtrl.dispose();
    hoursCtrl.dispose();
    budgetCtrl.dispose();
  }

  void _showStudioMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 980;
    return Scaffold(
      backgroundColor: const Color(0xff050505),
      body: SafeArea(
        child: FutureBuilder<Map<String, dynamic>>(
          future: _loadDashboard(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snapshot.data ?? {};
            final posts =
                (data['postDocs']
                    as List<QueryDocumentSnapshot<Map<String, dynamic>>>? ??
                const []);

            final sidebar = Container(
              width: isWide ? 260 : null,
              padding: EdgeInsets.all(isWide ? 16 : 12),
              decoration: BoxDecoration(
                color: const Color(0xff0d0d0d),
                border: isWide
                    ? const Border(right: BorderSide(color: Color(0xff1f1f1f)))
                    : const Border(
                        bottom: BorderSide(color: Color(0xff1f1f1f)),
                      ),
              ),
              child: isWide
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Icon(
                              Icons.auto_awesome_rounded,
                              color: Color(0xfff59e0b),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Viyou Studio',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _studioNavItem(0, Icons.dashboard_outlined, 'Overview'),
                        _studioNavItem(
                          1,
                          Icons.video_library_outlined,
                          'Content',
                        ),
                        _studioNavItem(
                          2,
                          Icons.wallet_outlined,
                          'Monetization',
                        ),
                        _studioNavItem(
                          3,
                          Icons.campaign_outlined,
                          'Promotions',
                        ),
                        _studioNavItem(
                          4,
                          Icons.receipt_long_outlined,
                          'Payments',
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back_rounded),
                          label: const Text('Back to profile'),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Icon(
                              Icons.auto_awesome_rounded,
                              color: Color(0xfff59e0b),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Viyou Studio',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 62,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              _studioNavItem(
                                0,
                                Icons.dashboard_outlined,
                                'Overview',
                              ),
                              _studioNavItem(
                                1,
                                Icons.video_library_outlined,
                                'Content',
                              ),
                              _studioNavItem(
                                2,
                                Icons.wallet_outlined,
                                'Monetization',
                              ),
                              _studioNavItem(
                                3,
                                Icons.campaign_outlined,
                                'Promotions',
                              ),
                              _studioNavItem(
                                4,
                                Icons.receipt_long_outlined,
                                'Payments',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.arrow_back_rounded),
                            label: const Text('Back to profile'),
                          ),
                        ),
                      ],
                    ),
            );

            final content = Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 40),
                children: [
                  const Text(
                    'Creator workspace',
                    style: TextStyle(
                      color: Color(0xfff59e0b),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Creator Studio',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A clear view of your audience, content and earnings.',
                    style: TextStyle(color: Colors.white60),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _studioStatCard(
                              'Total views',
                              '${data['views'] ?? 0}',
                              Icons.visibility_outlined,
                            ),
                            _studioStatCard(
                              'Long video views',
                              '${data['longViews'] ?? 0}',
                              Icons.play_circle_outline,
                            ),
                            _studioStatCard(
                              'Flicks views',
                              '${data['flickViews'] ?? 0}',
                              Icons.bolt_rounded,
                            ),
                            _studioStatCard(
                              'Followers',
                              '${data['followers'] ?? 0}',
                              Icons.people_outline,
                            ),
                            _studioStatCard(
                              'Wallet balance',
                              '₹${data['wallet'] ?? 0}',
                              Icons.account_balance_wallet_outlined,
                            ),
                            _studioStatCard(
                              'Revenue tier',
                              data['profile']?['revenueTier'] ?? 'Not eligible',
                              Icons.trending_up_rounded,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (_section == 0) _overview(data),
                  if (_section == 1) _content(data, posts),
                  if (_section == 2) _monetization(data),
                  if (_section == 3) _promotionsPanel(),
                  if (_section == 4) _payments(data),
                ],
              ),
            );

            return isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [sidebar, content],
                  )
                : Column(children: [sidebar, content]);
          },
        ),
      ),
    );
  }

  Widget _studioNavItem(int value, IconData icon, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: _section == value ? const Color(0xfff59e0b) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _section = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: _section == value ? Colors.black : Colors.white,
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _section == value ? Colors.black : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _studioStatCard(String title, String value, IconData icon) =>
      Container(
        width: 220,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xff101010),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xff202020)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xfff59e0b)),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      );

  Widget _overview(Map<String, dynamic> data) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _studioSectionCard(
        title: 'Monetization status',
        content: _metricRow(
          'Status',
          data['profile']?['isMonetized'] == true ? 'Active' : 'Not eligible',
        ),
      ),
      const SizedBox(height: 18),
      _studioSectionCard(
        title: 'Growth analytics',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metricRow(
              'Estimated earnings',
              '₹${data['profile']?['estimatedEarnings'] ?? 0}',
            ),
            const SizedBox(height: 8),
            _metricRow('Wallet balance', '₹${data['wallet'] ?? 0}'),
          ],
        ),
      ),
    ],
  );

  Widget _content(
    Map<String, dynamic> data,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> posts,
  ) => _studioSectionCard(
    title: 'Content performance',
    content: posts.isEmpty
        ? const Text('No posts yet')
        : Column(
            children: posts.map((post) {
              final item = post.data();
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xff101010),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: const Color(0xff1a1a1a),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        item['isFlicker'] == true
                            ? Icons.bolt_rounded
                            : Icons.video_library_outlined,
                        color: const Color(0xfff59e0b),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${item['title'] ?? 'Untitled'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${item['views'] ?? 0} views • ${(item['likes'] as List?)?.length ?? 0} likes',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${item['status'] ?? 'published'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff10b981),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
  );

  Widget _monetization(Map<String, dynamic> data) => _studioSectionCard(
    title: 'Monetization overview',
    content: Column(
      children: [
        _metricRow(
          'Active status',
          data['profile']?['isMonetized'] == true ? 'Active' : 'Not eligible',
        ),
        const SizedBox(height: 12),
        _metricRow(
          'Estimated earnings',
          '₹${data['profile']?['estimatedEarnings'] ?? 0}',
        ),
        const SizedBox(height: 12),
        _metricRow('Wallet balance', '₹${data['wallet'] ?? 0}'),
      ],
    ),
  );

  Widget _promotionsPanel() => _studioSectionCard(
    title: 'Promotion types',
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Run campaigns across the same placements used by Viyou web.',
          style: TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 18),
        _promotionTypeRow(
          Icons.view_stream_outlined,
          'In-feed ads',
          'Appear between feed posts.',
        ),
        _promotionTypeRow(
          Icons.article_outlined,
          'In-blog ads',
          'Appear inside blog reading flow.',
        ),
        _promotionTypeRow(
          Icons.play_circle_outline,
          'Long video pre-roll',
          'Play before eligible long videos.',
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _requestPromotion,
            icon: const Icon(Icons.campaign_outlined),
            label: const Text('Request promotion'),
          ),
        ),
      ],
    ),
  );

  Widget _payments(Map<String, dynamic> data) {
    final history = data['paymentHistory'] as List? ?? const [];
    return _studioSectionCard(
      title: 'Payment history',
      content: history.isEmpty
          ? const Text('No payments yet')
          : Column(
              children: history
                  .map(
                    (item) => Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xff101010),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${item['type'] ?? 'Payment'}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${item['date'] ?? ''}',
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '₹${item['amount'] ?? 0}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Color(0xff10b981),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
    );
  }

  Widget _studioSectionCard({required String title, required Widget content}) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 18),
        decoration: BoxDecoration(
          color: const Color(0xff101010),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xff1a1a1a)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            content,
          ],
        ),
      );

  Widget _metricRow(String label, String value) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: const TextStyle(color: Colors.white60)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ],
  );

  Widget _promotionTypeRow(IconData icon, String title, String subtitle) =>
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xff161616),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xfff59e0b)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class ViyouAdminPage extends StatefulWidget {
  const ViyouAdminPage({super.key});

  @override
  State<ViyouAdminPage> createState() => _ViyouAdminPageState();
}

class _ViyouAdminPageState extends State<ViyouAdminPage> {
  final _tier4 = TextEditingController();
  final _tier3 = TextEditingController();
  final _tier2 = TextEditingController();
  final _prerollRate = TextEditingController();
  final _blogAdRate = TextEditingController();
  final _promoUpiId = TextEditingController();
  final _promoQrCodeUrl = TextEditingController();
  bool _allowed = false;
  bool _loading = true;
  bool _showAds = true;
  bool _enableInFeedAds = true;
  bool _enablePreRollAds = true;

  @override
  void initState() {
    super.initState();
    _loadAdmin();
  }

  Future<void> _loadAdmin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      _allowed =
          profile.data()?['isAdmin'] == true ||
          profile.data()?['adminPermissions']?['isSuperAdmin'] == true;
      final settings = await FirebaseFirestore.instance
          .collection('settings')
          .doc('promotions')
          .get();
      final pricing = Map<String, dynamic>.from(
        settings.data()?['pricing'] ?? const {},
      );
      _tier4.text = '${pricing['tier4'] ?? 50}';
      _tier3.text = '${pricing['tier3'] ?? 70}';
      _tier2.text = '${pricing['tier2'] ?? 80}';
      _prerollRate.text = '${settings.data()?['prerollRate'] ?? 200}';
      _blogAdRate.text = '${settings.data()?['blogAdRate'] ?? 150}';
      _promoUpiId.text =
          '${settings.data()?['upiId'] ?? 'himanshusainiaggarwal@okaxis'}';
      _promoQrCodeUrl.text = '${settings.data()?['qrCodeUrl'] ?? ''}';
      final ads = await FirebaseFirestore.instance
          .collection('settings')
          .doc('ads')
          .get();
      _showAds = ads.data()?['showAds'] ?? true;
      _enableInFeedAds = ads.data()?['enableInFeedAds'] ?? true;
      _enablePreRollAds = ads.data()?['enablePreRollAds'] ?? true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _savePricing() async {
    await FirebaseFirestore.instance
        .collection('settings')
        .doc('promotions')
        .set({
          'pricing': {
            'tier4': int.tryParse(_tier4.text) ?? 50,
            'tier3': int.tryParse(_tier3.text) ?? 70,
            'tier2': int.tryParse(_tier2.text) ?? 80,
          },
          'prerollRate': int.tryParse(_prerollRate.text) ?? 200,
          'blogAdRate': int.tryParse(_blogAdRate.text) ?? 150,
          'upiId': _promoUpiId.text.trim(),
          'qrCodeUrl': _promoQrCodeUrl.text.trim(),
        }, SetOptions(merge: true));
    await FirebaseFirestore.instance.collection('settings').doc('ads').set({
      'showAds': _showAds,
      'enableInFeedAds': _enableInFeedAds,
      'enablePreRollAds': _enablePreRollAds,
    }, SetOptions(merge: true));
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pricing synced to website and app')),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!_allowed)
      return const Scaffold(body: Center(child: Text('Admin access denied')));
    return Scaffold(
      appBar: AppBar(title: const Text('Viyou Admin Panel')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Promotion pricing',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          TextField(
            controller: _tier4,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Tier 4 price'),
          ),
          TextField(
            controller: _tier3,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Tier 3 price'),
          ),
          TextField(
            controller: _tier2,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Tier 2 price'),
          ),
          TextField(
            controller: _prerollRate,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Pre-roll rate'),
          ),
          TextField(
            controller: _blogAdRate,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'In-blog ad rate'),
          ),
          TextField(
            controller: _promoUpiId,
            decoration: const InputDecoration(
              labelText: 'UPI ID for brand promotions',
            ),
          ),
          TextField(
            controller: _promoQrCodeUrl,
            decoration: const InputDecoration(
              labelText: 'QR code URL for brand promotions',
            ),
          ),
          SwitchListTile(
            title: const Text('Show ads'),
            value: _showAds,
            onChanged: (value) => setState(() => _showAds = value),
          ),
          SwitchListTile(
            title: const Text('Enable in-feed ads'),
            value: _enableInFeedAds,
            onChanged: (value) => setState(() => _enableInFeedAds = value),
          ),
          SwitchListTile(
            title: const Text('Enable pre-roll ads'),
            value: _enablePreRollAds,
            onChanged: (value) => setState(() => _enablePreRollAds = value),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _savePricing,
            child: const Text('Save pricing'),
          ),
          const SizedBox(height: 24),
          const Text(
            'Pending promotions',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('promotions')
                .where('status', isEqualTo: 'pending')
                .snapshots(),
            builder: (context, snapshot) {
              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty)
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No pending requests'),
                );
              return Column(
                children: docs.map((doc) {
                  final data = doc.data();
                  return ListTile(
                    title: Text('${data['blogId'] ?? 'Content'}'),
                    subtitle: Text(
                      '₹${data['price'] ?? 0} • Every ${data['frequency'] ?? 4} posts',
                    ),
                    trailing: FilledButton(
                      onPressed: () async {
                        await doc.reference.update({
                          'status': 'approved',
                          'approvedAt': DateTime.now().toIso8601String(),
                        });
                        final blogId = data['blogId'];
                        if (blogId is String && blogId.isNotEmpty) {
                          await FirebaseFirestore.instance
                              .collection('blogs')
                              .doc(blogId)
                              .set({
                                'isPromoted': true,
                                'promoFrequency':
                                    (data['frequency'] as num?)?.toInt() ?? 4,
                                'promoExpiry': DateTime.now()
                                    .add(
                                      Duration(
                                        hours:
                                            (data['hours'] as num?)?.toInt() ??
                                            24,
                                      ),
                                    )
                                    .toIso8601String(),
                              }, SetOptions(merge: true));
                        }
                      },
                      child: const Text('Approve'),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PublicPostTile extends StatelessWidget {
  const _PublicPostTile({required this.blog});
  final BlogRecord blog;

  @override
  Widget build(BuildContext context) {
    final media = blog.primaryImage;
    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 58,
          height: 58,
          child: media != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _PublicMediaPreview(source: media),
                )
              : Icon(blog.isFlicker ? Icons.bolt : Icons.article_outlined),
        ),
        title: Text(blog.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text('${blog.category}  •  ${blog.author}'),
        trailing: Icon(
          blog.video != null || blog.youtubeUrl != null
              ? Icons.play_arrow_rounded
              : Icons.chevron_right,
        ),
        onTap: () {
          if (hasPlayableMediaSource(blog.video) ||
              hasPlayableMediaSource(blog.youtubeUrl)) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ViyouVideoPlayer(video: blog)),
            );
          } else {
            showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              backgroundColor: const Color(0xff151515),
              builder: (_) => Padding(
                padding: const EdgeInsets.all(20),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (blog.imageSources.isNotEmpty)
                      _BlogImageCarousel(images: blog.imageSources),
                    const SizedBox(height: 16),
                    Text(
                      blog.title,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      blog.content.isEmpty
                          ? 'No description available.'
                          : blog.content,
                    ),
                  ],
                ),
              ),
            );
          }
        },
      ),
    );
  }
}

class _PublicMediaPreview extends StatelessWidget {
  const _PublicMediaPreview({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    if (source.startsWith('data:image/')) {
      final comma = source.indexOf(',');
      if (comma > 0) {
        return Image.memory(
          base64Decode(source.substring(comma + 1)),
          fit: BoxFit.cover,
        );
      }
    }
    return Image.network(source, fit: BoxFit.cover);
  }
}

class BlogComments extends StatefulWidget {
  const BlogComments({super.key, required this.blog});
  final BlogRecord blog;

  @override
  State<BlogComments> createState() => _BlogCommentsState();
}

class _BlogCommentsState extends State<BlogComments> {
  final _input = TextEditingController();
  final Map<String, TextEditingController> _replyInputs = {};
  final Set<String> _expandedReplies = {};
  List<Map<String, dynamic>> _comments = [];
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  Future<void> _loadComments() async {
    final snap = await FirebaseFirestore.instance
        .collection('blogs')
        .doc(widget.blog.id)
        .get();
    final raw = snap.data()?['comments'];
    if (mounted)
      setState(
        () => _comments = raw is List
            ? raw.map((item) => Map<String, dynamic>.from(item as Map)).toList()
            : [],
      );
  }

  Future<void> _addComment() async {
    final user = FirebaseAuth.instance.currentUser;
    final text = _input.text.trim();
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Login to comment on this video')),
      );
      return;
    }
    if (text.isEmpty) return;
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final comment = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'author': profile.data()?['name'] ?? user.displayName ?? 'User',
      'userUid': user.uid,
      'photo': profile.data()?['photoURL'] ?? user.photoURL,
      'text': text,
      'date': DateTime.now().toIso8601String(),
      'likes': [],
      'replies': [],
    };
    await FirebaseFirestore.instance
        .collection('blogs')
        .doc(widget.blog.id)
        .update({
          'comments': FieldValue.arrayUnion([comment]),
        });
    _input.clear();
    if (mounted)
      setState(() {
        _comments = [..._comments, comment];
        _expanded = true;
      });
  }

  Future<void> _saveComments() async {
    await FirebaseFirestore.instance
        .collection('blogs')
        .doc(widget.blog.id)
        .update({'comments': _comments});
  }

  Future<void> _toggleCommentLike(Map<String, dynamic> comment) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Login to like comments')));
      return;
    }
    final likes = List<String>.from(comment['likes'] ?? const <String>[]);
    if (likes.contains(user.uid)) {
      likes.remove(user.uid);
    } else {
      likes.add(user.uid);
    }
    setState(() => comment['likes'] = likes);
    await _saveComments();
  }

  Future<void> _addReply(Map<String, dynamic> comment) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Login to reply')));
      return;
    }
    final commentId = '${comment['id'] ?? ''}';
    final input = _replyInputs[commentId];
    final text = input?.text.trim() ?? '';
    if (text.isEmpty) return;
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final replies = List<Map<String, dynamic>>.from(
      (comment['replies'] as List? ?? const []).whereType<Map>().map(
        (reply) => Map<String, dynamic>.from(reply),
      ),
    );
    replies.add({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'author': profile.data()?['name'] ?? user.displayName ?? 'User',
      'userUid': user.uid,
      'photo': profile.data()?['photoURL'] ?? user.photoURL,
      'text': text,
      'date': DateTime.now().toIso8601String(),
      'likes': [],
    });
    setState(() {
      comment['replies'] = replies;
      _expandedReplies.add(commentId);
    });
    input?.clear();
    await _saveComments();
  }

  Future<void> _editComment(Map<String, dynamic> comment) async {
    final controller = TextEditingController(text: '${comment['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit comment'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    setState(() {
      comment['text'] = text;
      comment['isEdited'] = true;
    });
    await _saveComments();
  }

  Future<void> _deleteComment(Map<String, dynamic> comment) async {
    setState(
      () => _comments.removeWhere((item) => item['id'] == comment['id']),
    );
    await _saveComments();
  }

  @override
  void dispose() {
    _input.dispose();
    for (final controller in _replyInputs.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = FirebaseAuth.instance.currentUser != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xff101010),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Text(
                    'Comments',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '(${_comments.length})',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    color: Colors.grey[400],
                  ),
                ],
              ),
            ),
          ),
          if (isLoggedIn) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _addComment(),
                    decoration: const InputDecoration(
                      hintText: 'Add a comment...',
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(20)),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _addComment,
                  icon: const Icon(
                    Icons.send_rounded,
                    color: Color(0xff6366f1),
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 8),
            const Text(
              'Login to comment on this video',
              style: TextStyle(color: Colors.white54),
            ),
          ],
          if (_expanded) ...[
            const SizedBox(height: 10),
            if (_comments.isEmpty)
              const Text(
                'No comments yet. Be the first one to comment.',
                style: TextStyle(color: Colors.white54),
              )
            else
              ..._comments.map((comment) {
                final commentId = '${comment['id'] ?? ''}';
                final currentUserId = FirebaseAuth.instance.currentUser?.uid;
                final likes = List<String>.from(
                  comment['likes'] ?? const <String>[],
                );
                final replies = (comment['replies'] as List? ?? const [])
                    .whereType<Map>()
                    .map((reply) => Map<String, dynamic>.from(reply))
                    .toList();
                final isOwner = comment['userUid'] == currentUserId;
                final replyInput = _replyInputs.putIfAbsent(
                  commentId,
                  TextEditingController.new,
                );
                return Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .035),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 16,
                            child: Text(
                              '${comment['author'] ?? 'U'}'.characters.first
                                  .toUpperCase(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${comment['author'] ?? 'User'}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    if (comment['userUid'] ==
                                        widget.blog.authorUid)
                                      const Text(
                                        'Author',
                                        style: TextStyle(
                                          color: Color(0xfff59e0b),
                                          fontSize: 11,
                                        ),
                                      ),
                                    if (isOwner) ...[
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        tooltip: 'Edit comment',
                                        onPressed: () => _editComment(comment),
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 17,
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        tooltip: 'Delete comment',
                                        onPressed: () =>
                                            _deleteComment(comment),
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 17,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                Text(
                                  '${comment['text'] ?? ''}',
                                  style: TextStyle(color: Colors.grey[300]),
                                ),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () =>
                                          _toggleCommentLike(comment),
                                      icon: Icon(
                                        likes.contains(currentUserId)
                                            ? Icons.favorite_rounded
                                            : Icons.favorite_border_rounded,
                                        size: 16,
                                        color: likes.contains(currentUserId)
                                            ? const Color(0xffff0050)
                                            : null,
                                      ),
                                      label: Text('${likes.length}'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => setState(() {
                                        if (!_expandedReplies.add(commentId)) {
                                          _expandedReplies.remove(commentId);
                                        }
                                      }),
                                      icon: const Icon(
                                        Icons.reply_rounded,
                                        size: 17,
                                      ),
                                      label: Text(
                                        'Reply${replies.isEmpty ? '' : ' ${replies.length}'}',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      ...replies.map(
                        (reply) => Padding(
                          padding: const EdgeInsets.only(left: 34, top: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.subdirectory_arrow_right,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${reply['author'] ?? 'User'}: ${reply['text'] ?? ''}',
                                  style: TextStyle(color: Colors.grey[300]),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_expandedReplies.contains(commentId))
                        Padding(
                          padding: const EdgeInsets.only(left: 34, top: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: replyInput,
                                  decoration: const InputDecoration(
                                    hintText: 'Write a reply...',
                                    isDense: true,
                                  ),
                                  onSubmitted: (_) => _addReply(comment),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Send reply',
                                onPressed: () => _addReply(comment),
                                icon: const Icon(Icons.send_rounded),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              }),
          ],
        ],
      ),
    );
  }
}

class _StoryViewerDialog extends StatefulWidget {
  const _StoryViewerDialog({
    required this.authorUid,
    required this.stories,
    required this.initialIndex,
  });

  final String authorUid;
  final List<Map<String, dynamic>> stories;
  final int initialIndex;

  @override
  State<_StoryViewerDialog> createState() => _StoryViewerDialogState();
}

class _StoryViewerDialogState extends State<_StoryViewerDialog> {
  late final PageController _pageController;
  late int _index;
  VideoPlayerController? _videoController;
  Timer? _autoAdvanceTimer;
  bool _isPaused = false;
  bool _isLiked = false;

  static const Duration _storyDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.stories.length - 1);
    _pageController = PageController(initialPage: _index);
    _attachVideoForIndex(_index);
    _startAutoAdvance();
  }

  Future<void> _attachVideoForIndex(int index) async {
    final story = widget.stories[index];
    final url = story['statusVideo'] as String?;
    if (url == null || url.isEmpty) {
      _videoController?.dispose();
      _videoController = null;
      if (mounted) setState(() {});
      return;
    }

    _videoController?.dispose();
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _videoController = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
    } catch (_) {
      _videoController?.dispose();
      _videoController = null;
    }
    if (mounted) setState(() {});
  }

  void _startAutoAdvance() {
    if (_isPaused) return;
    _autoAdvanceTimer?.cancel();
    final current = widget.stories[_index];
    final videoUrl = current['statusVideo'] as String?;
    final duration = (videoUrl != null && videoUrl.isNotEmpty)
        ? const Duration(seconds: 6)
        : _storyDuration;

    _autoAdvanceTimer = Timer(duration, () {
      if (!mounted || _isPaused) return;
      if (_index < widget.stories.length - 1) {
        _goToStory(_index + 1);
      } else {
        Navigator.pop(context);
      }
    });
  }

  void _togglePause(bool value) {
    if (!mounted) return;
    setState(() => _isPaused = value);
    if (value) {
      _autoAdvanceTimer?.cancel();
      _videoController?.pause();
    } else {
      if (_videoController != null && _videoController!.value.isInitialized) {
        _videoController!.play();
      }
      _startAutoAdvance();
    }
  }

  void _goToStory(int nextIndex) {
    if (nextIndex < 0 || nextIndex >= widget.stories.length) {
      Navigator.pop(context);
      return;
    }

    _pageController.animateToPage(
      nextIndex,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
    );
    setState(() => _index = nextIndex);
    _attachVideoForIndex(nextIndex);
    _startAutoAdvance();
  }

  @override
  void dispose() {
    _autoAdvanceTimer?.cancel();
    _pageController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.stories[_index];
    final authorName = '${story['authorName'] ?? 'Creator'}';
    final authorPhoto = story['authorPhoto'] as String?;
    final imageUrl = story['statusImage'] as String?;
    final videoUrl = story['statusVideo'] as String?;
    final textStory =
        (story['statusMessage'] ?? story['storyText'] ?? story['text'] ?? '')
            .toString()
            .trim();
    final textColorValue = story['storyTextColor'] as int? ?? 0xffffffff;
    final textColor = Color(textColorValue);
    final textSize = (story['storyTextSize'] as num?)?.toDouble() ?? 26;
    final storyBackground =
        story['storyBackgroundColor'] as int? ?? const Color(0xff1f2937).value;
    final hasMedia =
        (imageUrl != null && imageUrl.isNotEmpty) ||
        (videoUrl != null && videoUrl.isNotEmpty);

    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final width = MediaQuery.sizeOf(context).width;
          final localX = details.localPosition.dx;
          if (localX < width * 0.45) {
            if (_index > 0) {
              _goToStory(_index - 1);
            }
          } else {
            if (_index < widget.stories.length - 1) {
              _goToStory(_index + 1);
            } else {
              Navigator.pop(context);
            }
          }
        },
        child: SizedBox.expand(
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                itemCount: widget.stories.length,
                onPageChanged: (i) {
                  setState(() => _index = i);
                  _attachVideoForIndex(i);
                  _startAutoAdvance();
                },
                itemBuilder: (context, index) {
                  final item = widget.stories[index];
                  final itemImageUrl = item['statusImage'] as String?;
                  final itemVideoUrl = item['statusVideo'] as String?;
                  final itemText =
                      (item['statusMessage'] ??
                              item['storyText'] ??
                              item['text'] ??
                              '')
                          .toString()
                          .trim();
                  final itemTextColorValue =
                      item['storyTextColor'] as int? ?? 0xffffffff;
                  final itemTextColor = Color(itemTextColorValue);
                  final itemTextSize =
                      (item['storyTextSize'] as num?)?.toDouble() ?? 26;
                  final itemHasMedia =
                      (itemImageUrl != null && itemImageUrl.isNotEmpty) ||
                      (itemVideoUrl != null && itemVideoUrl.isNotEmpty);

                  final backgroundColor = Color(
                    (item['storyBackgroundColor'] as int?) ??
                        const Color(0xff1f2937).value,
                  );

                  return Container(
                    color: Colors.black,
                    child: Center(
                      child: itemHasMedia
                          ? (itemImageUrl != null && itemImageUrl.isNotEmpty
                                ? Image.network(
                                    itemImageUrl,
                                    fit: BoxFit.contain,
                                    width: double.infinity,
                                    height: double.infinity,
                                    errorBuilder: (_, __, ___) => const Icon(
                                      Icons.broken_image_outlined,
                                      size: 50,
                                      color: Colors.white70,
                                    ),
                                  )
                                : (itemVideoUrl != null &&
                                          itemVideoUrl.isNotEmpty
                                      ? (_videoController != null &&
                                                _videoController!
                                                    .value
                                                    .isInitialized
                                            ? AspectRatio(
                                                aspectRatio: _videoController!
                                                    .value
                                                    .aspectRatio,
                                                child: VideoPlayer(
                                                  _videoController!,
                                                ),
                                              )
                                            : const Center(
                                                child:
                                                    CircularProgressIndicator(
                                                      color: Color(0xfff59e0b),
                                                    ),
                                              ))
                                      : const Center(
                                          child: Icon(
                                            Icons.image_not_supported_outlined,
                                            size: 42,
                                            color: Colors.white70,
                                          ),
                                        )))
                          : Container(
                              width: double.infinity,
                              height: double.infinity,
                              padding: const EdgeInsets.all(28),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: backgroundColor),
                              child: Text(
                                itemText.isEmpty ? 'Story' : itemText,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: itemTextColor,
                                  fontSize: itemTextSize,
                                  fontWeight: FontWeight.w700,
                                  height: 1.2,
                                ),
                              ),
                            ),
                    ),
                  );
                },
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.42),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.55),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 18,
                left: 16,
                right: 16,
                child: SafeArea(
                  child: Column(
                    children: [
                      Row(
                        children: List.generate(
                          widget.stories.length,
                          (i) => Expanded(
                            child: Container(
                              margin: EdgeInsets.only(
                                right: i == widget.stories.length - 1 ? 0 : 4,
                              ),
                              height: 3,
                              decoration: BoxDecoration(
                                color: i <= _index
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundImage:
                                authorPhoto == null || authorPhoto.isEmpty
                                ? null
                                : NetworkImage(authorPhoto),
                            child: authorPhoto == null || authorPhoto.isEmpty
                                ? const Icon(Icons.person_outline, size: 18)
                                : null,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              authorName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close, color: Colors.white),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (hasMedia && textStory.isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 28,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      textStory,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor,
                        fontSize: textSize * 0.45,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class ViyouVideoPlayer extends StatefulWidget {
  const ViyouVideoPlayer({super.key, required this.video});

  final BlogRecord video;

  @override
  State<ViyouVideoPlayer> createState() => _ViyouVideoPlayerState();
}

class _VideoFramePreview extends StatefulWidget {
  const _VideoFramePreview({required this.url});

  final String url;

  @override
  State<_VideoFramePreview> createState() => _VideoFramePreviewState();
}

class _VideoFramePreviewState extends State<_VideoFramePreview> {
  late final VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final controller = await _buildVideoController(widget.url);
    _controller = controller;
    await controller.initialize();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) return _placeholder();
    return AspectRatio(
      aspectRatio: _controller.value.aspectRatio,
      child: VideoPlayer(_controller),
    );
  }

  Widget _placeholder() => AspectRatio(
    aspectRatio: 16 / 9,
    child: Container(
      color: const Color(0xff202020),
      child: const Icon(Icons.movie_outlined, size: 42),
    ),
  );
}

class _FlickPage extends StatefulWidget {
  const _FlickPage({required this.blog, required this.isActive});

  final BlogRecord blog;
  final bool isActive;

  @override
  State<_FlickPage> createState() => _FlickPageState();
}

class _FlickPageState extends State<_FlickPage> {
  static final Set<String> _viewedFlicksThisSession = <String>{};
  VideoPlayerController? _controller;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _blogSubscription;
  late final Future<void> _ready;
  int _likesCount = 0;
  int _commentsCount = 0;
  int _viewsCount = 0;
  bool _isLiked = false;
  bool _isFollowing = false;
  bool _isSaved = false;
  bool _showHeart = false;
  bool _countedView = false;
  double _startSeconds = 0;
  double _endSeconds = 0;
  Timer? _heartTimer;

  @override
  void initState() {
    super.initState();
    _likesCount = widget.blog.likesCount;
    _commentsCount = widget.blog.commentsCount;
    _viewsCount = widget.blog.viewsCount;
    _isLiked = widget.blog.isLiked;
    _startSeconds = widget.blog.flickStartTime;
    _endSeconds = widget.blog.flickEndTime ?? widget.blog.duration;
    _blogSubscription = FirebaseFirestore.instance
        .collection('blogs')
        .doc(widget.blog.id)
        .snapshots()
        .listen(_syncFlickCounts);
    _ready = _initialize();
    _loadFollowState();
  }

  @override
  void didUpdateWidget(covariant _FlickPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      _setFlickActive(widget.isActive);
    }
  }

  Future<void> _initialize() async {
    final url = widget.blog.video;
    if (url == null || !hasPlayableMediaSource(url)) {
      throw const FormatException('This flick has no playable video URL');
    }
    final controller = await _buildVideoController(url);
    _controller = controller;
    await controller.initialize();
    final duration = controller.value.duration.inMilliseconds / 1000;
    if (_endSeconds <= 0 || _endSeconds > duration) _endSeconds = duration;
    await controller.setLooping(false);
    await controller.setVolume(_flicksGlobalMuted ? 0 : 1);
    if (_startSeconds > 0) {
      await controller.seekTo(
        Duration(milliseconds: (_startSeconds * 1000).round()),
      );
    }
    controller.addListener(_onFlickProgress);
    if (widget.isActive) await _setFlickActive(true);
  }

  Future<void> _setFlickActive(bool isActive) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (!isActive) {
      await controller.pause();
      return;
    }
    unawaited(_recordSyncedWatchHistory(widget.blog.id));
    await controller.play();
  }

  void _onFlickProgress() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final position = controller.value.position.inMilliseconds / 1000;
    if (_endSeconds > _startSeconds && position >= _endSeconds) {
      unawaited(
        controller.seekTo(
          Duration(milliseconds: (_startSeconds * 1000).round()),
        ),
      );
      unawaited(controller.play());
      return;
    }
    if (position < 5 || _countedView) return;
    _countedView = true;
    if (_viewedFlicksThisSession.add(widget.blog.id)) {
      unawaited(
        FirebaseFirestore.instance
            .collection('blogs')
            .doc(widget.blog.id)
            .update({'views': FieldValue.increment(1)}),
      );
    }
  }

  void _syncFlickCounts(DocumentSnapshot<Map<String, dynamic>> snapshot) {
    if (!mounted || !snapshot.exists) return;
    final data = snapshot.data() ?? {};
    final likes = data['likes'];
    final comments = data['comments'];
    final userId = FirebaseAuth.instance.currentUser?.uid;
    setState(() {
      _likesCount = likes is List
          ? likes.length
          : (likes is num ? likes.toInt() : 0);
      _commentsCount = comments is List ? comments.length : 0;
      _viewsCount = (data['views'] as num?)?.toInt() ?? 0;
      _isLiked = userId != null && likes is List && likes.contains(userId);
    });
  }

  Future<void> _loadFollowState() async {
    final user = FirebaseAuth.instance.currentUser;
    final authorUid = widget.blog.authorUid;
    if (user == null) return;
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    if (!mounted) return;
    final data = userDoc.data() ?? {};
    final following = data['following'];
    final savedBlogs = data['savedBlogs'];
    setState(() {
      _isFollowing =
          authorUid != null &&
          user.uid != authorUid &&
          following is List &&
          following.contains(authorUid);
      _isSaved = savedBlogs is List && savedBlogs.contains(widget.blog.id);
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _requireLogin(String action) {
    _showMessage('Log in to $action');
  }

  Future<void> _toggleFlickLike() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _requireLogin('like Flicks');
      return;
    }
    final wasLiked = _isLiked;
    setState(() {
      _isLiked = !wasLiked;
      _likesCount = (_likesCount + (wasLiked ? -1 : 1)).clamp(0, 1 << 30);
    });
    final reference = FirebaseFirestore.instance
        .collection('blogs')
        .doc(widget.blog.id);
    try {
      await reference.update({
        'likes': wasLiked
            ? FieldValue.arrayRemove([user.uid])
            : FieldValue.arrayUnion([user.uid]),
      });
      if (!wasLiked &&
          widget.blog.authorUid != null &&
          widget.blog.authorUid != user.uid) {
        await FirebaseFirestore.instance.collection('notifications').add({
          'recipientUid': widget.blog.authorUid,
          'senderUid': user.uid,
          'senderName': user.displayName ?? 'User',
          'type': 'like',
          'blogId': widget.blog.id,
          'blogTitle': widget.blog.title,
          'date': DateTime.now().toIso8601String(),
          'read': false,
        });
      }
    } catch (error) {
      if (mounted)
        setState(() {
          _isLiked = wasLiked;
          _likesCount = (_likesCount + (wasLiked ? 1 : -1)).clamp(0, 1 << 30);
        });
      _showMessage('Could not update like: $error');
    }
  }

  Future<void> _toggleFollow() async {
    final user = FirebaseAuth.instance.currentUser;
    final authorUid = widget.blog.authorUid;
    if (user == null) {
      _requireLogin('follow creators');
      return;
    }
    if (authorUid == null || authorUid == user.uid) return;
    final wasFollowing = _isFollowing;
    setState(() => _isFollowing = !wasFollowing);
    final currentUserRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);
    final authorRef = FirebaseFirestore.instance
        .collection('users')
        .doc(authorUid);
    try {
      await Future.wait([
        currentUserRef.set({
          'following': wasFollowing
              ? FieldValue.arrayRemove([authorUid])
              : FieldValue.arrayUnion([authorUid]),
        }, SetOptions(merge: true)),
        authorRef.set({
          'followers': wasFollowing
              ? FieldValue.arrayRemove([user.uid])
              : FieldValue.arrayUnion([user.uid]),
        }, SetOptions(merge: true)),
      ]);
      if (!wasFollowing) {
        await FirebaseFirestore.instance.collection('notifications').add({
          'recipientUid': authorUid,
          'senderUid': user.uid,
          'senderName': user.displayName ?? 'Someone',
          'type': 'follow',
          'date': DateTime.now().toIso8601String(),
          'read': false,
        });
      }
    } catch (error) {
      if (mounted) setState(() => _isFollowing = wasFollowing);
      _showMessage('Could not update follow: $error');
    }
  }

  Future<void> _toggleMute() async {
    final controller = _controller;
    if (controller == null) return;
    final isMuted = controller.value.volume == 0;
    _flicksGlobalMuted = !isMuted;
    await controller.setVolume(isMuted ? 1 : 0);
    if (mounted) setState(() {});
  }

  Future<void> _toggleFlickSave() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _requireLogin('save Flicks');
      return;
    }
    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);
    await userRef.set({
      'savedBlogs': FieldValue.arrayUnion([widget.blog.id]),
    }, SetOptions(merge: true));
    if (mounted) setState(() => _isSaved = true);
    _showMessage('Flick saved to profile');
  }

  Future<void> _openFlickComments() async {
    final controller = _controller;
    await controller?.pause();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xff101010),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .78,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
            child: BlogComments(blog: widget.blog),
          ),
        ),
      ),
    );
    if (mounted && controller != null) await controller.play();
  }

  Future<void> _showFlickDescription() async {
    final controller = _controller;
    await controller?.pause();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xff151515),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '@${widget.blog.author} • ${_formatFlickDate(widget.blog.date)}',
                  style: TextStyle(color: Colors.grey[400]),
                ),
                const SizedBox(height: 14),
                Text(
                  widget.blog.title,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (widget.blog.content.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(widget.blog.content),
                ],
                const SizedBox(height: 18),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.music_note_rounded,
                    color: Color(0xfff59e0b),
                  ),
                  title: Text(_audioLabel),
                  subtitle: const Text('Viyou Audio'),
                  trailing: const Icon(Icons.open_in_new_rounded),
                  onTap: _openFlickAudio,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted && controller != null) await controller.play();
  }

  String get _audioLabel =>
      widget.blog.isOriginalAudio || widget.blog.audioTitle == null
      ? '${widget.blog.title} - @${widget.blog.author}'
      : widget.blog.audioTitle!;

  String _formatFlickDate(DateTime date) {
    final age = DateTime.now().difference(date);
    if (age.inDays > 365) return '${age.inDays ~/ 365} years ago';
    if (age.inDays > 30) return '${age.inDays ~/ 30} months ago';
    if (age.inDays > 0) return '${age.inDays} days ago';
    if (age.inHours > 0) return '${age.inHours} hours ago';
    if (age.inMinutes > 0) return '${age.inMinutes} minutes ago';
    return 'Just now';
  }

  Future<void> _openFlickAudio() async {
    final source = widget.blog.audioUrl ?? widget.blog.video;
    final uri = source == null ? null : Uri.tryParse(source);
    if (uri == null || !await canLaunchUrl(uri)) {
      _showMessage('Audio is unavailable');
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _copyFlickLink() async {
    final link = Uri.https('viyou.in', '/flicks.html', {'id': widget.blog.id});
    await Clipboard.setData(ClipboardData(text: link.toString()));
    _showMessage('Flick link copied');
  }

  Future<void> _saveFlickToPlaylist() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _requireLogin('save Flicks to a playlist');
      return;
    }
    final snapshot = await FirebaseFirestore.instance
        .collection('playlists')
        .where('authorUid', isEqualTo: user.uid)
        .get();
    if (!mounted) return;
    if (snapshot.docs.isEmpty) {
      _showMessage('Create a playlist from your profile first');
      return;
    }
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xff151515),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Save to playlist')),
            ...snapshot.docs.map(
              (playlist) => ListTile(
                leading: const Icon(Icons.playlist_play_rounded),
                title: Text('${playlist.data()['name'] ?? 'Playlist'}'),
                onTap: () => Navigator.pop(sheetContext, playlist.id),
              ),
            ),
          ],
        ),
      ),
    );
    if (selectedId == null) return;
    final ref = FirebaseFirestore.instance
        .collection('playlists')
        .doc(selectedId);
    final playlist = snapshot.docs
        .firstWhere((doc) => doc.id == selectedId)
        .data();
    final items = List<Map<String, dynamic>>.from(
      (playlist['items'] as List? ?? const []).whereType<Map>().map(
        (item) => Map<String, dynamic>.from(item),
      ),
    );
    if (items.any(
      (item) => (item['contentId'] ?? item['id']) == widget.blog.id,
    )) {
      _showMessage('Flick is already in this playlist');
      return;
    }
    items.add({
      'id': widget.blog.id,
      'contentId': widget.blog.id,
      'type': 'flick',
      'title': widget.blog.title,
      'image': widget.blog.primaryImage ?? '',
      'url': 'flicks.html?id=${widget.blog.id}',
      'addedAt': DateTime.now().toIso8601String(),
    });
    await ref.update({'items': items});
    _showMessage('Added to playlist');
  }

  Future<void> _reportFlick() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _requireLogin('report Flicks');
      return;
    }
    const reasons = [
      'Sexual content',
      'Violent or repulsive content',
      'Hateful or abusive content',
      'Harassment or bullying',
      'Spam or misleading',
      'Other',
    ];
    final selectedReason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xff151515),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Report Flick')),
            ...reasons.map(
              (reason) => ListTile(
                title: Text(reason),
                onTap: () => Navigator.pop(sheetContext, reason),
              ),
            ),
          ],
        ),
      ),
    );
    if (selectedReason == null) return;
    String? reason = selectedReason;
    if (selectedReason == 'Other') {
      final reasonController = TextEditingController();
      reason = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Report Flick'),
          content: TextField(
            controller: reasonController,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Describe the issue'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, reasonController.text.trim()),
              child: const Text('Submit'),
            ),
          ],
        ),
      );
      reasonController.dispose();
    }
    if (reason == null || reason.isEmpty) return;
    await FirebaseFirestore.instance.collection('reports').add({
      'blogId': widget.blog.id,
      'reporterUid': user.uid,
      'reason': reason,
      'date': DateTime.now().toIso8601String(),
    });
    _showMessage('Report submitted');
  }

  Future<void> _sendFlick() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _requireLogin('send Flicks');
      return;
    }
    final userSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final following = List<String>.from(
      userSnapshot.data()?['following'] ?? const <String>[],
    );
    if (!mounted) return;
    if (following.isEmpty) {
      _showMessage('Follow someone to send them a Flick');
      return;
    }
    final selectedUid = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xff151515),
      builder: (sheetContext) => SafeArea(
        child: FutureBuilder<List<DocumentSnapshot<Map<String, dynamic>>>>(
          future: Future.wait(
            following.map(
              (uid) =>
                  FirebaseFirestore.instance.collection('users').doc(uid).get(),
            ),
          ),
          builder: (context, snapshot) {
            final users = snapshot.data ?? const [];
            return ListView(
              shrinkWrap: true,
              children: [
                const ListTile(title: Text('Send Flick to')),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Center(child: CircularProgressIndicator()),
                ...users
                    .where((item) => item.exists)
                    .map(
                      (item) => ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.person_outline),
                        ),
                        title: Text('${item.data()?['name'] ?? 'User'}'),
                        subtitle: Text('@${item.data()?['username'] ?? ''}'),
                        onTap: () => Navigator.pop(sheetContext, item.id),
                      ),
                    ),
              ],
            );
          },
        ),
      ),
    );
    if (selectedUid != null) await _sendFlickToUser(selectedUid);
  }

  Future<void> _sendFlickToUser(String targetUid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final conversationId = user.uid.compareTo(targetUid) < 0
        ? '${user.uid}_$targetUid'
        : '${targetUid}_${user.uid}';
    final conversationRef = FirebaseFirestore.instance
        .collection('conversations')
        .doc(conversationId);
    final messagesRef = conversationRef.collection('messages');
    final partnerSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(targetUid)
        .get();
    final senderSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final sender = senderSnapshot.data() ?? {};
    final partner = partnerSnapshot.data() ?? {};
    await messagesRef.add({
      'type': 'flick',
      'flickId': widget.blog.id,
      'videoUrl': widget.blog.video,
      'title': widget.blog.title,
      'senderUid': user.uid,
      'timestamp': FieldValue.serverTimestamp(),
    });
    await conversationRef.set({
      'participants': [user.uid, targetUid],
      'participantDetails': {
        user.uid: {
          'name': sender['name'] ?? user.displayName ?? 'User',
          'photoURL': sender['photoURL'] ?? user.photoURL,
        },
        targetUid: {
          'name': partner['name'] ?? 'User',
          'photoURL': partner['photoURL'],
        },
      },
      'lastMessage': {
        'text': 'Sent a Flick',
        'senderUid': user.uid,
        'timestamp': FieldValue.serverTimestamp(),
        'isRead': false,
      },
    }, SetOptions(merge: true));
    _showMessage('Flick sent');
  }

  Future<void> _openCreatorProfile() async {
    final authorUid = widget.blog.authorUid;
    if (authorUid == null) return;
    final userSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(authorUid)
        .get();
    if (!userSnapshot.exists || !mounted) return;
    final postsSnapshot = await FirebaseFirestore.instance
        .collection('blogs')
        .where('authorUid', isEqualTo: authorUid)
        .where('status', isEqualTo: 'published')
        .limit(30)
        .get();
    if (!mounted) return;
    final profile = UserProfile.fromDocument(
      userSnapshot,
      FirebaseAuth.instance.currentUser,
      postsSnapshot.docs.map(BlogRecord.fromDocument).toList(),
    );
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ViyouPublicProfilePage(profile: profile),
      ),
    );
  }

  Future<void> _showFlickMore() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff151515),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(
                _isSaved ? Icons.bookmark : Icons.bookmark_add_outlined,
              ),
              title: Text(_isSaved ? 'Saved to profile' : 'Save to profile'),
              onTap: () {
                Navigator.pop(sheetContext);
                _toggleFlickSave();
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('Save to playlist'),
              onTap: () {
                Navigator.pop(sheetContext);
                _saveFlickToPlaylist();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Copy link'),
              onTap: () {
                Navigator.pop(sheetContext);
                _copyFlickLink();
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report Flick'),
              onTap: () {
                Navigator.pop(sheetContext);
                _reportFlick();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _heartTimer?.cancel();
    _blogSubscription?.cancel();
    _controller?.removeListener(_onFlickProgress);
    _controller?.dispose();
    super.dispose();
  }

  Widget _flickAction({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color color = Colors.white,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: color, size: 29),
        tooltip: label,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: .42),
          fixedSize: const Size(48, 48),
        ),
      ),
      Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
      const SizedBox(height: 12),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError ||
            _controller == null ||
            !_controller!.value.isInitialized) {
          return ColoredBox(
            color: Colors.black,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Flick video unavailable\n${snapshot.error ?? ''}',
                  textAlign: TextAlign.center,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          );
        }
        final controller = _controller!;
        return GestureDetector(
          onTap: () async {
            if (controller.value.volume == 0) {
              await controller.setVolume(1);
            } else if (controller.value.isPlaying) {
              await controller.pause();
            } else {
              await controller.play();
            }
            if (mounted) setState(() {});
          },
          onDoubleTap: () {
            if (!_isLiked) _toggleFlickLike();
            _heartTimer?.cancel();
            setState(() => _showHeart = true);
            _heartTimer = Timer(const Duration(milliseconds: 650), () {
              if (mounted) setState(() => _showHeart = false);
            });
          },
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: VideoPlayer(controller),
                  ),
                ),
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 12,
                  right: 12,
                  child: IconButton.filledTonal(
                    onPressed: _toggleMute,
                    tooltip: controller.value.volume == 0 ? 'Unmute' : 'Mute',
                    icon: Icon(
                      controller.value.volume == 0
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: .45),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 82, 38),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: _openCreatorProfile,
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 20,
                                child: Text(
                                  widget.blog.author.isEmpty
                                      ? 'V'
                                      : widget.blog.author[0].toUpperCase(),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  '@${widget.blog.author}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black87,
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (FirebaseAuth.instance.currentUser?.uid !=
                                  widget.blog.authorUid)
                                TextButton(
                                  onPressed: _toggleFollow,
                                  child: Text(
                                    _isFollowing ? 'Following' : 'Follow',
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          onTap: _showFlickDescription,
                          child: Text(
                            widget.blog.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 8),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.blog.category} • ${_formatFlickDate(widget.blog.date)}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            shadows: [
                              Shadow(color: Colors.black87, blurRadius: 8),
                            ],
                          ),
                        ),
                        if (widget.blog.content.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          InkWell(
                            onTap: _showFlickDescription,
                            child: Text(
                              widget.blog.content,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        InkWell(
                          onTap: _openFlickAudio,
                          child: Row(
                            children: [
                              const Icon(
                                Icons.music_note_rounded,
                                size: 16,
                                color: Color(0xfff59e0b),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  _audioLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: MediaQuery.sizeOf(context).height * .2,
                  right: 6,
                  bottom: MediaQuery.sizeOf(context).height * .14,
                  width: 64,
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _flickAction(
                          icon: _isLiked
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          label: '$_likesCount',
                          color: _isLiked
                              ? const Color(0xffff0050)
                              : Colors.white,
                          onPressed: _toggleFlickLike,
                        ),
                        _flickAction(
                          icon: Icons.mode_comment_outlined,
                          label: '$_commentsCount',
                          onPressed: _openFlickComments,
                        ),
                        _flickAction(
                          icon: Icons.share_outlined,
                          label: 'Share',
                          onPressed: _copyFlickLink,
                        ),
                        _flickAction(
                          icon: Icons.playlist_add_rounded,
                          label: 'Playlist',
                          onPressed: _saveFlickToPlaylist,
                        ),
                        _flickAction(
                          icon: Icons.send_rounded,
                          label: 'Send',
                          onPressed: _sendFlick,
                        ),
                        _flickAction(
                          icon: Icons.flag_outlined,
                          label: 'Report',
                          onPressed: _reportFlick,
                        ),
                        _flickAction(
                          icon: _isSaved
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                          label: 'Save',
                          onPressed: _toggleFlickSave,
                        ),
                        _flickAction(
                          icon: Icons.visibility_outlined,
                          label: '$_viewsCount',
                          onPressed: () {},
                        ),
                        _flickAction(
                          icon: Icons.more_horiz_rounded,
                          label: 'More',
                          onPressed: _showFlickMore,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showHeart)
                  const Center(
                    child: Icon(
                      Icons.favorite_rounded,
                      color: Color(0xffff0050),
                      size: 94,
                    ),
                  ),
                if (!controller.value.isPlaying)
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill_rounded,
                      size: 76,
                      color: Colors.white70,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class ViyouChatPage extends StatefulWidget {
  const ViyouChatPage({
    super.key,
    required this.partnerUid,
    required this.partnerName,
    this.partnerPhoto,
  });

  final String partnerUid;
  final String partnerName;
  final String? partnerPhoto;

  @override
  State<ViyouChatPage> createState() => _ViyouChatPageState();
}

class _ViyouChatPageState extends State<ViyouChatPage> {
  final _input = TextEditingController();
  late final String _conversationId;
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _conversationStream;
  Timer? _typingTimer;
  bool _typingStatusActive = false;
  bool _isPartnerBlocked = false;
  bool _blockedByPartner = false;
  bool _blockStatusLoaded = false;
  bool _blockStatusFailed = false;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser!.uid;
    _conversationId = uid.compareTo(widget.partnerUid) < 0
        ? '${uid}_${widget.partnerUid}'
        : '${widget.partnerUid}_$uid';
    _conversationStream = FirebaseFirestore.instance
        .collection('conversations')
        .doc(_conversationId)
        .snapshots();
    _markConversationRead();
    _loadBlockStatus();
  }

  Future<void> _markConversationRead() async {
    final conversation = FirebaseFirestore.instance
        .collection('conversations')
        .doc(_conversationId);
    if (!(await conversation.get()).exists) return;
    await conversation.set({
      'lastMessage': {'isRead': true},
    }, SetOptions(merge: true));
    final messages = await FirebaseFirestore.instance
        .collection('conversations')
        .doc(_conversationId)
        .collection('messages')
        .get();
    final unreadMessages = messages.docs.where((message) {
      final data = message.data();
      return data['senderUid'] == widget.partnerUid && data['isRead'] != true;
    }).toList();
    for (var start = 0; start < unreadMessages.length; start += 450) {
      final batch = FirebaseFirestore.instance.batch();
      for (final message in unreadMessages.skip(start).take(450)) {
        batch.update(message.reference, {'isRead': true});
      }
      await batch.commit();
    }
  }

  Future<void> _loadBlockStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snapshots = await Future.wait([
        FirebaseFirestore.instance.collection('users').doc(user.uid).get(),
        FirebaseFirestore.instance
            .collection('users')
            .doc(widget.partnerUid)
            .get(),
      ]);
      if (!mounted) return;
      final blockedUsers = List<String>.from(
        snapshots[0].data()?['blockedUsers'] ?? const <dynamic>[],
      );
      final blockedBy = List<String>.from(
        snapshots[1].data()?['blockedBy'] ?? const <dynamic>[],
      );
      setState(() {
        _isPartnerBlocked = blockedUsers.contains(widget.partnerUid);
        _blockedByPartner = blockedBy.contains(user.uid);
        _blockStatusLoaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _blockStatusLoaded = true;
          _blockStatusFailed = true;
        });
      }
    }
  }

  Future<void> _togglePartnerBlock() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final operation = _isPartnerBlocked
        ? FieldValue.arrayRemove([widget.partnerUid])
        : FieldValue.arrayUnion([widget.partnerUid]);
    final reciprocal = _isPartnerBlocked
        ? FieldValue.arrayRemove([user.uid])
        : FieldValue.arrayUnion([user.uid]);
    try {
      await Future.wait([
        FirebaseFirestore.instance.collection('users').doc(user.uid).update({
          'blockedUsers': operation,
        }),
        FirebaseFirestore.instance
            .collection('users')
            .doc(widget.partnerUid)
            .update({'blockedBy': reciprocal}),
      ]);
      if (!mounted) return;
      setState(() => _isPartnerBlocked = !_isPartnerBlocked);
      _showChatNotice(_isPartnerBlocked ? 'User blocked' : 'User unblocked');
    } catch (error) {
      _showChatNotice('Could not update block setting: $error');
    }
  }

  void _handleTyping(String value) {
    _typingTimer?.cancel();
    final isTyping = value.trim().isNotEmpty;
    unawaited(_setTypingStatus(isTyping));
    if (isTyping) {
      _typingTimer = Timer(
        const Duration(milliseconds: 1600),
        () => _setTypingStatus(false),
      );
    }
  }

  Future<void> _setTypingStatus(bool isTyping) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || isTyping == _typingStatusActive) return;
    try {
      final conversation = FirebaseFirestore.instance
          .collection('conversations')
          .doc(_conversationId);
      if (isTyping && !(await conversation.get()).exists) return;
      await conversation.set({
        'typingStatus': {
          user.uid: isTyping ? FieldValue.serverTimestamp() : null,
        },
      }, SetOptions(merge: true));
      _typingStatusActive = isTyping;
    } catch (_) {}
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    unawaited(_setTypingStatus(false));
    _input.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _input.text.trim();
    final user = FirebaseAuth.instance.currentUser;
    if (text.isEmpty ||
        user == null ||
        !_blockStatusLoaded ||
        _blockStatusFailed ||
        _isPartnerBlocked ||
        _blockedByPartner) {
      return;
    }
    _input.clear();
    _typingTimer?.cancel();
    unawaited(_setTypingStatus(false));
    final messages = FirebaseFirestore.instance
        .collection('conversations')
        .doc(_conversationId)
        .collection('messages');
    await messages.add({
      'type': 'text',
      'text': text,
      'content': text,
      'senderUid': user.uid,
      'timestamp': FieldValue.serverTimestamp(),
      'isRead': false,
    });
    await _updateConversationPreview(text, user);
  }

  Future<void> _updateConversationPreview(String text, User user) async {
    final profile = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    await FirebaseFirestore.instance
        .collection('conversations')
        .doc(_conversationId)
        .set({
          'participants': [user.uid, widget.partnerUid],
          'participantDetails': {
            user.uid: {
              'name': profile.data()?['name'] ?? user.displayName ?? 'User',
              'photoURL': profile.data()?['photoURL'] ?? user.photoURL,
            },
            widget.partnerUid: {
              'name': widget.partnerName,
              'photoURL': widget.partnerPhoto,
            },
          },
          'lastMessage': {
            'text': text,
            'senderUid': user.uid,
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          },
        }, SetOptions(merge: true));
  }

  Future<void> _pickAttachment() async {
    if (!_blockStatusLoaded ||
        _blockStatusFailed ||
        _isPartnerBlocked ||
        _blockedByPartner) {
      return;
    }
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'webp'],
    );
    if (result.isEmpty) return;

    final file = result.single;
    final extension = file.extension?.toLowerCase() ?? '';
    final isPdf = extension == 'pdf';
    final sizeLimit = isPdf ? 5 * 1024 * 1024 : 10 * 1024 * 1024;
    final fileSize = await file.length();
    if (fileSize != null && fileSize > sizeLimit) {
      _showChatNotice(
        isPdf
            ? 'PDF files must be 5 MB or smaller'
            : 'Images must be 10 MB or smaller',
      );
      return;
    }

    final bytes = await file.readAsBytes();
    if (bytes.lengthInBytes > sizeLimit) {
      _showChatNotice(
        isPdf
            ? 'PDF files must be 5 MB or smaller'
            : 'Images must be 10 MB or smaller',
      );
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final mimeType = isPdf
          ? 'application/pdf'
          : 'image/${extension == 'jpg' ? 'jpeg' : extension}';
      final storageRef = FirebaseStorage.instance.ref().child(
        'chat_media/$_conversationId/${DateTime.now().millisecondsSinceEpoch}_$safeName',
      );
      final uploaded = await storageRef.putData(
        bytes,
        SettableMetadata(contentType: mimeType),
      );
      final url = await uploaded.ref.getDownloadURL();
      await FirebaseFirestore.instance
          .collection('conversations')
          .doc(_conversationId)
          .collection('messages')
          .add({
            'type': isPdf ? 'pdf' : 'image',
            'content': url,
            'text': isPdf ? '[PDF Document]' : '[Image]',
            'fileName': file.name,
            'senderUid': user.uid,
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });
      await _updateConversationPreview(
        isPdf ? '[PDF Document]' : '[Image]',
        user,
      );
    } catch (error) {
      _showChatNotice('File upload failed: $error');
    }
  }

  void _openPdf(String url, String fileName) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _ChatPdfReaderPage(url: url, fileName: fileName),
      ),
    );
  }

  Future<void> _openSharedContent(Map<String, dynamic> data) async {
    final type = data['type'];
    if (type == 'flick') {
      final flickId = data['flickId'];
      if (flickId is! String || flickId.isEmpty) {
        _showChatNotice('This shared Flick is unavailable');
        return;
      }
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('blogs')
            .doc(flickId)
            .get();
        if (!mounted) return;
        if (!snapshot.exists) {
          _showChatNotice('This Flick is no longer available');
          return;
        }
        final flick = BlogRecord.fromMap(flickId, snapshot.data() ?? const {});
        await Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ViyouVideoPlayer(video: flick),
          ),
        );
      } catch (error) {
        _showChatNotice('Could not open Flick: $error');
      }
      return;
    }

    final content = '${data['content'] ?? ''}';
    Uri? uri;
    if (type == 'youtube') {
      uri = Uri.tryParse(content);
      if (uri == null || !uri.hasScheme) {
        uri = Uri.https('www.youtube.com', '/watch', {'v': content});
      }
    } else if (type == 'watch' && data['blogId'] is String) {
      uri = Uri.https('viyou.in', '/', {'view': 'watch', 'id': data['blogId']});
    }
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _openImage(String url) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => _ChatImageViewerPage(url: url)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    final stream = FirebaseFirestore.instance
        .collection('conversations')
        .doc(_conversationId)
        .collection('messages')
        .snapshots();
    return Scaffold(
      backgroundColor: const Color(0xff080808),
      appBar: AppBar(
        backgroundColor: const Color(0xff111111),
        title: Row(
          children: [
            CircleAvatar(
              radius: 17,
              backgroundImage: widget.partnerPhoto == null
                  ? null
                  : NetworkImage(widget.partnerPhoto!),
              child: widget.partnerPhoto == null
                  ? const Icon(Icons.person, size: 18)
                  : null,
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.partnerName),
                StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _conversationStream,
                  builder: (context, snapshot) {
                    final typing = Map<String, dynamic>.from(
                      snapshot.data?.data()?['typingStatus'] ?? const {},
                    );
                    final typingAt = typing[widget.partnerUid];
                    final isTyping =
                        typingAt is Timestamp &&
                        DateTime.now().difference(typingAt.toDate()).inSeconds <
                            6;
                    return Text(
                      _blockedByPartner
                          ? 'You cannot reply to this conversation'
                          : isTyping
                          ? 'Typing...'
                          : 'Message securely on Viyou',
                      style: TextStyle(
                        color: isTyping
                            ? const Color(0xff10b981)
                            : Colors.grey[500],
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () =>
                _showChatNotice('Video calls are not available yet'),
            icon: const Icon(Icons.videocam_outlined),
            tooltip: 'Video call',
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (action) {
              if (action == 'copy') {
                Clipboard.setData(ClipboardData(text: widget.partnerUid));
                _showChatNotice('User ID copied');
              } else if (action == 'clear') {
                _clearChatForMe();
              } else if (action == 'block') {
                _togglePartnerBlock();
              } else if (action == 'profile') {
                unawaited(
                  launchUrl(
                    Uri.https('viyou.in', '/profile.html', {
                      'uid': widget.partnerUid,
                    }),
                    mode: LaunchMode.externalApplication,
                  ),
                );
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'profile',
                child: Text('View profile'),
              ),
              const PopupMenuItem(value: 'copy', child: Text('Copy user ID')),
              const PopupMenuItem(
                value: 'clear',
                child: Text('Clear chat for me'),
              ),
              PopupMenuItem(
                value: 'block',
                child: Text(_isPartnerBlocked ? 'Unblock user' : 'Block user'),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.more_vert_rounded),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: stream,
              builder: (context, snapshot) {
                final messages =
                    (snapshot.data?.docs ?? []).where((message) {
                      final deletedBy = message.data()['deletedBy'];
                      return deletedBy is! List ||
                          !deletedBy.contains(user.uid);
                    }).toList()..sort((a, b) {
                      final aTime = _chatMessageDate(a.data()['timestamp']);
                      final bTime = _chatMessageDate(b.data()['timestamp']);
                      final byTime = aTime.compareTo(bTime);
                      return byTime == 0 ? a.id.compareTo(b.id) : byTime;
                    });
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 14),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[messages.length - 1 - index];
                    final data = message.data();
                    final sent = data['senderUid'] == user.uid;
                    final type = '${data['type'] ?? 'text'}';
                    final timestamp = data['timestamp'];
                    final reactions = Map<String, dynamic>.from(
                      data['reactions'] ?? const {},
                    );
                    final messageDate = _chatMessageDate(timestamp);
                    final olderMessage = index < messages.length - 1
                        ? messages[messages.length - 2 - index]
                        : null;
                    final showDateHeader =
                        olderMessage == null ||
                        !_isSameChatDay(
                          messageDate,
                          _chatMessageDate(olderMessage.data()['timestamp']),
                        );
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (showDateHeader) _chatDateDivider(messageDate),
                        GestureDetector(
                          onLongPress: () =>
                              _showMessageActions(message, data, sent),
                          child: Align(
                            alignment: sent
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.fromLTRB(12, 9, 10, 6),
                              constraints: const BoxConstraints(maxWidth: 330),
                              decoration: BoxDecoration(
                                color: sent
                                    ? const Color(0xff4c3bb8)
                                    : const Color(0xff1d1d1d),
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(18),
                                  topRight: const Radius.circular(18),
                                  bottomLeft: Radius.circular(sent ? 18 : 4),
                                  bottomRight: Radius.circular(sent ? 4 : 18),
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (type == 'pdf')
                                    InkWell(
                                      onTap: () => _openPdf(
                                        '${data['content'] ?? ''}',
                                        '${data['fileName'] ?? 'Document.pdf'}',
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.picture_as_pdf_rounded,
                                            color: Colors.redAccent,
                                          ),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              '${data['fileName'] ?? 'PDF document'}',
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          const Icon(
                                            Icons.open_in_new_rounded,
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                    )
                                  else if (type == 'image' &&
                                      data['content'] is String)
                                    GestureDetector(
                                      onTap: () =>
                                          _openImage(data['content'] as String),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Image.network(
                                          data['content'] as String,
                                          width: 240,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const Icon(
                                                Icons.broken_image_outlined,
                                              ),
                                        ),
                                      ),
                                    )
                                  else if (type == 'youtube')
                                    TextButton.icon(
                                      onPressed: () => _openSharedContent(data),
                                      icon: const Icon(
                                        Icons.play_circle_outline,
                                      ),
                                      label: const Text('Open YouTube video'),
                                    )
                                  else if (type == 'watch')
                                    InkWell(
                                      onTap: () => _openSharedContent(data),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.play_circle_outline),
                                          const SizedBox(width: 8),
                                          Flexible(
                                            child: Text(
                                              '${data['title'] ?? 'Shared video'}',
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  else if (type == 'flick')
                                    InkWell(
                                      onTap: () => _openSharedContent(data),
                                      child: Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: .2,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.bolt_rounded,
                                              color: Color(0xffff0050),
                                            ),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                '${data['title'] ?? 'Shared a Flick'}',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  else
                                    Text(_chatMessageText(data)),
                                  if (data['forwarded'] == true)
                                    Text(
                                      'Forwarded',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: .6,
                                        ),
                                        fontSize: 11,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  if (data['edited'] == true)
                                    Text(
                                      'Edited',
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: .55,
                                        ),
                                        fontSize: 10,
                                      ),
                                    ),
                                  if (reactions.isNotEmpty)
                                    Wrap(
                                      spacing: 5,
                                      children: reactions.entries
                                          .where(
                                            (entry) =>
                                                entry.value is List &&
                                                (entry.value as List)
                                                    .isNotEmpty,
                                          )
                                          .map(
                                            (entry) => ActionChip(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              label: Text(
                                                '${entry.key} ${(entry.value as List).length}',
                                              ),
                                              onPressed: () => _toggleReaction(
                                                message,
                                                entry.key,
                                              ),
                                            ),
                                          )
                                          .toList(),
                                    ),
                                  const SizedBox(height: 3),
                                  Align(
                                    alignment: Alignment.bottomRight,
                                    widthFactor: 1,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _formatChatTime(timestamp),
                                          style: TextStyle(
                                            color: Colors.white.withValues(
                                              alpha: .6,
                                            ),
                                            fontSize: 10,
                                          ),
                                        ),
                                        if (sent)
                                          Icon(
                                            data['isRead'] == true
                                                ? Icons.done_all_rounded
                                                : Icons.done_rounded,
                                            size: 13,
                                            color: data['isRead'] == true
                                                ? const Color(0xff42c5e8)
                                                : Colors.white54,
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              color: const Color(0xff111111),
              child: !_blockStatusLoaded
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _blockStatusFailed || _isPartnerBlocked || _blockedByPartner
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Center(child: Text('Messaging is unavailable')),
                    )
                  : Row(
                      children: [
                        IconButton(
                          onPressed: _pickAttachment,
                          icon: const Icon(Icons.attach_file_rounded),
                          tooltip: 'Attach',
                        ),
                        Expanded(
                          child: TextField(
                            controller: _input,
                            onChanged: _handleTyping,
                            onSubmitted: (_) => _sendMessage(),
                            decoration: const InputDecoration(
                              hintText: 'Message',
                              filled: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(24),
                                ),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _sendMessage,
                          icon: const Icon(
                            Icons.send_rounded,
                            color: Color(0xff6366f1),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatChatTime(Object? value) {
    final date = value is Timestamp
        ? value.toDate()
        : DateTime.tryParse('$value');
    if (date == null) return '';
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    return '$hour:${date.minute.toString().padLeft(2, '0')} ${date.hour >= 12 ? 'PM' : 'AM'}';
  }

  bool _isSameChatDay(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  Widget _chatDateDivider(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final difference = today.difference(day).inDays;
    final label = date.year == 1970
        ? 'Earlier'
        : difference == 0
        ? 'Today'
        : difference == 1
        ? 'Yesterday'
        : difference < 7
        ? const [
            'Monday',
            'Tuesday',
            'Wednesday',
            'Thursday',
            'Friday',
            'Saturday',
            'Sunday',
          ][date.weekday - 1]
        : '${date.day}/${date.month}/${date.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xff202020),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            label,
            style: TextStyle(color: Colors.grey[300], fontSize: 11),
          ),
        ),
      ),
    );
  }

  DateTime _chatMessageDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse('$value') ?? DateTime(1970);
  }

  String _chatMessageText(Map<String, dynamic> data) =>
      '${data['content'] ?? data['text'] ?? ''}';

  Duration? _chatMessageAge(Object? value) {
    final sentAt = switch (value) {
      Timestamp timestamp => timestamp.toDate(),
      DateTime date => date,
      _ => null,
    };
    return sentAt == null ? null : DateTime.now().difference(sentAt);
  }

  Future<void> _showMessageActions(
    QueryDocumentSnapshot<Map<String, dynamic>> message,
    Map<String, dynamic> data,
    bool sent,
  ) async {
    final age = _chatMessageAge(data['timestamp']);
    final canEdit =
        sent &&
        age != null &&
        age < const Duration(minutes: 15) &&
        (data['type'] == 'text' || data['type'] == 'story_reply');
    final canDeleteForEveryone =
        sent && age != null && age < const Duration(hours: 24);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff171717),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: ['❤️', '👍', '😂', '😮', '😢', '🙏']
                    .map(
                      (emoji) => IconButton(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _toggleReaction(message, emoji);
                        },
                        icon: Text(emoji, style: const TextStyle(fontSize: 22)),
                        tooltip: 'React $emoji',
                      ),
                    )
                    .toList(),
              ),
            ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit message'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _editMessage(message, data);
                },
              ),
            ListTile(
              leading: const Icon(Icons.forward_rounded),
              title: const Text('Forward'),
              onTap: () {
                Navigator.pop(sheetContext);
                _forwardMessage(data);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Delete for me'),
              onTap: () {
                Navigator.pop(sheetContext);
                _deleteMessage(message, forEveryone: false);
              },
            ),
            if (canDeleteForEveryone)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('Delete for everyone'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _deleteMessage(message, forEveryone: true);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleReaction(
    QueryDocumentSnapshot<Map<String, dynamic>> message,
    String emoji,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snapshot = await message.reference.get();
      if (!snapshot.exists) return;
      final reactions = Map<String, dynamic>.from(
        snapshot.data()?['reactions'] ?? const {},
      );
      final users = List<String>.from(reactions[emoji] ?? const <String>[]);
      await message.reference.update({
        'reactions.$emoji': users.contains(user.uid)
            ? FieldValue.arrayRemove([user.uid])
            : FieldValue.arrayUnion([user.uid]),
      });
    } catch (error) {
      _showChatNotice('Could not update reaction: $error');
    }
  }

  Future<void> _editMessage(
    QueryDocumentSnapshot<Map<String, dynamic>> message,
    Map<String, dynamic> data,
  ) async {
    final controller = TextEditingController(text: _chatMessageText(data));
    final updatedText = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          decoration: const InputDecoration(hintText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (updatedText == null || updatedText.isEmpty || !mounted) return;
    await message.reference.update({'content': updatedText, 'edited': true});
  }

  Future<void> _deleteMessage(
    QueryDocumentSnapshot<Map<String, dynamic>> message, {
    required bool forEveryone,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      if (forEveryone) {
        await message.reference.delete();
      } else {
        await message.reference.update({
          'deletedBy': FieldValue.arrayUnion([user.uid]),
        });
      }
    } catch (error) {
      _showChatNotice('Could not delete message: $error');
    }
  }

  Future<void> _forwardMessage(Map<String, dynamic> data) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final conversations = await FirebaseFirestore.instance
        .collection('conversations')
        .where('participants', arrayContains: user.uid)
        .get();
    if (!mounted) return;
    final targets = conversations.docs.where((conversation) {
      final participants = List<String>.from(
        conversation.data()['participants'] ?? const [],
      );
      return participants.any(
        (uid) => uid != user.uid && uid != widget.partnerUid,
      );
    }).toList();
    final targetUid = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xff171717),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Forward to')),
            if (targets.isEmpty)
              const ListTile(title: Text('No other conversations yet')),
            ...targets.map((conversation) {
              final conversationData = conversation.data();
              final participants = List<String>.from(
                conversationData['participants'] ?? const [],
              );
              final uid = participants.firstWhere(
                (id) => id != user.uid,
                orElse: () => '',
              );
              final details = Map<String, dynamic>.from(
                conversationData['participantDetails'] ?? const {},
              );
              final person = Map<String, dynamic>.from(
                details[uid] ?? const {},
              );
              return ListTile(
                leading: CircleAvatar(
                  backgroundImage: person['photoURL'] is String
                      ? NetworkImage(person['photoURL'])
                      : null,
                  child: person['photoURL'] == null
                      ? const Icon(Icons.person_outline)
                      : null,
                ),
                title: Text('${person['name'] ?? 'User'}'),
                onTap: uid.isEmpty
                    ? null
                    : () => Navigator.pop(sheetContext, uid),
              );
            }),
          ],
        ),
      ),
    );
    if (targetUid == null) return;

    try {
      final targetId = user.uid.compareTo(targetUid) < 0
          ? '${user.uid}_$targetUid'
          : '${targetUid}_${user.uid}';
      final forwarded = Map<String, dynamic>.from(data)
        ..remove('reactions')
        ..remove('deletedBy')
        ..['senderUid'] = user.uid
        ..['timestamp'] = FieldValue.serverTimestamp()
        ..['isRead'] = false
        ..['forwarded'] = true;
      final targetConversation = FirebaseFirestore.instance
          .collection('conversations')
          .doc(targetId);
      await targetConversation.collection('messages').add(forwarded);

      final myProfile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final targetProfile = await FirebaseFirestore.instance
          .collection('users')
          .doc(targetUid)
          .get();
      final target = targetProfile.data() ?? {};
      final preview = switch (data['type']) {
        'pdf' => '[PDF Document]',
        'image' => '[Image]',
        'flick' => 'Sent a Flick',
        _ => _chatMessageText(data),
      };
      await targetConversation.set({
        'participants': [user.uid, targetUid],
        'participantDetails': {
          user.uid: {
            'name': myProfile.data()?['name'] ?? user.displayName ?? 'User',
            'photoURL': myProfile.data()?['photoURL'] ?? user.photoURL,
          },
          targetUid: {
            'name': target['name'] ?? 'User',
            'photoURL': target['photoURL'],
          },
        },
        'lastMessage': {
          'text': preview,
          'senderUid': user.uid,
          'timestamp': FieldValue.serverTimestamp(),
          'isRead': false,
        },
      }, SetOptions(merge: true));
      _showChatNotice('Message forwarded');
    } catch (error) {
      _showChatNotice('Could not forward message: $error');
    }
  }

  Future<void> _clearChatForMe() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final messages = await FirebaseFirestore.instance
        .collection('conversations')
        .doc(_conversationId)
        .collection('messages')
        .get();
    for (var start = 0; start < messages.docs.length; start += 450) {
      final batch = FirebaseFirestore.instance.batch();
      for (final message in messages.docs.skip(start).take(450)) {
        batch.update(message.reference, {
          'deletedBy': FieldValue.arrayUnion([user.uid]),
        });
      }
      await batch.commit();
    }
    _showChatNotice('Chat cleared for you');
  }

  void _showChatNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ChatPdfReaderPage extends StatefulWidget {
  const _ChatPdfReaderPage({required this.url, required this.fileName});

  final String url;
  final String fileName;

  @override
  State<_ChatPdfReaderPage> createState() => _ChatPdfReaderPageState();
}

class _ChatPdfReaderPageState extends State<_ChatPdfReaderPage> {
  late Future<Uint8List> _pdfBytes;

  @override
  void initState() {
    super.initState();
    _pdfBytes = _loadPdf();
  }

  Future<Uint8List> _loadPdf() async {
    final reference = FirebaseStorage.instance.refFromURL(widget.url);
    final bytes = await reference.getData(20 * 1024 * 1024);
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('The PDF file is empty or unavailable.');
    }
    return bytes;
  }

  void _retry() => setState(() => _pdfBytes = _loadPdf());

  Future<void> _openExternally() async {
    final uri = Uri.tryParse(widget.url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.fileName)),
      body: FutureBuilder<Uint8List>(
        future: _pdfBytes,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.picture_as_pdf_outlined,
                      size: 42,
                      color: Colors.redAccent,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Unable to load this PDF.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error ?? 'No document data was returned.'}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry'),
                        ),
                        TextButton.icon(
                          onPressed: _openExternally,
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: const Text('Open externally'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }
          return PdfViewer.data(snapshot.data!, sourceName: widget.url);
        },
      ),
    );
  }
}

class _ChatImageViewerPage extends StatelessWidget {
  const _ChatImageViewerPage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Image.network(url),
        ),
      ),
    );
  }
}

class _ViyouVideoPlayerState extends State<ViyouVideoPlayer> {
  late VideoPlayerController _controller;
  YoutubePlayerController? _youtubeController;
  late final Future<void> _ready;
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _likesStream;
  Map<String, dynamic>? _preRollAd;
  bool _adDismissed = false;
  late final Future<List<BlogRecord>> _suggestionsFuture;

  double _playbackRate = 1.0;
  double _rateBeforeLongPress = 1.0;
  Timer? _sleepTimer;
  Duration? _sleepTimerDuration;
  String _selectedResolution = 'Auto';
  bool _switchingResolution = false;
  bool _isFullscreen = false;
  bool _viewCounted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _likesStream = FirebaseFirestore.instance
        .collection('blogs')
        .doc(widget.video.id)
        .snapshots();
    _ready = _initialize();
    _suggestionsFuture = _loadSuggestions();
  }

  Future<void> _initialize() async {
    unawaited(_recordSyncedWatchHistory(widget.video.id));
    final youtubeId = [widget.video.youtubeUrl, widget.video.video]
        .whereType<String>()
        .map(YoutubePlayerController.convertUrlToId)
        .whereType<String>()
        .firstOrNull;
    if (youtubeId != null) {
      _youtubeController = YoutubePlayerController.fromVideoId(
        videoId: youtubeId,
        autoPlay: true,
      );
      _adDismissed = true;
      return;
    }

    final source = widget.video.video;
    if (!hasPlayableMediaSource(source)) {
      throw const FormatException('This video has no playable media source');
    }
    _controller = await _initializeVideoControllerWithFallback(source!);
    _controller.addListener(_syncPlaybackState);
    _controller.setLooping(widget.video.isFlicker);
    await _controller.setPlaybackSpeed(_playbackRate);
    try {
      await _loadPreRollAd();
    } catch (error) {
      debugPrint('Pre-roll ad unavailable: $error');
      _preRollAd = null;
      _adDismissed = true;
    }
    if (_adDismissed) await _controller.play();
    _syncPlaybackState();
  }

  void _syncPlaybackState() {
    if (!mounted) return;
    setState(() {
      _position = _controller.value.position;
      _duration = _controller.value.duration;
    });
    if (!_viewCounted &&
        _controller.value.isPlaying &&
        _controller.value.position >= const Duration(seconds: 10)) {
      _viewCounted = true;
      final updates = <String, FieldValue>{'views': FieldValue.increment(1)};
      if (!widget.video.isFlicker) {
        updates['longVideoViews'] = FieldValue.increment(1);
      }
      unawaited(
        FirebaseFirestore.instance
            .collection('blogs')
            .doc(widget.video.id)
            .update(updates)
            .catchError((Object error) {
              debugPrint('Video view count update failed: $error');
            }),
      );
    }
  }

  Future<List<BlogRecord>> _loadSuggestions() async {
    final items = <BlogRecord>[];
    QueryDocumentSnapshot<Map<String, dynamic>>? lastDocument;
    var hasMore = true;
    while (hasMore && items.length < 20) {
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('blogs')
          .orderBy('date', descending: true)
          .limit(50);
      if (lastDocument != null) query = query.startAfterDocument(lastDocument);
      final snapshot = await query.get();
      if (snapshot.docs.isEmpty) break;
      lastDocument = snapshot.docs.last;
      hasMore = snapshot.docs.length == 50;
      items.addAll(
        snapshot.docs
            .where((document) => document.data()['visibility'] != 'unlisted')
            .map(BlogRecord.fromDocument)
            .where(
              (post) =>
                  post.status == 'published' &&
                  post.id != widget.video.id &&
                  !post.isFlicker &&
                  (hasPlayableMediaSource(post.video) ||
                      (post.youtubeUrl != null &&
                          YoutubePlayerController.convertUrlToId(
                                post.youtubeUrl!,
                              ) !=
                              null)),
            ),
      );
    }

    final sameCategory =
        items.where((post) => post.category == widget.video.category).toList()
          ..sort((a, b) => b.date.compareTo(a.date));
    final otherCategories =
        items.where((post) => post.category != widget.video.category).toList()
          ..shuffle();
    return [...sameCategory, ...otherCategories].take(8).toList();
  }

  Future<void> _loadPreRollAd() async {
    final settings =
        (await FirebaseFirestore.instance
                .collection('settings')
                .doc('ads')
                .get())
            .data();
    if (settings?['showAds'] == false ||
        settings?['enablePreRollAds'] == false) {
      if (mounted) {
        setState(() {
          _preRollAd = null;
          _adDismissed = true;
        });
      }
      _controller.play();
      return;
    }
    final snapshot = await FirebaseFirestore.instance
        .collection('promotions')
        .where('status', isEqualTo: 'approved')
        .limit(30)
        .get();
    final items = snapshot.docs.map((doc) => doc.data()).toList();
    final active = ViyouPromotionHelper.filterApprovedPromotions(
      items,
      type: 'preroll',
      category: widget.video.category,
    );
    if (!mounted) return;
    setState(() {
      _preRollAd = active.isEmpty ? null : active.first;
      _adDismissed = _preRollAd == null;
    });
    if (_preRollAd != null) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  Future<void> _toggleLike() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Login to like this video')));
      return;
    }
    final ref = FirebaseFirestore.instance
        .collection('blogs')
        .doc(widget.video.id);
    final currentLikes = (await ref.get()).data()?['likes'];
    final alreadyLiked =
        currentLikes is List &&
        currentLikes.map((value) => '$value').contains(user.uid);
    if (currentLikes is List) {
      await ref.update({
        'likes': alreadyLiked
            ? FieldValue.arrayRemove([user.uid])
            : FieldValue.arrayUnion([user.uid]),
      });
    } else if (currentLikes is num) {
      await ref.update({'likes': FieldValue.increment(1)});
    } else {
      await ref.update({
        'likes': FieldValue.arrayUnion([user.uid]),
      });
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(alreadyLiked ? 'Like removed' : 'Video liked')),
      );
    }
  }

  Future<void> _shareVideo() async {
    final value = widget.video.video ?? widget.video.id;
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Video link copied')));
    }
  }

  void _dismissPreRollAd() {
    if (!mounted) return;
    setState(() {
      _adDismissed = true;
      _preRollAd = null;
    });
    _controller.play();
  }

  Future<void> _setPlaybackRate(double value) async {
    _playbackRate = value;
    final youtube = _youtubeController;
    if (youtube != null) {
      await youtube.setPlaybackRate(value);
    } else {
      await _controller.setPlaybackSpeed(value);
    }
    if (mounted) setState(() {});
  }

  Future<List<double>> _availablePlaybackRates() async {
    final youtube = _youtubeController;
    if (youtube != null) {
      try {
        final rates = await youtube.availablePlaybackRates;
        if (rates.isNotEmpty) return rates;
      } catch (_) {}
    }
    return const [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
  }

  void _setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerDuration = duration;
    if (duration != null) {
      _sleepTimer = Timer(duration, _pauseForSleepTimer);
    }
    if (mounted) setState(() {});
  }

  Future<void> _pauseForSleepTimer() async {
    _sleepTimer = null;
    _sleepTimerDuration = null;
    final youtube = _youtubeController;
    if (youtube != null) {
      await youtube.pauseVideo();
    } else if (_controller.value.isInitialized) {
      await _controller.pause();
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sleep timer paused playback')),
    );
  }

  List<MapEntry<String, String>> _availableResolutions() {
    final entries = widget.video.videoQualities.entries
        .where(
          (entry) =>
              entry.key.trim().isNotEmpty && entry.value.trim().isNotEmpty,
        )
        .toList();
    int resolutionValue(String label) =>
        int.tryParse(RegExp(r'\d+').firstMatch(label)?.group(0) ?? '') ?? 0;
    entries.sort(
      (first, second) =>
          resolutionValue(second.key).compareTo(resolutionValue(first.key)),
    );
    return entries;
  }

  Future<void> _setResolution(String quality, String? source) async {
    final targetSource = quality == 'Auto' ? widget.video.video : source;
    if (targetSource == null || targetSource.isEmpty) {
      if (quality == 'Auto' && mounted) {
        setState(() => _selectedResolution = 'Auto');
      }
      return;
    }
    if (quality == 'Auto' && _selectedResolution == 'Auto') {
      if (mounted) setState(() => _selectedResolution = 'Auto');
      return;
    }
    if (_youtubeController != null) return;

    final oldController = _controller;
    final wasPlaying = oldController.value.isPlaying;
    final position = oldController.value.position;
    if (mounted) setState(() => _switchingResolution = true);
    VideoPlayerController? replacement;
    try {
      replacement = await _initializeVideoControllerWithFallback(targetSource);
      await replacement.setLooping(widget.video.isFlicker);
      await replacement.setPlaybackSpeed(_playbackRate);
      await replacement.seekTo(position);
      replacement.addListener(_syncPlaybackState);
      oldController.removeListener(_syncPlaybackState);
      _controller = replacement;
      await oldController.dispose();
      if (wasPlaying) await replacement.play();
      if (mounted) setState(() => _selectedResolution = quality);
    } catch (error) {
      if (replacement != null && !identical(replacement, _controller)) {
        await replacement.dispose();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not change resolution: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _switchingResolution = false);
    }
  }

  Future<void> _showPlayerSettings() async {
    var section = 'main';
    final ratesFuture = _availablePlaybackRates();
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xff181818),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final youtube = _youtubeController != null;
          final resolutions = _availableResolutions();
          final sleepLabel = _sleepTimerDuration == null
              ? 'Off'
              : '${_sleepTimerDuration!.inMinutes} minutes';
          final title = switch (section) {
            'speed' => 'Playback speed',
            'sleep' => 'Sleep timer',
            'quality' => 'Quality',
            _ => 'Settings',
          };
          void goTo(String next) => setSheetState(() => section = next);
          final items = <Widget>[];

          if (section == 'main') {
            items.addAll([
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Sleep timer'),
                trailing: _settingsValue(sleepLabel),
                onTap: () => goTo('sleep'),
              ),
              ListTile(
                leading: const Icon(Icons.speed_rounded),
                title: const Text('Playback speed'),
                trailing: _settingsValue(
                  _playbackRate == 1 ? 'Normal' : '${_playbackRate}x',
                ),
                onTap: () => goTo('speed'),
              ),
              ListTile(
                leading: const Icon(Icons.high_quality_outlined),
                title: const Text('Quality'),
                trailing: _settingsValue(
                  _switchingResolution ? 'Changing...' : _selectedResolution,
                ),
                onTap: () => goTo('quality'),
              ),
            ]);
          } else if (section == 'speed') {
            items.add(
              FutureBuilder<List<double>>(
                future: ratesFuture,
                builder: (context, snapshot) {
                  final rates = snapshot.data ?? const <double>[];
                  if (rates.isEmpty) {
                    return const ListTile(
                      title: Text('Loading available speeds...'),
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: rates.map((rate) {
                      final selected = rate == _playbackRate;
                      return ListTile(
                        title: Text(rate == 1 ? 'Normal' : '${rate}x'),
                        trailing: selected
                            ? const Icon(
                                Icons.check_rounded,
                                color: Color(0xfff59e0b),
                              )
                            : null,
                        onTap: () {
                          unawaited(_setPlaybackRate(rate));
                          goTo('main');
                        },
                      );
                    }).toList(),
                  );
                },
              ),
            );
          } else if (section == 'sleep') {
            const options = <Duration?>[
              null,
              Duration(minutes: 5),
              Duration(minutes: 10),
              Duration(minutes: 15),
              Duration(minutes: 30),
              Duration(minutes: 45),
              Duration(minutes: 60),
            ];
            items.addAll(
              options.map((duration) {
                final label = duration == null
                    ? 'Off'
                    : '${duration.inMinutes} minutes';
                final selected = duration == _sleepTimerDuration;
                return ListTile(
                  title: Text(label),
                  trailing: selected
                      ? const Icon(
                          Icons.check_rounded,
                          color: Color(0xfff59e0b),
                        )
                      : null,
                  onTap: () {
                    _setSleepTimer(duration);
                    goTo('main');
                  },
                );
              }),
            );
          } else {
            items.add(
              ListTile(
                title: const Text('Auto'),
                subtitle: Text(
                  youtube
                      ? 'YouTube adjusts quality automatically'
                      : resolutions.isEmpty
                      ? 'No alternate source qualities are available'
                      : 'Use the default video source',
                ),
                trailing: _selectedResolution == 'Auto'
                    ? const Icon(Icons.check_rounded, color: Color(0xfff59e0b))
                    : null,
                onTap: () {
                  _setResolution('Auto', null);
                  goTo('main');
                },
              ),
            );
            if (!youtube) {
              items.addAll(
                resolutions.map((entry) {
                  final selected = entry.key == _selectedResolution;
                  return ListTile(
                    title: Text(entry.key),
                    trailing: selected
                        ? const Icon(
                            Icons.check_rounded,
                            color: Color(0xfff59e0b),
                          )
                        : null,
                    onTap: () {
                      unawaited(_setResolution(entry.key, entry.value));
                      goTo('main');
                    },
                  );
                }),
              );
            }
          }

          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.72,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 34,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    color: Colors.white30,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    if (section != 'main')
                      IconButton(
                        onPressed: () => goTo('main'),
                        icon: const Icon(Icons.arrow_back_rounded),
                        tooltip: 'Back to settings',
                      ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Close settings',
                    ),
                  ],
                ),
                const Divider(height: 1, color: Colors.white12),
                Flexible(child: ListView(shrinkWrap: true, children: items)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _settingsValue(String value) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(value, style: TextStyle(color: Colors.grey[400])),
      const SizedBox(width: 6),
      const Icon(Icons.chevron_right_rounded),
    ],
  );

  void _togglePlayback() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
    if (mounted) setState(() {});
  }

  void _skipBy(int seconds) {
    final target = _controller.value.position + Duration(seconds: seconds);
    final duration = _controller.value.duration;
    final safeTarget = target < Duration.zero
        ? Duration.zero
        : target > duration
        ? duration
        : target;
    _controller.seekTo(safeTarget);
  }

  Future<void> _toggleFullscreen() async {
    final entering = !_isFullscreen;
    if (entering) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (mounted) setState(() => _isFullscreen = entering);
  }

  Widget _buildPlayerControls({required bool fullscreen}) {
    final controlButtonConstraints = const BoxConstraints.tightFor(
      width: 40,
      height: 40,
    );
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      padding: EdgeInsets.fromLTRB(8, 2, 8, fullscreen ? 8 : 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            min: 0,
            max: _duration.inMilliseconds > 0
                ? _duration.inMilliseconds.toDouble()
                : 1,
            value: _position.inMilliseconds
                .clamp(0, _duration.inMilliseconds)
                .toDouble(),
            onChanged: (value) =>
                _controller.seekTo(Duration(milliseconds: value.round())),
            activeColor: const Color(0xfff59e0b),
          ),
          Row(
            children: [
              IconButton(
                constraints: controlButtonConstraints,
                padding: EdgeInsets.zero,
                tooltip: 'Back 10 seconds',
                onPressed: () => _skipBy(-10),
                icon: const Icon(Icons.replay_10_rounded),
              ),
              IconButton(
                constraints: controlButtonConstraints,
                padding: EdgeInsets.zero,
                tooltip: 'Play or pause',
                onPressed: _togglePlayback,
                icon: Icon(
                  _controller.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                constraints: controlButtonConstraints,
                padding: EdgeInsets.zero,
                tooltip: 'Forward 10 seconds',
                onPressed: () => _skipBy(10),
                icon: const Icon(Icons.forward_10_rounded),
              ),
              Flexible(
                child: Text(
                  '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[200], fontSize: 12),
                ),
              ),
              IconButton(
                constraints: controlButtonConstraints,
                padding: EdgeInsets.zero,
                tooltip: 'Player settings',
                onPressed: _showPlayerSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
              IconButton(
                constraints: controlButtonConstraints,
                padding: EdgeInsets.zero,
                tooltip: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                onPressed: _toggleFullscreen,
                icon: Icon(
                  fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerSurface({bool fullscreen = false}) {
    final youtubeController = _youtubeController;
    if (youtubeController != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          YoutubePlayer(
            controller: youtubeController,
            aspectRatio: 16 / 9,
            autoFullScreen: true,
            enableFullScreenOnVerticalDrag: true,
          ),
          Positioned(
            right: 8,
            bottom: 48,
            child: Material(
              color: Colors.black.withValues(alpha: 0.62),
              shape: const CircleBorder(),
              child: IconButton(
                onPressed: _showPlayerSettings,
                tooltip: 'Player settings',
                icon: const Icon(Icons.settings_outlined, color: Colors.white),
              ),
            ),
          ),
        ],
      );
    }
    final aspectRatio = _controller.value.aspectRatio > 0
        ? _controller.value.aspectRatio
        : 16 / 9;
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(fullscreen ? 0 : 18),
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  onTapUp: (details) {
                    final fraction =
                        details.localPosition.dx / constraints.maxWidth;
                    if (fraction < 0.4) {
                      _skipBy(-10);
                    } else if (fraction > 0.6) {
                      _skipBy(10);
                    } else {
                      _togglePlayback();
                    }
                  },
                  onLongPressStart: (_) {
                    _rateBeforeLongPress = _playbackRate;
                    _setPlaybackRate(2.0);
                  },
                  onLongPressEnd: (_) => _setPlaybackRate(_rateBeforeLongPress),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayer(_controller),
                      if (!_controller.value.isPlaying)
                        const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            size: 78,
                            color: Colors.white70,
                          ),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _buildPlayerControls(fullscreen: fullscreen),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    final totalSeconds = value.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  bool _isImageSource(String? source) =>
      source != null &&
      (source.startsWith('http://') ||
          source.startsWith('https://') ||
          source.startsWith('data:image/'));

  Widget _imageSource(String? source, {BoxFit fit = BoxFit.cover}) {
    if (source == null || source.isEmpty) {
      return const ColoredBox(
        color: Color(0xff1d1d1d),
        child: Icon(Icons.play_circle_outline, color: Color(0xfff59e0b)),
      );
    }
    if (source.startsWith('data:image/')) {
      final comma = source.indexOf(',');
      if (comma > 0) {
        try {
          return Image.memory(
            base64Decode(source.substring(comma + 1)),
            fit: fit,
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: Color(0xff1d1d1d),
              child: Icon(Icons.play_circle_outline, color: Color(0xfff59e0b)),
            ),
          );
        } catch (_) {
          return const ColoredBox(
            color: Color(0xff1d1d1d),
            child: Icon(Icons.play_circle_outline, color: Color(0xfff59e0b)),
          );
        }
      }
    }
    return Image.network(
      source,
      fit: fit,
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: Color(0xff1d1d1d),
        child: Icon(Icons.play_circle_outline, color: Color(0xfff59e0b)),
      ),
    );
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _youtubeController?.close();
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (_youtubeController == null) {
      _controller.removeListener(_syncPlaybackState);
      _controller.dispose();
    }
    super.dispose();
  }

  Widget _suggestionTile(BlogRecord post) {
    final thumb = post.primaryImage;
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ViyouVideoPlayer(video: post)),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xff121212),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 118,
                height: 78,
                child: _isImageSource(thumb)
                    ? _imageSource(thumb, fit: BoxFit.cover)
                    : const ColoredBox(
                        color: Color(0xff1d1d1d),
                        child: Icon(
                          Icons.play_circle_outline,
                          color: Color(0xfff59e0b),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    post.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '@${post.author}',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${post.category} • ${post.likesCount} likes',
                    style: TextStyle(color: Colors.grey[500], fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionsPanel() => FutureBuilder<List<BlogRecord>>(
    future: _suggestionsFuture,
    builder: (context, snapshot) {
      final items = snapshot.data ?? const <BlogRecord>[];
      if (items.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Up Next',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          ...items.map(_suggestionTile),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _isFullscreen
          ? null
          : AppBar(title: const Text('Watch'), backgroundColor: Colors.black),
      body: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Unable to play this video'),
                    const SizedBox(height: 8),
                    Text(
                      snapshot.error.toString(),
                      textAlign: TextAlign.center,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
            );
          }

          return LayoutBuilder(
            builder: (context, constraints) {
              if (_isFullscreen) {
                return ColoredBox(
                  color: Colors.black,
                  child: _buildPlayerSurface(fullscreen: true),
                );
              }
              final isWide = constraints.maxWidth >= 980;
              final mainColumn = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildPlayerSurface(),
                  const SizedBox(height: 16),
                  Text(
                    widget.video.title,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundImage: widget.video.authorPhoto == null
                            ? null
                            : NetworkImage(widget.video.authorPhoto!),
                        child: widget.video.authorPhoto == null
                            ? Text(
                                widget.video.author.isEmpty
                                    ? 'V'
                                    : widget.video.author[0],
                              )
                            : null,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.video.author,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            Text(
                              '${widget.video.category} • ${widget.video.date.year}',
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: _likesStream,
                        builder: (context, snapshot) {
                          final rawLikes = snapshot.data?.data()?['likes'];
                          final count = rawLikes is List
                              ? rawLikes.length
                              : rawLikes is num
                              ? rawLikes.toInt()
                              : widget.video.likesCount;
                          final userId = FirebaseAuth.instance.currentUser?.uid;
                          final isLiked =
                              userId != null &&
                              rawLikes is List &&
                              rawLikes
                                  .map((value) => '$value')
                                  .contains(userId);
                          return FilledButton.icon(
                            onPressed: _toggleLike,
                            icon: Icon(
                              isLiked
                                  ? Icons.thumb_up_alt_rounded
                                  : Icons.thumb_up_alt_outlined,
                            ),
                            label: Text('$count'),
                          );
                        },
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: _shareVideo,
                        icon: const Icon(Icons.share_outlined),
                        label: const Text('Share'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xff101010),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Description',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.video.content.isEmpty
                              ? 'No description available for this video.'
                              : widget.video.content,
                          style: TextStyle(
                            color: Colors.grey[300],
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  BlogComments(blog: widget.video),
                ],
              );

              final sidePanel = SizedBox(
                width: isWide ? 340 : double.infinity,
                child: _suggestionsPanel(),
              );

              return Stack(
                children: [
                  SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      isWide ? 20 : 12,
                      8,
                      isWide ? 20 : 12,
                      24,
                    ),
                    child: isWide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: mainColumn),
                              const SizedBox(width: 22),
                              sidePanel,
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              mainColumn,
                              const SizedBox(height: 18),
                              sidePanel,
                            ],
                          ),
                  ),
                  if (_preRollAd != null && !_adDismissed)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: .72),
                        child: Center(
                          child: SizedBox(
                            width: 360,
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'Sponsored',
                                      style: TextStyle(
                                        color: Color(0xfff59e0b),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (_preRollAd!['mediaData'] is String &&
                                        ((_preRollAd!['mediaData'] as String)
                                                .startsWith('http://') ||
                                            (_preRollAd!['mediaData'] as String)
                                                .startsWith('https://') ||
                                            (_preRollAd!['mediaData'] as String)
                                                .startsWith('data:image/')))
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child:
                                            (_preRollAd!['mediaData'] as String)
                                                .startsWith('data:image/')
                                            ? Image.memory(
                                                base64Decode(
                                                  (_preRollAd!['mediaData']
                                                          as String)
                                                      .substring(
                                                        (_preRollAd!['mediaData']
                                                                    as String)
                                                                .indexOf(',') +
                                                            1,
                                                      ),
                                                ),
                                                fit: BoxFit.cover,
                                                height: 170,
                                                width: double.infinity,
                                              )
                                            : Image.network(
                                                _preRollAd!['mediaData'],
                                                fit: BoxFit.cover,
                                                height: 170,
                                                width: double.infinity,
                                              ),
                                      )
                                    else
                                      SizedBox(
                                        height: 170,
                                        child: Container(
                                          decoration: const BoxDecoration(
                                            color: Color(0xff202020),
                                            borderRadius: BorderRadius.all(
                                              Radius.circular(12),
                                            ),
                                          ),
                                          child: const Center(
                                            child: Icon(
                                              Icons.campaign_outlined,
                                              size: 42,
                                            ),
                                          ),
                                        ),
                                      ),
                                    const SizedBox(height: 14),
                                    Text(
                                      '${_preRollAd!['title'] ?? 'Brand pre-roll'}',
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Sponsored content for ${widget.video.category}',
                                      style: TextStyle(color: Colors.grey[500]),
                                    ),
                                    const SizedBox(height: 18),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: FilledButton(
                                            onPressed: () {
                                              final url =
                                                  _preRollAd!['targetUrl'];
                                              if (url is String &&
                                                  url.isNotEmpty) {
                                                launchUrl(
                                                  Uri.parse(url),
                                                  mode: LaunchMode
                                                      .externalApplication,
                                                );
                                              }
                                            },
                                            child: const Text('Open offer'),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        TextButton(
                                          onPressed: _dismissPreRollAd,
                                          child: const Text('Skip'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
