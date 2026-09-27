// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:flutter_app/main.dart';
import 'package:flutter_app/firebase_options.dart';

void main() {
  testWidgets('Viyou home screen renders', (WidgetTester tester) async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await tester.pumpWidget(const ViyouApp());

    expect(find.text('Viyou.in'), findsOneWidget);
    expect(find.text('Stories'), findsOneWidget);
    expect(find.text('Latest from creators'), findsOneWidget);
  });

  testWidgets('Studio dashboard renders on phone-sized screens', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(size: Size(390, 844)),
        child: MaterialApp(home: ViyouStudioDashboardPage()),
      ),
    );

    expect(find.text('Creator Studio'), findsWidgets);
    expect(find.text('Overview'), findsOneWidget);
  });

  test('promotion helper selects approved ads by type and target category', () {
    final promos = [
      {
        'type': 'preroll',
        'status': 'approved',
        'targetCategories': ['Gaming'],
        'impressions_goal': 1000,
        'impressions_served': 100,
        'promoExpiry': DateTime.now()
            .add(const Duration(days: 1))
            .toIso8601String(),
      },
      {
        'type': 'external',
        'status': 'approved',
        'promoExpiry': DateTime.now()
            .add(const Duration(days: 2))
            .toIso8601String(),
      },
      {
        'type': 'preroll',
        'status': 'rejected',
        'targetCategories': ['Gaming'],
      },
    ];

    final matching = ViyouPromotionHelper.filterApprovedPromotions(
      promos,
      type: 'preroll',
      category: 'Gaming',
    );

    expect(matching, hasLength(1));
    expect(matching.first['type'], 'preroll');
    expect(matching.first['targetCategories'], contains('Gaming'));
  });

  test(
    'playable media guard accepts http and base64 video urls and rejects image-only sources',
    () {
      expect(
        hasPlayableMediaSource('https://cdn.example.com/video.mp4'),
        isTrue,
      );
      expect(hasPlayableMediaSource('https://youtu.be/abc123xyz'), isTrue);
      expect(
        hasPlayableMediaSource('data:video/mp4;base64,AAAAIGZ0eXBpc29t'),
        isTrue,
      );
      expect(hasPlayableMediaSource('data:audio/mpeg;base64,AAAA'), isTrue);
      expect(hasPlayableMediaSource('data:image/png;base64,AAAA'), isFalse);
      expect(hasPlayableMediaSource(null), isFalse);
    },
  );

  test('video upload MIME follows common container extensions', () {
    expect(videoContentTypeForName('clip.MP4'), 'video/mp4');
    expect(videoContentTypeForName('clip.MOV'), 'video/quicktime');
    expect(videoContentTypeForName('clip.webm'), 'video/webm');
  });

  test('promotion helper enforces gallery and duration limits', () {
    expect(
      ViyouPromotionHelper.isMediaGalleryValid([
        'a',
        'b',
        'c',
        'd',
        'e',
      ], maxCount: 5),
      isTrue,
    );
    expect(
      ViyouPromotionHelper.isMediaGalleryValid([
        'a',
        'b',
        'c',
        'd',
        'e',
        'f',
      ], maxCount: 5),
      isFalse,
    );
    expect(ViyouPromotionHelper.isVideoDurationValid(60), isTrue);
    expect(ViyouPromotionHelper.isVideoDurationValid(61), isFalse);
  });
}
