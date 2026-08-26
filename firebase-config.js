// d:\Viyo\firebase-config.js
// Import the functions you need from the SDKs you need
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-app.js";
import { initializeFirestore, persistentLocalCache, persistentMultipleTabManager, doc, getDoc } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-firestore.js";
import { getAuth } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-auth.js";
import { getAnalytics } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-analytics.js";
import { getStorage } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-storage.js";

// Your web app's Firebase configuration
const firebaseConfig = {
  apiKey: "AIzaSyCG0Cc7zoNj8yP_QEmU873KpAWtAPmiI5Y",
  authDomain: "viyou-6265f.firebaseapp.com",
  databaseURL: "https://viyou-6265f-default-rtdb.firebaseio.com",
  projectId: "viyou-6265f",
  storageBucket: "viyou-6265f.firebasestorage.app",
  messagingSenderId: "97740586242",
  appId: "1:97740586242:web:82c9c13f36dd36ed50561b",
  measurementId: "G-0S8T13BK1W"
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const db = initializeFirestore(app, {
  localCache: persistentLocalCache({tabManager: persistentMultipleTabManager()})
});
const auth = getAuth(app);
const analytics = getAnalytics(app);
const storage = getStorage(app);

// Simple cached plan helper to avoid a Firestore read on every upload
let _planCache = { value: null, expires: 0 };
const PLAN_CACHE_TTL_MS = 30 * 1000; // 30 seconds cache
const SPARK_MAX_BYTES = 1 * 1024 * 1024; // 1 MB

async function fetchPlanDoc() {
  const now = Date.now();
  if (_planCache.value && _planCache.expires > now) return _planCache.value;
  try {
    const planRef = doc(db, 'config', 'plan');
    const snap = await getDoc(planRef);
    if (snap.exists()) {
      const data = snap.data();
      const plan = data && data.plan ? String(data.plan) : 'spark';
      _planCache = { value: plan, expires: now + PLAN_CACHE_TTL_MS };
      return plan;
    }
  } catch (e) {
    // ignore - default to spark if any error
    console.error('fetchPlanDoc error', e);
  }
  return 'spark';
}

// Returns true if a file of size `sizeBytes` is allowed to be uploaded under current plan.
async function isUploadAllowed(sizeBytes) {
  const plan = await fetchPlanDoc();
  if (plan === 'blaze') return true;
  return sizeBytes <= SPARK_MAX_BYTES;
}

// Export the initialized services and helper
export { db, auth, app, analytics, storage, firebaseConfig, isUploadAllowed, SPARK_MAX_BYTES };
