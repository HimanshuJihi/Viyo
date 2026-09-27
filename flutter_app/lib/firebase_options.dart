// Generated Firebase configuration for the Viyou Firebase project.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError('Firebase is not configured for this platform.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCi6mKq4JwZg1JTrmnX2WWy5Foffe4ZVFI',
    appId: '1:97740586242:android:281cf6596e1953db50561b',
    messagingSenderId: '97740586242',
    projectId: 'viyou-6265f',
    databaseURL: 'https://viyou-6265f-default-rtdb.firebaseio.com',
    storageBucket: 'viyou-6265f.firebasestorage.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCG0Cc7zoNj8yP_QEmU873KpAWtAPmiI5Y',
    appId: '1:97740586242:web:82c9c13f36dd36ed50561b',
    messagingSenderId: '97740586242',
    projectId: 'viyou-6265f',
    authDomain: 'viyou-6265f.firebaseapp.com',
    databaseURL: 'https://viyou-6265f-default-rtdb.firebaseio.com',
    storageBucket: 'viyou-6265f.firebasestorage.app',
    measurementId: 'G-0S8T13BK1W',
  );
}
