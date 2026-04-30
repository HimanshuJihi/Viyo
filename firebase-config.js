// d:\Viyo\firebase-config.js
// Import the functions you need from the SDKs you need
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-app.js";
import { getFirestore } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-firestore.js";
import { getAuth } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-auth.js";
import { getAnalytics } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-analytics.js";

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
const db = getFirestore(app);
const auth = getAuth(app);
const analytics = getAnalytics(app);

// Export the initialized services
export { db, auth, app, analytics, firebaseConfig };
