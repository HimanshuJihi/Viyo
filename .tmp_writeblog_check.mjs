

        document.addEventListener('DOMContentLoaded', () => {
            lucide.createIcons();
            const observer = new MutationObserver((mutations) => {
                if (mutations.some(m => m.addedNodes.length > 0)) {
                    observer.disconnect();
                    lucide.createIcons();
                    observer.observe(document.body, { childList: true, subtree: true });
                }
            });
            observer.observe(document.body, { childList: true, subtree: true });
        });
    


        const initialTheme = localStorage.getItem('theme') || 'dark';
        if (initialTheme !== 'dark') document.body.classList.add(initialTheme + '-mode');
    

        import { initializeApp } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-app.js";
        import { getFirestore, collection, addDoc, doc, getDoc, updateDoc, setDoc, query, where, getDocs, orderBy, limit, arrayUnion, arrayRemove, increment } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-firestore.js";
        import { getAuth, onAuthStateChanged } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-auth.js";
        import { getStorage, ref, uploadBytesResumable, getDownloadURL } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-storage.js";
        import { firebaseConfig, storage } from "./firebase-config.js";


        const app = initializeApp(firebaseConfig);
        const db = getFirestore(app);
        const auth = getAuth(app);
        let isUserVerified = false;
        let currentPostType = 'blog';
        window.maxUploadSizeMB = 5; // Default max upload size
        window.maxVideoUploadSizeMB = 1;
        window.maxFlickUploadSizeMB = 1;
        // Flicks Studio Variables
        let fsSegments = [];
        let fsRecorder = null;
        let fsStream = null;
        let fsTotalTimeMs = 0;
        let fsChunks = [];
        let fsTime = 0;
        let fsFacingMode = 'user';
        let fsTimeThisSegment = 0;
        let fsTimerInterval = null;
        let fsAudioAdded = false;
        let fsOriginalAudioVolume = 0.2;
        let fsMusicVolume = 1;
        let videoDurationForTrim = 0;
        let fsVideoDuration = 0;
        let fsTrimStart = 0;
        let fsTrimEnd = 100;
        let fsTrimStartPercent = 0;
        let fsTrimEndPercent = 100;
        let fsCurrentFilterIdx = 0;
        let fsFilters = ['none', 'grayscale(100%)', 'sepia(100%)', 'contrast(150%)', 'invert(100%)', 'hue-rotate(90deg)'];
        const FS_MAX_TIME = 30000;
        let fsAllAudios = [];
        window.selectedFSAudioUrl = null;
        window.selectedFSAudioName = null;
        window.selectedFSAudioId = null;
        window.fsAudioTrimStart = 0;
        window.isFSRendering = false;
        const fsProSettings = { speed: 1, ramp: 'none', fps: 30, fit: 'cover', mirror: 'off', quality: 'high', look: 'none', strength: 0.65, exposure: 0, contrast: 1, saturation: 1, temperature: 0, vignette: 0, grain: 0, textFont: 'font-classic', textWeight: 600, textColor: '#ffffff', textStyle: 'normal', textAnimation: 'none', textBg: 'none', textAlign: 'center', letterSpacing: 0 };

        function fsGetRenderFilter() {
            const lookFilters = { none: '', cinematic: 'sepia(12%) contrast(115%) saturate(115%)', noir: 'grayscale(100%) contrast(135%)', vintage: 'sepia(45%) saturate(85%) contrast(105%)', dream: 'brightness(110%) saturate(82%) blur(0.3px)', vivid: 'saturate(155%) contrast(115%)', cool: 'hue-rotate(175deg) saturate(110%)', warm: 'sepia(28%) saturate(125%)' };
            const base = lookFilters[fsProSettings.look] || fsFilters[fsCurrentFilterIdx] || '';
            return `${base} brightness(${1 + Number(fsProSettings.exposure) * Number(fsProSettings.strength)}) contrast(${Number(fsProSettings.contrast)}) saturate(${Number(fsProSettings.saturation)}) hue-rotate(${Number(fsProSettings.temperature)}deg)`;
        }

        function fsApplyProSettings() {
            const video = document.getElementById('fs-preview-video');
            if (!video) return;
            video.playbackRate = Number(fsProSettings.speed) || 1;
            video.style.filter = fsGetRenderFilter();
            video.style.objectFit = fsProSettings.fit === 'contain' ? 'contain' : 'cover';
            video.style.transform = fsProSettings.mirror === 'on' ? 'scaleX(-1)' : 'none';
            document.querySelectorAll('.fs-text').forEach(el => fsApplyTextSettings(el));
        }

        function fsApplyTextSettings(el) {
            el.classList.remove('font-classic', 'font-modern', 'font-neon', 'font-typewriter', 'font-strong', 'font-serif', 'font-hand');
            el.classList.add(fsProSettings.textFont);
            el.style.fontWeight = fsProSettings.textWeight;
            el.style.color = fsProSettings.textColor;
            el.style.textAlign = fsProSettings.textAlign;
            el.style.letterSpacing = `${fsProSettings.letterSpacing}px`;
            el.style.textTransform = fsProSettings.textStyle === 'uppercase' ? 'uppercase' : 'none';
            el.style.fontStyle = fsProSettings.textStyle === 'italic' ? 'italic' : 'normal';
            el.style.textShadow = fsProSettings.textStyle === 'glow' ? `0 0 12px ${fsProSettings.textColor}` : (fsProSettings.textStyle === 'outline' ? `1px 1px 0 #000, -1px -1px 0 #000` : '0 1px 4px rgba(0,0,0,0.8)');
            el.style.background = fsProSettings.textBg === 'glass' ? 'rgba(255,255,255,0.18)' : (fsProSettings.textBg === 'solid' ? fsProSettings.textColor : (fsProSettings.textBg === 'highlight' ? 'rgba(245,158,11,0.75)' : 'transparent'));
            el.style.backdropFilter = fsProSettings.textBg === 'glass' ? 'blur(8px)' : 'none';
        }

        window.toggleFSProPanel = function() {
            const panel = document.getElementById('fs-pro-panel');
            panel.classList.toggle('open');
            if (panel.classList.contains('open')) panel.querySelector('select')?.focus();
        };

        document.querySelectorAll('[data-fs-setting]').forEach(select => {
            select.addEventListener('change', () => {
                const key = select.dataset.fsSetting;
                fsProSettings[key] = ['speed', 'fps', 'strength', 'exposure', 'contrast', 'saturation', 'temperature', 'vignette', 'grain', 'textWeight', 'letterSpacing'].includes(key) ? Number(select.value) : select.value;
                fsApplyProSettings();
            });
        });

        // --- Toast Notification Logic ---
        function showToast(message, type = 'info') {
            let container = document.getElementById('toast-container');
            if (!container) {
                container = document.createElement('div');
                container.id = 'toast-container';
                document.body.appendChild(container);
            }

            const toast = document.createElement('div');
            toast.className = `toast ${type}`;
            
            let iconClass = 'info';
            if (type === 'success') iconClass = 'check-circle';
            if (type === 'error') iconClass = 'x-circle';

            toast.innerHTML = `<span class="toast-icon"><i data-lucide="${iconClass}"></i></span><span>${message}</span>`;
            container.appendChild(toast);

            setTimeout(() => { toast.classList.add('show'); }, 100);

            setTimeout(() => {
                toast.classList.remove('show');
                toast.addEventListener('transitionend', () => { if (toast.parentNode) toast.parentNode.removeChild(toast); });
            }, 4000);
        }

        // --- Character Counter Logic ---
        const contentArea = document.getElementById('content');
        const charCounter = document.getElementById('char-counter');
        const titleInput = document.getElementById('title');
        const titleCharCounter = document.getElementById('title-char-counter');
        
        function updateCharCounter() {
            if (contentArea && charCounter) {
                const maxLength = contentArea.getAttribute('maxlength') || 5000;
                const currentLength = contentArea.value.length;
                charCounter.textContent = `(${currentLength} / ${maxLength})`;
                if (currentLength > maxLength * 0.9) {
                    charCounter.style.color = '#ffc107'; // Yellow warning
                } else {
                    charCounter.style.color = '#aaa'; // Default
                }
            }
            if (titleInput && titleCharCounter) {
                const maxLength = titleInput.getAttribute('maxlength') || 100;
                const currentLength = titleInput.value.length;
                titleCharCounter.textContent = `(${currentLength} / ${maxLength})`;
                if (currentLength > maxLength * 0.9) {
                    titleCharCounter.style.color = '#ffc107';
                } else {
                    titleCharCounter.style.color = '#aaa';
                }
            }
        }
        
        if (contentArea) {
            contentArea.addEventListener('input', updateCharCounter);
        }
        if (titleInput) {
            titleInput.addEventListener('input', updateCharCounter);
        }
            
        // Helper function to get video from IndexedDB
        function retrieveVideoFromIndexedDB() {
            return new Promise((resolve, reject) => {
                const request = indexedDB.open("ViyouMediaDB", 1);
                request.onsuccess = (e) => {
                    const db = e.target.result;
                    if (!db.objectStoreNames.contains("videos")) {
                        resolve(null); return;
                    }
                    const tx = db.transaction("videos", "readwrite");
                    const store = tx.objectStore("videos");
                    const getReq = store.get("exported_video");
                    getReq.onsuccess = () => {
                        // Clean up database after taking the video so it doesn't take space
                        store.delete("exported_video");
                        resolve(getReq.result);
                    };
                    getReq.onerror = () => reject(getReq.error);
                };
                request.onerror = () => reject(request.error);
            });
        }

        // Theme Toggle Logic
        const themeToggleBtn = document.getElementById('theme-toggle');
        const themeDropdown = document.getElementById('theme-dropdown');
        const body = document.body;

        function applyTheme(theme) {
            body.classList.remove('light-mode', 'cyberpunk-mode', 'matrix-mode', 'ocean-mode', 'dracula-mode', 'solar-mode');
            if (theme && theme !== 'dark') {
                body.classList.add(theme + '-mode');
            }
            localStorage.setItem('theme', theme || 'dark');
            if (window.lucide) window.lucide.createIcons();

            document.querySelectorAll('.theme-option[data-theme]').forEach(btn => {
                if (btn.getAttribute('data-theme') === (theme || 'dark')) {
                    btn.classList.add('active');
                } else {
                    btn.classList.remove('active');
                }
            });
        }

        applyTheme(localStorage.getItem('theme') || 'dark');

        themeToggleBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            themeDropdown.classList.toggle('show');
        });

        document.addEventListener('click', (e) => {
            if (!themeToggleBtn.contains(e.target) && !themeDropdown.contains(e.target)) {
                themeDropdown.classList.remove('show');
            }
        });

        document.querySelectorAll('.theme-option[data-theme]').forEach(btn => {
            btn.addEventListener('click', async (e) => {
                e.stopPropagation();
                const newTheme = btn.getAttribute('data-theme');
                applyTheme(newTheme);
                themeDropdown.classList.remove('show');

                if (auth.currentUser) {
                    try {
                        const userRef = doc(db, "users", auth.currentUser.uid);
                        await setDoc(userRef, { theme: newTheme }, { merge: true });
                    } catch (e) {
                        console.error("Error saving theme preference:", e);
                    }
                }
            });
        });

        window.switchPostType = function(type) {
            currentPostType = type;
            document.getElementById('video-upload').value = ''; // Clear video input to enforce new ratio validation
            
            document.getElementById('video-preview').style.display = 'none';
            document.getElementById('video-preview').src = '';
            const trimGroup = document.getElementById('flick-trim-group');
            if (trimGroup) trimGroup.style.display = 'none';
            
            const vidPreview = document.getElementById('video-preview');
            const thumbPreview = document.getElementById('thumbnail-preview');
            if (type === 'flick') {
                vidPreview.style.objectFit = 'cover';
                vidPreview.style.aspectRatio = '9/16';
                vidPreview.style.width = '140px';
                vidPreview.style.margin = '10px auto';
                thumbPreview.style.objectFit = 'cover';
                thumbPreview.style.aspectRatio = '9/16';
                thumbPreview.style.width = '100px';
            } else {
                vidPreview.style.objectFit = 'contain';
                vidPreview.style.aspectRatio = 'auto';
                vidPreview.style.width = '100%';
                vidPreview.style.margin = '10px 0';
                thumbPreview.style.objectFit = 'contain';
                thumbPreview.style.aspectRatio = 'auto';
                thumbPreview.style.width = 'auto';
            }
            
            document.getElementById('tab-blog').style.color = type === 'blog' ? 'white' : '#888';
            document.getElementById('tab-blog').style.borderBottomColor = type === 'blog' ? '#6366f1' : 'transparent';
            document.getElementById('tab-video').style.color = type === 'video' ? 'white' : '#888';
            document.getElementById('tab-video').style.borderBottomColor = type === 'video' ? '#6366f1' : 'transparent';
            document.getElementById('tab-flick').style.color = type === 'flick' ? 'white' : '#888';
            document.getElementById('tab-flick').style.borderBottomColor = type === 'flick' ? '#6366f1' : 'transparent';

            const blogFields = document.getElementById('blog-specific-fields');
            const videoFields = document.getElementById('video-specific-fields');
            const thumbnailGroup = document.getElementById('thumbnail-group');
            
            if (type === 'blog') {
                blogFields.style.display = 'block';
                videoFields.style.display = 'none';
                document.getElementById('content-label-text').innerText = 'सामग्री (Content)';
                document.getElementById('title').required = true;
                document.getElementById('content').required = true;
                document.getElementById('content').setAttribute('maxlength', '10000');
                document.getElementById('title').placeholder = 'Ex: भारत की शानदार जीत...';
                document.getElementById('content').placeholder = 'यहाँ अपने विचार लिखें...';
            } else if (type === 'video') {
                blogFields.style.display = 'none';
                videoFields.style.display = 'block';
                thumbnailGroup.style.display = 'block';
                document.getElementById('content-label-text').innerText = 'विवरण (Description) - Optional';
                document.getElementById('video-upload-label').innerText = `Long Video अपलोड करें (Max ${window.maxVideoUploadSizeMB}MB)`;
                document.getElementById('title').required = false;
                document.getElementById('content').required = false;
                document.getElementById('content').setAttribute('maxlength', '1000');
                document.getElementById('title').placeholder = 'Ex: My Long Video Title (Optional)';
                document.getElementById('content').placeholder = 'Description for your video... (Optional 1000 characters max)';
                document.getElementById('open-flick-cam-btn').style.display = 'none';
            } else if (type === 'flick') {
                blogFields.style.display = 'none';
                videoFields.style.display = 'block';
                thumbnailGroup.style.display = 'block';
                document.getElementById('content-label-text').innerText = 'विवरण (Description) - Optional';
                document.getElementById('video-upload-label').innerText = `Flick Video अपलोड करें (Max ${window.maxFlickUploadSizeMB}MB)`;
                document.getElementById('title').required = false;
                document.getElementById('content').required = false;
                document.getElementById('content').setAttribute('maxlength', '1000');
                document.getElementById('title').placeholder = 'Ex: My Flick Title (Optional - Max 100 characters)';
                document.getElementById('content').placeholder = 'Description for your flick... (Optional 1000 characters max)';
                document.getElementById('open-flick-cam-btn').style.display = 'block';
                
                // Auto open shorts camera if no video is selected yet
                if (!document.getElementById('video-upload').value && fsSegments.length === 0) {
                    window.openFlickCamera();
                }
            }
            updateCharCounter();
        };

        onAuthStateChanged(auth, async (user) => {
            if (user) {
                const authorInput = document.getElementById('author');
                
                // Fetch Unique ID (Username)
                const userDoc = await getDoc(doc(db, "users", user.uid));
                if (userDoc.exists() && userDoc.data().username) {
                    if (authorInput) {
                        authorInput.value = userDoc.data().username;
                        authorInput.readOnly = true; // Lock author name to Unique ID
                        updateCharCounter(); // Set initial count to (0 / 5000)
                    }
                    if (userDoc.data().isVerified) isUserVerified = true;
                } else {
                    alert("Please create a Unique ID (Username) in your profile first.");
                    window.location.href = "profile.html?requireUsername=true";
                    return;
                }

                // Fetch Max Upload Size from Settings
                try {
                    const genDoc = await getDoc(doc(db, "settings", "general"));
                    if (genDoc.exists() && genDoc.data().maxUploadSizeMB) {
                        window.maxUploadSizeMB = genDoc.data().maxUploadSizeMB;
                    }
                    if (genDoc.exists() && genDoc.data().maxVideoSizeMB) window.maxVideoUploadSizeMB = genDoc.data().maxVideoSizeMB;
                    if (genDoc.exists() && genDoc.data().maxFlickSizeMB) window.maxFlickUploadSizeMB = genDoc.data().maxFlickSizeMB;
                    if (genDoc.exists() && genDoc.data().enableYoutubeLinks === false) {
                        document.getElementById('youtube-url-group').style.display = 'none';
                    } else {
                        document.getElementById('youtube-url-group').style.display = 'block';
                    }
                } catch(e) { console.error("Error fetching general settings:", e); }
                
                // Check if we are editing an existing blog
                const urlParams = new URLSearchParams(window.location.search);
                const editId = urlParams.get('id');
                if (editId) loadBlogForEdit(editId, user);
                
                // --- Step 4: Import Rendered Video from Editor ---
                const importVideo = urlParams.get('importVideo');
                const importType = urlParams.get('type');
                const importAudio = urlParams.get('importAudio');

                if (importVideo === 'true') {
                    window.switchPostType(importType || 'video');
                    try {
                        const blob = await retrieveVideoFromIndexedDB();
                        if (blob) {
                            const file = new File([blob], "Viyou_Edited_Video.webm", { type: blob.type });
                            const dataTransfer = new DataTransfer();
                            dataTransfer.items.add(file);
                            const videoInput = document.getElementById('video-upload');
                            videoInput.files = dataTransfer.files;
                            
                            // Trigger change event to run validations if any
                            const event = new Event('change');
                            videoInput.dispatchEvent(event);
                            
                            showToast("Your edited video has been attached successfully!", "success");
                        }
                    } catch(err) {
                        console.error("Failed to retrieve imported video", err);
                        showToast("Failed to load the edited video.", "error");
                    }
                } else if (importAudio === 'true') {
                    const importUrl = localStorage.getItem('viyou_import_audio_url');
                    const importName = localStorage.getItem('viyou_import_audio_name');
                    const importId = localStorage.getItem('viyou_import_audio_id');
                    const importStart = parseFloat(localStorage.getItem('viyou_import_audio_start')) || 0;
                    
                    if (importUrl) {
                        window.switchPostType('flick');
                        
                        window.selectedFSAudioUrl = importUrl;
                        window.selectedFSAudioName = importName || "Imported Audio";
                        window.selectedFSAudioId = importId;
                        window.fsAudioTrimStart = importStart;
                        
                        const camAudioName = document.getElementById('fs-audio-name');
                        if (camAudioName) camAudioName.innerText = window.selectedFSAudioName;
                        const camTrimBtn = document.getElementById('fs-trim-btn');
                        if (camTrimBtn) camTrimBtn.style.display = 'flex';
                        
                        const editAudioPill = document.getElementById('fs-edit-audio-pill');
                        if (editAudioPill) editAudioPill.style.display = 'flex';
                        const editAudioName = document.getElementById('fs-edit-audio-name');
                        if (editAudioName) editAudioName.innerText = window.selectedFSAudioName;
                        const editTrimBtn = document.getElementById('fs-edit-trim-btn');
                        if (editTrimBtn) editTrimBtn.style.display = 'flex';

                        const aud = document.getElementById('fs-bg-audio');
                        aud.src = importUrl;
                        fsAudioAdded = true;
                        aud.currentTime = importStart;
                        fsOriginalAudioVolume = 0.2;
                        fsMusicVolume = 1;
                        document.getElementById('fs-vol-original').value = 0.2;
                        document.getElementById('fs-vol-music').value = 1;
                        window.updateFSVolumes();
                        
                        window.openFlickCamera(); // Auto open camera for them!
                        
                        localStorage.removeItem('viyou_import_audio_url');
                        localStorage.removeItem('viyou_import_audio_name');
                        localStorage.removeItem('viyou_import_audio_id');
                        localStorage.removeItem('viyou_import_audio_start');
                    }
                    window.history.replaceState({}, document.title, window.location.pathname);
                }
                // Load theme preference
                try {
                    const userDocRef = doc(db, "users", user.uid);
                    const userDocSnap = await getDoc(userDocRef);
                    let themeToApply = 'dark'; // default
                    if (userDocSnap.exists() && userDocSnap.data().theme) {
                        themeToApply = userDocSnap.data().theme;
                    } else {
                        const localTheme = localStorage.getItem('theme');
                        if (localTheme) {
                            themeToApply = localTheme;
                            await setDoc(userDocRef, { theme: themeToApply }, { merge: true });
                        }
                    }
                    applyTheme(themeToApply);
                } catch(e) {
                    console.error("Error loading theme preference:", e);
                    applyTheme(localStorage.getItem('theme') || 'dark');
                }
            } else {
                alert("You must be logged in to write a blog.");
                applyTheme(localStorage.getItem('theme') || 'dark');
                window.location.href = 'index.html';
            }
        });

        // Helper to read file as DataURL (for Video)
        function readFile(file) {
            return new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(reader.result);
                reader.onerror = reject;
                reader.readAsDataURL(file);
            });
        }

    function uploadVideoToFirebase(file) {
        return new Promise((resolve, reject) => {
            const overlay = document.getElementById('upload-progress-overlay');
            const bar = document.getElementById('upload-progress-bar');
            const text = document.getElementById('upload-progress-text');
            const cancelBtn = document.getElementById('cancel-upload-btn');
            overlay.style.display = 'flex';
            
            const safeName = file.name ? file.name.replace(/[^a-zA-Z0-9.]/g, '') : 'video.mp4';
            const storagePath = `user_videos/${auth.currentUser.uid}/${Date.now()}_${safeName}`;
            const storageRef = ref(storage, storagePath);
            const uploadTask = uploadBytesResumable(storageRef, file, { contentType: file.type || 'video/mp4' });
            
            const cancelUpload = () => {
                uploadTask.cancel();
            };
            cancelBtn.addEventListener('click', cancelUpload);
            cancelBtn.onclick = cancelUpload;

            uploadTask.on('state_changed',
                (snapshot) => {
                    const progress = (snapshot.bytesTransferred / snapshot.totalBytes) * 100;
                    bar.style.width = progress + '%';
                    
                    if (progress >= 100) {
                        text.innerText = "100%  •  Finalizing on server... Please wait.";
                    } else {
                        const mbTransferred = (snapshot.bytesTransferred / (1024 * 1024)).toFixed(1);
                        const mbTotal = (snapshot.totalBytes / (1024 * 1024)).toFixed(1);
                        text.innerText = `${Math.round(progress)}%  •  ${mbTransferred}MB / ${mbTotal}MB`;
                    }
                    cancelBtn.style.display = 'block';
                },
                (error) => {
                    overlay.style.display = 'none';
                    cancelBtn.removeEventListener('click', cancelUpload);
                    cancelBtn.onclick = null;
                    if (error.code !== 'storage/canceled') {
                        const message = error.code === 'storage/unauthorized'
                            ? 'Firebase Storage permission denied. Please sign in again or update Storage Rules for user_videos/{userId}/{fileName}.'
                            : "Upload failed: " + error.message;
                        reject(new Error(message));
                    }
                    else reject(new Error("Upload cancelled by user"));
                },
                async () => {
                    cancelBtn.removeEventListener('click', cancelUpload);
                    cancelBtn.onclick = null;
                    try {
                        const downloadURL = await getDownloadURL(uploadTask.snapshot.ref);
                        text.innerText = "Video Uploaded! Finalizing Post...";
                        resolve(downloadURL);
                    } catch (e) {
                        overlay.style.display = 'none';
                        reject(new Error("Failed to get video URL"));
                    }
                }
            );
        });
    }

        document.getElementById('thumbnail-upload').addEventListener('change', function(e) {
            const file = e.target.files[0];
            if (file) {
                const reader = new FileReader();
                reader.onload = (e) => {
                    document.getElementById('thumbnail-preview').src = e.target.result;
                    document.getElementById('thumbnail-preview').style.display = 'block';
                };
                reader.readAsDataURL(file);
            }
        });

        // --- Flicks Trimmer UI Logic ---
        document.getElementById('flick-trim-start').addEventListener('input', (e) => {
            let start = parseFloat(e.target.value);
            let end = parseFloat(document.getElementById('flick-trim-end').value);
            if (start >= end) {
                end = Math.min(videoDurationForTrim, start + 1);
                document.getElementById('flick-trim-end').value = end;
            }
            if (end - start > 30) {
                end = start + 30;
                document.getElementById('flick-trim-end').value = end;
            }
            updateTrimDisplay();
            document.getElementById('video-preview').currentTime = start;
        });

        document.getElementById('flick-trim-end').addEventListener('input', (e) => {
            let end = parseFloat(e.target.value);
            let start = parseFloat(document.getElementById('flick-trim-start').value);
            if (end <= start) {
                start = Math.max(0, end - 1);
                document.getElementById('flick-trim-start').value = start;
            }
            if (end - start > 30) {
                start = end - 30;
                document.getElementById('flick-trim-start').value = start;
            }
            updateTrimDisplay();
            document.getElementById('video-preview').currentTime = end - 1;
        });

        function updateTrimDisplay() {
            const start = parseFloat(document.getElementById('flick-trim-start').value);
            const end = parseFloat(document.getElementById('flick-trim-end').value);
            document.getElementById('trim-start-val').innerText = start.toFixed(1) + 's';
            document.getElementById('trim-end-val').innerText = end.toFixed(1) + 's';
            document.getElementById('trim-duration-display').innerText = `Selected Duration: ${(end - start).toFixed(1)}s`;
        }

        const vidPreviewEl = document.getElementById('video-preview');
        vidPreviewEl.addEventListener('timeupdate', function() {
            if (currentPostType === 'flick') {
                const end = parseFloat(document.getElementById('flick-trim-end').value) || videoDurationForTrim;
                const start = parseFloat(document.getElementById('flick-trim-start').value) || 0;
                if (vidPreviewEl.currentTime >= end || vidPreviewEl.currentTime < start) {
                    vidPreviewEl.currentTime = start;
                    vidPreviewEl.play().catch(()=>{});
                }
            }
        });

        // Aspect Ratio Validation for Video Uploads
        document.getElementById('video-upload').addEventListener('change', function(e) {
            const file = e.target.files[0];
            const preview = document.getElementById('video-preview');
            if (!file) {
                preview.style.display = 'none';
                preview.src = '';
                return;
            }

            const video = document.createElement('video');
            video.preload = 'metadata';

            video.onloadedmetadata = function() {
                const ratio = video.videoWidth / video.videoHeight;
                const duration = video.duration;
                let isValid = true;
                let expectedRatioText = "";

                if (currentPostType === 'flick') {
                    // No validation needed for flicks; it will automatically center-crop
                    // visually via CSS object-fit: cover and aspect-ratio: 9/16
                } else if (currentPostType === 'video') {
                    // Check for roughly 16:9 (1.77) or 1:1 (1.0)
                    const is16by9 = (ratio >= 1.6 && ratio <= 1.9);
                    const is1by1 = (ratio >= 0.9 && ratio <= 1.1);
                    if (!is16by9 && !is1by1) {
                        isValid = false;
                        expectedRatioText = "16:9 (Horizontal) or 1:1 (Square)";
                    }
                }

                if (!isValid) {
                    let alertMsg = `Invalid video for ${currentPostType === 'flick' ? 'Flick' : 'Long Video'}.\nExpected: ${expectedRatioText}`;
                    if (currentPostType === 'video' && !is16by9 && !is1by1) {
                         alertMsg += `\nSelected video ratio is approx: ${(ratio).toFixed(2)}:1`;
                    }
                    alert(alertMsg);
                    document.getElementById('video-upload').value = '';
                    preview.style.display = 'none';
                    preview.src = '';
                    window.URL.revokeObjectURL(video.src);
                } else {
                    preview.src = video.src;
                    preview.style.display = 'block';
                    videoDurationForTrim = duration;
                    
                    if (currentPostType === 'flick') {
                        document.getElementById('flick-trim-group').style.display = 'block';
                        const startSlider = document.getElementById('flick-trim-start');
                        const endSlider = document.getElementById('flick-trim-end');
                        startSlider.max = duration;
                        endSlider.max = duration;
                        startSlider.value = 0;
                        endSlider.value = Math.min(duration, 30);
                        updateTrimDisplay();
                        preview.currentTime = 0;
                    }
                }
            };

            video.src = URL.createObjectURL(file);
        });

        document.getElementById('add-poll-btn').addEventListener('click', () => {
            const pollCreator = document.getElementById('poll-creator');
            pollCreator.style.display = pollCreator.style.display === 'none' ? 'block' : 'none';
        });

        function updateVisibilityUI() {
            const visibility = document.getElementById('post-visibility')?.value || 'public';
            const scheduleFields = document.getElementById('schedule-fields');
            const scheduleInput = document.getElementById('schedule-date-time');
            if (scheduleFields) {
                scheduleFields.style.display = visibility === 'scheduled' ? 'block' : 'none';
            }
            if (visibility === 'scheduled' && scheduleInput && !scheduleInput.value) {
                const now = new Date(Date.now() + 60 * 60 * 1000);
                const localDateTime = new Date(now.getTime() - now.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
                scheduleInput.value = localDateTime;
            }
        }

        document.getElementById('post-visibility')?.addEventListener('change', updateVisibilityUI);

        async function loadBlogForEdit(id, user) {
            try {
                const docRef = doc(db, "blogs", id);
                const docSnap = await getDoc(docRef);
                
                if (docSnap.exists()) {
                    const blog = docSnap.data();
                    const isOwner = (blog.authorUid === user.uid) || (!blog.authorUid && blog.author === user.displayName);
                    if (!isOwner) {
                        alert("You can only edit your own blogs!");
                        window.location.href = 'index.html';
                        return;
                    }
                document.querySelector('h1').innerText = "Edit Blog";
                document.getElementById('title').value = blog.title;
                if (blog.category) document.getElementById('category').value = blog.category;
                const visibilityValue = blog.visibility || (blog.status === 'scheduled' || blog.scheduledAt ? 'scheduled' : 'public');
                const visibilitySelect = document.getElementById('post-visibility');
                if (visibilitySelect) visibilitySelect.value = visibilityValue;
                const scheduleInput = document.getElementById('schedule-date-time');
                if (scheduleInput && (blog.scheduledAt || visibilityValue === 'scheduled')) {
                    const scheduledDate = blog.scheduledAt ? new Date(blog.scheduledAt) : new Date();
                    const formatted = new Date(scheduledDate.getTime() - scheduledDate.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
                    scheduleInput.value = formatted;
                }
                updateVisibilityUI();
                document.getElementById('author').value = blog.author;
                document.getElementById('content').value = blog.content;
                document.getElementById('publish-btn').innerHTML = '<img src="publish-icon.png" alt="Publish" style="width: 20px; height: 20px; margin-right: 5px;"> Update Blog';
                updateCharCounter(); // Update counter after loading content
                
                if (blog.isFlicker) {
                    window.switchPostType('flick');
                    if (blog.thumbnail) {
                        document.getElementById('thumbnail-preview').src = blog.thumbnail;
                        document.getElementById('thumbnail-preview').style.display = 'block';
                    }
                } else if (blog.video) {
                    window.switchPostType('video');
                    if (blog.thumbnail) {
                        document.getElementById('thumbnail-preview').src = blog.thumbnail;
                        document.getElementById('thumbnail-preview').style.display = 'block';
                    }
                } else {
                    window.switchPostType('blog');
                    document.getElementById('youtube-url').value = blog.youtubeUrl || '';
                }

                // Load existing poll data for editing
                if (blog.poll) {
                    const pollCreator = document.getElementById('poll-creator');
                    pollCreator.style.display = 'block';
                    document.getElementById('poll-question').value = blog.poll.question;
                    const optionInputs = document.querySelectorAll('.poll-option');
                    blog.poll.options.forEach((opt, index) => {
                        if (optionInputs[index]) optionInputs[index].value = opt.text;
                    });
                }
                }
            } catch (error) {
                console.error("Error loading blog:", error);
            }
        }

        // Image Compression Function
        function compressImage(file) {
            return new Promise((resolve, reject) => {
                const maxWidth = 800;
                const maxHeight = 800;
                const reader = new FileReader();
                reader.readAsDataURL(file);
                reader.onload = event => {
                    const img = new Image();
                    img.src = event.target.result;
                    img.onload = () => {
                        let width = img.width;
                        let height = img.height;

                        if (width > height) {
                            if (width > maxWidth) {
                                height *= maxWidth / width;
                                width = maxWidth;
                            }
                        } else {
                            if (height > maxHeight) {
                                width *= maxHeight / height;
                                height = maxHeight;
                            }
                        }

                        const canvas = document.createElement('canvas');
                        canvas.width = width;
                        canvas.height = height;
                        const ctx = canvas.getContext('2d');
                        ctx.drawImage(img, 0, 0, width, height);
                        
                        let quality = 0.8;
                        let dataUrl = canvas.toDataURL('image/jpeg', quality);
                        while(dataUrl.length > 135000 && quality > 0.1) { // Compress to ~100KB
                            quality -= 0.1;
                            dataUrl = canvas.toDataURL('image/jpeg', quality);
                        }
                        resolve(dataUrl);
                    };
                    img.onerror = error => reject(error);
                };
                reader.onerror = error => reject(error);
            });
        }

        function compressThumbnail(file) {
            return new Promise((resolve, reject) => {
                const maxWidth = 1280;
                const maxHeight = 720;
                const reader = new FileReader();
                reader.readAsDataURL(file);
                reader.onload = event => {
                    const img = new Image();
                    img.src = event.target.result;
                    img.onload = () => {
                        let width = img.width;
                        let height = img.height;
                        if (width > height) { if (width > maxWidth) { height *= maxWidth / width; width = maxWidth; } } 
                        else { if (height > maxHeight) { width *= maxHeight / height; height = maxHeight; } }
                        const canvas = document.createElement('canvas');
                        canvas.width = width; canvas.height = height;
                        const ctx = canvas.getContext('2d');
                        ctx.drawImage(img, 0, 0, width, height);
                        
                        let quality = 0.8;
                        let dataUrl = canvas.toDataURL('image/jpeg', quality);
                        while(dataUrl.length > 115000 && quality > 0.1) { // Compress to ~100KB
                            quality -= 0.1;
                            dataUrl = canvas.toDataURL('image/jpeg', quality);
                        }
                        resolve(dataUrl);
                    };
                    img.onerror = reject;
                };
                reader.onerror = reject;
            });
        }

        let submissionStatus = 'published';
        document.getElementById('save-draft-btn').addEventListener('click', () => {
            submissionStatus = 'draft';
            document.getElementById('blogForm').requestSubmit();
        });

        document.getElementById('blogForm').addEventListener('submit', async function(e) {
            e.preventDefault();
            if (e.submitter && e.submitter.id !== 'save-draft-btn') submissionStatus = 'published';
            
            let title = document.getElementById('title').value.trim();
            const category = document.getElementById('category').value;
            const author = document.getElementById('author').value;
            let content = document.getElementById('content').value.trim();
            const imageInput = document.getElementById('image');
            const youtubeUrlInput = document.getElementById('youtube-url');
            const pollQuestion = document.getElementById('poll-question').value.trim();
            const pollOptions = Array.from(document.querySelectorAll('.poll-option'))
                                     .map(input => input.value.trim())
                                     .filter(option => option !== '');
                                     
            const allowAudioRemix = document.getElementById('allow-audio-remix') ? document.getElementById('allow-audio-remix').checked : true;
            const chosenVisibility = document.getElementById('post-visibility')?.value || 'public';
            const selectedSchedule = document.getElementById('schedule-date-time')?.value || '';
            
            const importedAudioUrl = localStorage.getItem('viyou_import_audio_url');
            const importedAudioName = localStorage.getItem('viyou_import_audio_name');
            const importedAudioId = localStorage.getItem('viyou_import_audio_id');

            if (chosenVisibility === 'scheduled' && !selectedSchedule) {
                showToast('Please select a schedule time for this post.', 'error');
                return;
            }
            if (chosenVisibility === 'scheduled') {
                const scheduledTime = new Date(selectedSchedule).getTime();
                const nowTime = Date.now();
                if (Number.isNaN(scheduledTime) || scheduledTime <= nowTime) {
                    showToast('Scheduled time should be a future date and time.', 'error');
                    return;
                }
            }

            let isFlicks = currentPostType === 'flick';
            
            // --- Abusive & Sexual Content Filter (Client-Side) ---
            let badWords = ['fuck', 'bitch', 'asshole', 'porn', 'nude', 'bastard', 'slut', 'madarchod', 'bhenchod', 'chutiya', 'bhosdike', 'randi', 'sex'];
            try {
                const modDoc = await getDoc(doc(db, "settings", "moderation"));
                if (modDoc.exists() && modDoc.data().badWords) {
                    badWords = modDoc.data().badWords;
                }
            } catch(e) { console.error("Error loading bad words filter", e); }
            
            const textToCheck = (title + " " + content + " " + pollQuestion + " " + pollOptions.join(' ')).toLowerCase();
            
            const containsAbuse = badWords.some(word => {
                const regex = new RegExp('\\b' + word + '\\b', 'i');
                return regex.test(textToCheck);
            });

            if (containsAbuse) {
                showToast("⚠️ Abusive or explicit language detected! Your content cannot be published.", 'error');
                return;
            }
            // -----------------------------------------------------

            if (currentPostType === 'video' && !title) {
                title = "Viyou " + new Date().toLocaleDateString('en-IN');
            } else if (currentPostType === 'flick' && !title) {
                title = "Viyou Flicks " + new Date().toLocaleDateString('en-IN');
            }

            if (currentPostType === 'blog' && (!title || !content)) {
                showToast("Title and Content are required for a Blog Post.", 'error');
                return;
            }
            
            if (currentPostType === 'blog' && content.length < 1200) {
                showToast("Blog content must be at least 1200 characters long.", 'error');
                return;
            }

            const urlParams = new URLSearchParams(window.location.search);
            const editId = urlParams.get('id');
            if ((currentPostType === 'video' || currentPostType === 'flick') && !editId && document.getElementById('video-upload').files.length === 0) {
                showToast("A video file is required for this post type!", 'error');
                return;
            }

            // Validation for max 5 images
            if (currentPostType === 'blog' && imageInput.files.length > 5) {
                showToast("You can only upload a maximum of 5 images.", 'error');
                return;
            }

            // Validation for max 5MB size per image (already exists)
            if (currentPostType === 'blog') {
                for (let i = 0; i < imageInput.files.length; i++) {
                    if (imageInput.files[i].size > window.maxUploadSizeMB * 1024 * 1024) {
                        showToast(`Image "${imageInput.files[i].name}" is too large. Max ${window.maxUploadSizeMB}MB allowed.`, 'error');
                        return;
                    }
                }
            }
            
            // Validation for poll
            let pollData = null;
            if (pollQuestion) {
                if (pollOptions.length < 2) {
                    showToast("A poll must have at least 2 options.", 'error');
                    return;
                }
                pollData = {
                    question: pollQuestion,
                    options: pollOptions.map(opt => ({ text: opt, votes: 0, voters: [] })),
                    totalVotes: 0
                };
            }

            if(title && author && (content !== "" || currentPostType !== 'blog')) {
                const processBlog = async (imagesData, youtubeUrl, pollData, videoBase64, thumbnailBase64) => {
                    try {
                        let videoDuration = 0;
                        let fStart = 0;
                        let fEnd = 30;
                        if (isFlicks) {
                            fStart = parseFloat(document.getElementById('flick-trim-start').value) || 0;
                            fEnd = parseFloat(document.getElementById('flick-trim-end').value) || 30;
                            videoDuration = fEnd - fStart;
                        } else {
                            const vidPreview = document.getElementById('video-preview');
                            if (vidPreview && vidPreview.src && !isNaN(vidPreview.duration) && vidPreview.duration > 0) {
                                videoDuration = vidPreview.duration;
                            } else {
                                videoDuration = videoDurationForTrim || 0;
                            }
                        }

                        // --- Smart Search: Create keywords from title and content ---
                        const allTextForKeywords = (title + " " + content).toLowerCase();
                        // Remove punctuation, split into words, filter short words, and get unique keywords
                        const keywords = [...new Set(allTextForKeywords.replace(/[.,!?;:"'()]/g, "").split(/\s+/).filter(word => word.length > 2))];
                        // --- End Smart Search ---

                        let audioId = null;
                        let authorName = author;
                        const selectedVisibility = document.getElementById('post-visibility')?.value || 'public';
                        const selectedSchedule = document.getElementById('schedule-date-time')?.value || null;
                        const normalizedStatus = submissionStatus === 'draft' ? 'draft' : (selectedVisibility === 'scheduled' ? 'scheduled' : 'published');
                        const normalizedScheduledAt = selectedVisibility === 'scheduled' && selectedSchedule ? new Date(selectedSchedule).toISOString() : null;
                        
                        let audioUrlToSave = null;
                        let audioTitleToSave = null;
                        let isOriginalAudioToSave = false;

                        if (importedAudioUrl) {
                            audioUrlToSave = importedAudioUrl;
                            audioTitleToSave = importedAudioName || "Imported Audio";
                            audioId = importedAudioId || null;
                            isOriginalAudioToSave = false;
                        } else if (videoBase64 && !youtubeUrl) {
                            audioUrlToSave = videoBase64;
                            audioTitleToSave = `${title} - @${authorName}`;
                            isOriginalAudioToSave = true;
                        }

                        if (videoBase64 && !youtubeUrl && allowAudioRemix && isOriginalAudioToSave) {
                            try {
                                const audioRef = await addDoc(collection(db, "audios"), {
                                    title: audioTitleToSave,
                                    ownerUid: auth.currentUser.uid,
                                    ownerName: authorName,
                                    audioUrl: videoBase64, // Using the proxy stream URL as base audio source
                                    coverImage: thumbnailBase64 || 'logo.png',
                                    allowRemix: allowAudioRemix,
                                    usageCount: 1,
                                    timestamp: new Date().toISOString()
                                });
                                audioId = audioRef.id;
                            } catch(err) { console.error("Failed to generate audio document", err); }
                        }

                        const mentionRegex = /@([\w_]+)/g;
                        const allText = title + " " + content;
                        const mentions = [...new Set([...allText.matchAll(mentionRegex)].map(m => m[1].toLowerCase()))];
                        
                        let mentionedUids = [];
                        let mentionMap = {};
                        if (mentions.length > 0) {
                            const q = query(collection(db, "users"), where("usernameLower", "in", mentions.slice(0, 30)));
                            const usersSnap = await getDocs(q);
                            usersSnap.forEach(docSnap => {
                                mentionedUids.push(docSnap.id);
                                mentionMap[docSnap.data().usernameLower] = docSnap.id;
                            });
                        }

                    if (editId) {
                        // Update existing blog
                            const blogRef = doc(db, "blogs", editId);
                            const updateData = {
                                title: title,
                                titleLower: title.toLowerCase(),
                                category: category,
                                content: content,
                                status: normalizedStatus,
                                visibility: selectedVisibility,
                                scheduledAt: normalizedScheduledAt,
                                mentionedUids: mentionedUids,
                                mentionMap: mentionMap,
                                keywords: keywords, // Add keywords for searching
                                allowAudioRemix: allowAudioRemix
                            };
                            updateData.authorVerified = isUserVerified;
                            updateData.isFlicker = isFlicks;
                            if (isFlicks) {
                                updateData.flickStartTime = fStart;
                                updateData.flickEndTime = fEnd;
                            }
                            if (imagesData && imagesData.length > 0) {
                                updateData.images = imagesData;
                            }
                                if (!isNaN(videoDuration) && videoDuration > 0) updateData.duration = videoDuration;
                            if (videoBase64) updateData.video = videoBase64;
                            if (thumbnailBase64) updateData.thumbnail = thumbnailBase64;
                            updateData.youtubeUrl = youtubeUrl || null;
                            updateData.poll = pollData; // Can add/update/remove poll
                            if (audioId) { updateData.audioId = audioId; }
                            if (audioUrlToSave) { updateData.audioUrl = audioUrlToSave; }
                                    if (audioTitleToSave) { updateData.audioTitle = audioTitleToSave; }
                                    if (audioId) { updateData.audioId = audioId; }
                            updateData.isOriginalAudio = isOriginalAudioToSave;
                            updateData.status = normalizedStatus;
                            await updateDoc(blogRef, updateData);
                    } else {
                        // Fetch latest user profile for author details
                        let authorPhoto = null;
                        if (auth.currentUser) {
                            try {
                                const userDoc = await getDoc(doc(db, "users", auth.currentUser.uid));
                                if (userDoc.exists()) {
                                    const userData = userDoc.data();
                                    if (userData.photoURL) authorPhoto = userData.photoURL;
                                }
                            } catch(e) {}
                        }

                        // Create new blog
                            const newBlogRef = await addDoc(collection(db, "blogs"), {
                            title: title,
                            titleLower: title.toLowerCase(),
                            category: category,
                            author: authorName,
                            authorUid: auth.currentUser ? auth.currentUser.uid : null,
                            authorPhoto: authorPhoto,
                            authorVerified: isUserVerified,
                            content: content,
                            isFlicker: isFlicks,
                            date: new Date().toISOString(),
                            images: imagesData || [],
                            image: thumbnailBase64 ? thumbnailBase64 : ((imagesData && imagesData.length > 0) ? imagesData[0] : 'logo.png'), // Default image
                            video: videoBase64 || null,
                                duration: isNaN(videoDuration) ? 0 : videoDuration,
                            flickStartTime: isFlicks ? fStart : null,
                            flickEndTime: isFlicks ? fEnd : null,
                            thumbnail: thumbnailBase64 || null,
                            youtubeUrl: youtubeUrl || null,
                            poll: pollData,
                            audioId: audioId,
                            audioUrl: audioUrlToSave,
                            audioTitle: audioTitleToSave,
                            isOriginalAudio: isOriginalAudioToSave,
                            allowAudioRemix: allowAudioRemix,
                                comments: [],
                                views: 0,
                                likes: [],
                                status: normalizedStatus,
                                visibility: selectedVisibility,
                                scheduledAt: normalizedScheduledAt,
                                mentionedUids: mentionedUids,
                                mentionMap: mentionMap,
                                keywords: keywords // Add keywords for searching
                            });

                            if (submissionStatus === 'published' && mentionedUids.length > 0) {
                                for (const uid of mentionedUids) {
                                    if (uid !== auth.currentUser.uid) {
                                        await addDoc(collection(db, "notifications"), {
                                            recipientUid: uid,
                                            senderUid: auth.currentUser.uid,
                                            senderName: authorName,
                                            type: "mention",
                                            blogId: newBlogRef.id,
                                            blogTitle: title,
                                            date: new Date().toISOString(),
                                            read: false
                                        });
                                    }
                                }
                            }
                    }
                    
                        const successMessage = submissionStatus === 'draft' ? 'Draft Saved Successfully!' : (selectedVisibility === 'scheduled' ? 'Post Scheduled Successfully!' : (editId ? 'Blog Updated Successfully!' : 'Blog Published Successfully!'));
                        showToast(successMessage, 'success');
                        
                        const overlayText = document.getElementById('upload-progress-text');
                        if (overlayText) overlayText.innerText = "Post Published Successfully! Redirecting...";

                        localStorage.removeItem('viyou_import_audio_url');
                        localStorage.removeItem('viyou_import_audio_name');
                        localStorage.removeItem('viyou_import_audio_id');

                        setTimeout(() => {
                            document.getElementById('upload-progress-overlay').style.display = 'none';
                            window.location.href = 'index.html';
                        }, 1500);

                    } catch (e) {
                        console.error("Error:", e);
                        document.getElementById('upload-progress-overlay').style.display = 'none';
                        showToast('Error saving blog: ' + e.message, 'error');
                        submitBtn.innerHTML = originalBtnContent;
                        submitBtn.disabled = false;
                    }
                };

                // Show loading state
                const submitBtn = document.getElementById(submissionStatus === 'draft' ? 'save-draft-btn' : 'publish-btn');
                const originalBtnContent = submitBtn.innerHTML;
                submitBtn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> ' + (submissionStatus === 'draft' ? 'Saving...' : 'Processing...');
                submitBtn.disabled = true;


                let imagePromises = [];
                let youtubeUrl = '';
                
                if (currentPostType === 'blog') {
                    const imageFiles = Array.from(imageInput.files);
                    youtubeUrl = youtubeUrlInput.value.trim();
                    imagePromises = imageFiles.map(file => compressImage(file));
                } else {
                    pollData = null; // Clear out poll if not a blog
                }
                
                let videoPromise = Promise.resolve(null);
                if (currentPostType === 'video' || currentPostType === 'flick') {
                    const videoInput = document.getElementById('video-upload');
                    if (videoInput && videoInput.files.length > 0) {
                        const vFile = videoInput.files[0];
                        let limitMB = currentPostType === 'flick' ? window.maxFlickUploadSizeMB : window.maxVideoUploadSizeMB;
                        if (vFile.size > limitMB * 1024 * 1024) {
                            showToast(`Video size is too large! Max ${limitMB}MB allowed for ${currentPostType === 'flick' ? 'Flicks' : 'Long Videos'}.`, 'error');
                            submitBtn.innerHTML = originalBtnContent;
                            submitBtn.disabled = false;
                            return;
                        }
                    videoPromise = uploadVideoToFirebase(vFile);
                    }
                }

                let thumbnailPromise = Promise.resolve(null);
                if ((currentPostType === 'video' || currentPostType === 'flick') && document.getElementById('thumbnail-upload').files.length > 0) {
                    thumbnailPromise = compressThumbnail(document.getElementById('thumbnail-upload').files[0]);
                }
                
                Promise.all([Promise.all(imagePromises), videoPromise, thumbnailPromise]).then(([imageResults, videoResult, thumbnailResult]) => {

                    let totalSize = JSON.stringify(imageResults).length + content.length + (videoResult ? videoResult.length : 0) + (thumbnailResult ? thumbnailResult.length : 0) + 1000;
                    if (currentPostType === 'blog' && totalSize > 1024 * 1024) {
                        showToast("Total data size is too large (Max 1MB).", 'error');
                        submitBtn.innerHTML = originalBtnContent;
                        submitBtn.disabled = false;
                        return;
                    }
                    processBlog(imageResults.length > 0 ? imageResults : null, youtubeUrl, pollData, videoResult, thumbnailResult);
                }).catch(err => {
                    console.error(err);
                    document.getElementById('upload-progress-overlay').style.display = 'none';
                    showToast("Error processing media: " + err.message, 'error');
                    submitBtn.innerHTML = originalBtnContent;
                    submitBtn.disabled = false;
                });
            }
        });

        const emojis = ['😀','😂','😍','😎','🥺','😭','😡','🔥','✨','💯','❤️','💔','🎉','👑','💸','🍕','🍔','📸','🚀','✈️'];
        const emojiList = document.getElementById('fs-emoji-list');
        if (emojiList) {
            emojis.forEach(e => {
                const span = document.createElement('span');
                span.innerText = e; span.style.cursor = 'pointer';
                span.onclick = () => { window.addFSSticker(e); document.getElementById('fs-stickers-layer').style.display='none'; };
                emojiList.appendChild(span);
            });
        }

        window.openFlickCamera = async function() {
            document.getElementById('flicks-studio-spa').style.display = 'flex';
            document.getElementById('fs-cam-view').style.display = 'block';
            document.getElementById('fs-edit-view').style.display = 'none';
            document.getElementById('fs-audio-pill').style.display = 'flex';
            
            fsTime = 0; fsChunks = [];
            fsSegments = []; fsTotalTimeMs = 0;
            document.getElementById('fs-cam-progress').style.width = '0%';
            document.getElementById('fs-cam-timer').innerText = '0.0s';
            document.getElementById('fs-next-to-edit-btn').style.display = 'none';
            document.getElementById('fs-segments-list').innerHTML = '';
            
            updateFSRecordBtnUI(false, true);
            await startFSCamera();
            if (window.lucide) window.lucide.createIcons();
        };

        window.closeFlicksStudio = function() {
            if (fsRecorder && fsRecorder.state !== 'inactive') fsRecorder.stop();
            if (fsStream) { fsStream.getTracks().forEach(t => t.stop()); fsStream = null; }
            clearInterval(fsTimerInterval);
            document.getElementById('fs-preview-video').pause();
            document.getElementById('fs-preview-video').removeAttribute('src');
            document.getElementById('fs-bg-audio').pause();
            document.getElementById('flicks-studio-spa').style.display = 'none';
            document.getElementById('fs-overlays-container').innerHTML = ''; // clear text/stickers
        };

        window.backToFSCamera = async function() {
            document.getElementById('fs-edit-view').style.display = 'none';
            document.getElementById('fs-cam-view').style.display = 'block';
            document.getElementById('fs-preview-video').pause();
            document.getElementById('fs-bg-audio').pause();
            await startFSCamera();
        };

        async function startFSCamera() {
            if (fsStream) fsStream.getTracks().forEach(t => t.stop());
            try {
                fsStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: fsFacingMode }, audio: true });
                document.getElementById('fs-camera-feed').srcObject = fsStream;
            } catch (e) { console.error(e); showToast("Camera access denied.", "error"); window.closeFlicksStudio(); }
        }

        window.switchFSCamera = function() { fsFacingMode = fsFacingMode === "environment" ? "user" : "environment"; startFSCamera(); };

        const fsRecordBtn = document.getElementById('fs-record-btn');
        if (fsRecordBtn) {
            fsRecordBtn.addEventListener('mousedown', startFSRecord); fsRecordBtn.addEventListener('touchstart', startFSRecord, {passive: true});
            window.addEventListener('mouseup', stopFSRecord); window.addEventListener('touchend', stopFSRecord);
        }

        function startFSRecord(e) {
            if (fsTotalTimeMs >= FS_MAX_TIME) return;            
            let options = { mimeType: 'video/webm; codecs=vp8,opus' };
            if (!MediaRecorder.isTypeSupported(options.mimeType)) options = { mimeType: 'video/webm' };
            if (!MediaRecorder.isTypeSupported(options.mimeType)) options = { mimeType: 'video/mp4' };
            
            fsChunks = []; fsTimeThisSegment = 0;
            fsRecorder = new MediaRecorder(fsStream, options);
            fsRecorder.ondataavailable = ev => { if (ev.data.size > 0) fsChunks.push(ev.data); };
            
            fsRecorder.onstop = () => {
                if (fsChunks.length > 0) {
                    const blob = new Blob(fsChunks, { type: fsRecorder.mimeType || 'video/webm' });
                    const url = URL.createObjectURL(blob);
                    fsSegments.push({ type: 'video', url: url, duration: fsTimeThisSegment });
                    fsTotalTimeMs += fsTimeThisSegment;
                    updateFSSegmentsUI(url, 'video');
                    updateFSRecordBtnUI(false);
                }
            };
            
            fsRecorder.start();
            if (fsAudioAdded) document.getElementById('fs-bg-audio').play().catch(e=>{});
            
            fsTimerInterval = setInterval(() => {
                fsTimeThisSegment += 100;
                let percent = ((fsTotalTimeMs + fsTimeThisSegment) / FS_MAX_TIME) * 100;
                document.getElementById('fs-cam-progress').style.width = percent + '%';
                document.getElementById('fs-cam-timer').innerText = ((fsTotalTimeMs + fsTimeThisSegment) / 1000).toFixed(1) + 's';
                if (fsTotalTimeMs + fsTimeThisSegment >= FS_MAX_TIME) {
                    stopFSRecord();
                    setTimeout(window.goToFSEditor, 200);
                }
            }, 100);
            updateFSRecordBtnUI(true);
        }

        function stopFSRecord() {
            if (fsRecorder && fsRecorder.state === 'recording') {
                fsRecorder.stop();
                clearInterval(fsTimerInterval);
                if (fsAudioAdded) document.getElementById('fs-bg-audio').pause();
            }
        }

        function updateFSRecordBtnUI(isRecording, isReset = false) {
            const inner = document.getElementById('fs-record-inner');
            const btn = document.getElementById('fs-record-btn');
            if (isRecording) {
                inner.style.borderRadius = '8px';
                inner.style.transform = 'scale(0.5)';
            btn.style.borderColor = 'rgba(255,255,255,0.4)';
            } else {
                inner.style.borderRadius = '50%';
                inner.style.transform = 'scale(1)';
                if (isReset) {
                btn.style.borderColor = 'rgba(255,255,255,0.8)';
                } else {
                btn.style.borderColor = 'rgba(255,255,255,0.8)';
                }
            }
            
            const nextBtn = document.getElementById('fs-next-to-edit-btn');
            const spacer = document.getElementById('fs-next-spacer');
            if (fsSegments.length > 0 || fsTotalTimeMs > 0) {
                nextBtn.style.display = 'flex';
                spacer.style.display = 'none';
            } else {
                nextBtn.style.display = 'none';
                spacer.style.display = 'block';
            }
        }

        document.getElementById('fs-gallery-input').addEventListener('change', (e) => {
            const file = e.target.files[0];
            if (!file) return;
            if (fsTotalTimeMs >= FS_MAX_TIME) return;
            const blobUrl = URL.createObjectURL(file);
            
            if (file.type.startsWith('video/')) {
                const vid = document.createElement('video');
                vid.src = blobUrl;
                vid.onloadedmetadata = () => {
                    let durMs = vid.duration * 1000;
                    let allowedMs = FS_MAX_TIME - fsTotalTimeMs;
                    let finalDur = Math.min(durMs, allowedMs);
                    fsSegments.push({ type: 'video', url: blobUrl, duration: finalDur });
                    fsTotalTimeMs += finalDur;
                    updateFSSegmentsUI(blobUrl, 'video');
                    document.getElementById('fs-cam-progress').style.width = (fsTotalTimeMs / FS_MAX_TIME) * 100 + '%';
                        document.getElementById('fs-cam-timer').innerText = (fsTotalTimeMs / 1000).toFixed(1) + 's';
                    document.getElementById('fs-next-to-edit-btn').style.display = 'block';
                    if (fsTotalTimeMs >= FS_MAX_TIME) window.goToFSEditor();
                };
            } else {
                let allowedMs = FS_MAX_TIME - fsTotalTimeMs;
                let finalDur = Math.min(3000, allowedMs); // Default 3s for images
                fsSegments.push({ type: 'image', url: blobUrl, duration: finalDur });
                fsTotalTimeMs += finalDur;
                updateFSSegmentsUI(blobUrl, 'image');
                document.getElementById('fs-cam-progress').style.width = (fsTotalTimeMs / FS_MAX_TIME) * 100 + '%';
                    document.getElementById('fs-cam-timer').innerText = (fsTotalTimeMs / 1000).toFixed(1) + 's';
                document.getElementById('fs-next-to-edit-btn').style.display = 'block';
                if (fsTotalTimeMs >= FS_MAX_TIME) window.goToFSEditor();
            }
            e.target.value = '';
        });

        function updateFSSegmentsUI(url, type) {
            const container = document.getElementById('fs-segments-list');
            const div = document.createElement('div');
            div.style.cssText = 'width: 35px; height: 35px; border-radius: 4px; overflow: hidden; border: 1px solid white; flex-shrink: 0; background: #222;';
            if (type === 'video') div.innerHTML = `<video src="${url}#t=0.1" style="width:100%;height:100%;object-fit:cover;"></video>`;
            else div.innerHTML = `<img src="${url}" style="width:100%;height:100%;object-fit:cover;">`;
            container.appendChild(div);
        }

        window.goToFSEditor = function() {
            document.getElementById('upload-progress-overlay').style.display = 'flex';
            document.getElementById('upload-progress-text').innerText = "Preparing...";

            if (fsRecorder && fsRecorder.state === 'recording') {
                fsRecorder.stop();
            }

            setTimeout(() => {
                if (fsSegments.length === 0) {
                    document.getElementById('upload-progress-overlay').style.display = 'none';
                    return;
                }
                
                if (fsSegments.length === 1 && fsSegments[0].type === 'video') {
                    loadMediaToFSEditor(fsSegments[0].url);
                } else {
                    document.getElementById('upload-progress-text').innerText = "Processing clips...";
                    mergeSegmentsToSingleVideo(fsSegments).then(mergedBlob => {
                        loadMediaToFSEditor(URL.createObjectURL(mergedBlob));
                    }).catch(err => {
                        console.error("Merging error:", err);
                        if (err.message !== "captureStream not supported") {
                            alert("Failed to process clips.");
                        }
                        document.getElementById('upload-progress-overlay').style.display = 'none';
                    });
                }
            }, 200); // 200ms delay to ensure chunks are properly saved before moving to next screen
        };
        
        async function mergeSegmentsToSingleVideo(segments) {
            document.getElementById('upload-progress-overlay').style.display = 'flex';
            const progressText = document.getElementById('upload-progress-text');
            const progressBar = document.getElementById('upload-progress-bar');
            
            const canvas = document.createElement('canvas');
            canvas.width = 720; canvas.height = 1280;
            
            // Mobile Safari/Chrome Background Render Workaround
            canvas.style.position = 'fixed';
            canvas.style.top = '0px';
            canvas.style.left = '0px';
            canvas.style.width = '10px';
            canvas.style.height = '10px';
            canvas.style.opacity = '0';
            canvas.style.pointerEvents = 'none';
            document.body.appendChild(canvas);
            
            if (!canvas.captureStream) {
                document.getElementById('upload-progress-overlay').style.display = 'none';
                document.body.removeChild(canvas);
                alert("Your browser does not support multi-clip merging. Please record a single continuous video or upload from gallery.");
                throw new Error("captureStream not supported");
            }
            
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = '#000';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            
            const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
            const dest = audioCtx.createMediaStreamDestination();
            
            let options = { mimeType: 'video/webm; codecs=vp8,opus' };
            if (!MediaRecorder.isTypeSupported(options.mimeType)) options = { mimeType: 'video/webm' };
            if (!MediaRecorder.isTypeSupported(options.mimeType)) options = { mimeType: 'video/mp4' };
            
            const stream = new MediaStream([...canvas.captureStream(30).getVideoTracks(), ...dest.stream.getAudioTracks()]);
            const recorder = new MediaRecorder(stream, options);
            
            const chunks = [];
            recorder.ondataavailable = e => { if (e.data.size > 0) chunks.push(e.data); };
            recorder.start();
            
            for (let i = 0; i < segments.length; i++) {
                const seg = segments[i];
                const progress = Math.round(((i + 1) / segments.length) * 100);
                progressText.innerText = `Processing clip ${i+1}/${segments.length}...`;
                progressBar.style.width = `${progress}%`;
                
                if (seg.type === 'video') {
                    await new Promise(resolve => {
                        const vid = document.createElement('video');
                        vid.src = seg.url; vid.muted = false; vid.crossOrigin = "anonymous";
                        vid.onloadedmetadata = () => {
                            if (vid.captureStream || vid.mozCaptureStream) {
                                try {
                                    const vs = vid.captureStream ? vid.captureStream() : vid.mozCaptureStream();
                                    if (vs.getAudioTracks().length > 0) { const source = audioCtx.createMediaStreamSource(vs); source.connect(dest); }
                                } catch (err) { console.warn("Failed to capture video segment stream:", err); }
                            }
                            vid.play();
                            const draw = () => {
                                if (vid.ended || vid.paused || vid.currentTime * 1000 >= seg.duration) { resolve(); return; }
                                const ratio = Math.max(canvas.width / vid.videoWidth, canvas.height / vid.videoHeight);
                                const w = vid.videoWidth * ratio; const h = vid.videoHeight * ratio;
                                ctx.fillStyle = '#000'; ctx.fillRect(0, 0, canvas.width, canvas.height);
                                ctx.drawImage(vid, (canvas.width - w)/2, (canvas.height - h)/2, w, h);
                                requestAnimationFrame(draw);
                            };
                            draw();
                        };
                    });
                } else {
                    await new Promise(resolve => {
                        const img = new Image(); img.src = seg.url; img.crossOrigin = "anonymous";
                        img.onload = () => {
                            const startTime = performance.now();
                            const draw = (now) => {
                                if (now - startTime > seg.duration) { resolve(); return; }
                                const ratio = Math.max(canvas.width / img.width, canvas.height / img.height);
                                const w = img.width * ratio; const h = img.height * ratio;
                                ctx.fillStyle = '#000'; ctx.fillRect(0, 0, canvas.width, canvas.height);
                                ctx.drawImage(img, (canvas.width - w)/2, (canvas.height - h)/2, w, h);
                                requestAnimationFrame(draw);
                            };
                            requestAnimationFrame(draw);
                        };
                    });
                }
            }
            
            recorder.stop();
            return new Promise(resolve => {
                recorder.onstop = () => {
                    if (canvas.parentNode) document.body.removeChild(canvas); // Cleanup
                    resolve(new Blob(chunks, { type: recorder.mimeType }));
                };
            });
        }

        window.toggleFSPreviewPlay = function(event) {
            if (event) event.stopPropagation();
            const vid = document.getElementById('fs-preview-video');
            const bgAudio = document.getElementById('fs-bg-audio');
            if (vid.paused) {
                vid.play().catch(e=>{});
                if (fsAudioAdded && bgAudio.paused) {
                    bgAudio.play().catch(e=>{});
                }
            } else {
                vid.pause();
                if (fsAudioAdded) bgAudio.pause();
            }
        };

        function loadMediaToFSEditor(url) {
            if (fsStream) { fsStream.getTracks().forEach(t => t.stop()); fsStream = null; }
            document.getElementById('fs-cam-view').style.display = 'none';
            document.getElementById('fs-edit-view').style.display = 'block';
            document.getElementById('fs-next-to-edit-btn').style.display = 'none';
            document.getElementById('fs-audio-pill').style.display = 'none';

            if (fsAudioAdded) {
                const editAudioPill = document.getElementById('fs-edit-audio-pill');
                if (editAudioPill) editAudioPill.style.display = 'flex';
                const editTrimBtn = document.getElementById('fs-edit-trim-btn');
                if (editTrimBtn) editTrimBtn.style.display = 'flex';
            }

            const vid = document.getElementById('fs-preview-video');
            const playPauseOverlay = document.getElementById('fs-play-pause-overlay');
            vid.src = url;
            
            vid.onloadedmetadata = () => {
                fsVideoDuration = vid.duration;
                fsTrimStart = 0;
                fsTrimEnd = Math.min(fsVideoDuration, 30);
                fsTrimStartPercent = 0;
                fsTrimEndPercent = (fsTrimEnd / fsVideoDuration) * 100;
                
                window.updateFSVolumes(); // Apply volumes
                
                generateFilmstrip(url);
                updateHandles();
                vid.play().catch(e=>{});
                
                document.getElementById('upload-progress-overlay').style.display = 'none';
            };
            
            vid.onplay = () => { if (playPauseOverlay) playPauseOverlay.style.opacity = '0'; };
            vid.onpause = () => { if (playPauseOverlay) playPauseOverlay.style.opacity = '1'; };
            
            vid.ontimeupdate = () => {
                if (window.isFSRendering) return; // Disable loop resets during actual render
                if (vid.currentTime >= fsTrimEnd || vid.currentTime < fsTrimStart) {
                    vid.currentTime = fsTrimStart;
                    vid.play().catch(e=>{});
                    if (fsAudioAdded) {
                        const aud = document.getElementById('fs-bg-audio');
                        aud.currentTime = window.fsAudioTrimStart || 0; aud.play().catch(e=>{});
                    }
                }
                // Update playhead
                const currentPercent = ((vid.currentTime) / fsVideoDuration) * 100;
                document.getElementById('fs-playhead').style.left = currentPercent + '%';
            };
        }

        async function generateFilmstrip(url) {
            const container = document.getElementById('fs-filmstrip-images');
            container.innerHTML = '';
            const tempVid = document.createElement('video');
            tempVid.src = url; tempVid.muted = true; tempVid.crossOrigin = "anonymous";
            
            const canvas = document.createElement('canvas');
            canvas.width = 100; canvas.height = 150;
            const ctx = canvas.getContext('2d');
            
            tempVid.onloadedmetadata = async () => {
                const dur = tempVid.duration;
                if (!isFinite(dur) || dur <= 0) {
                    console.error("Cannot generate filmstrip due to invalid video duration:", dur);
                    // Optionally, show a placeholder or error in the filmstrip container
                    return;
                }
                const count = 6;
                for (let i = 0; i < count; i++) {
                    await new Promise(r => {
                        tempVid.currentTime = (dur / count) * i + 0.1;
                        tempVid.onseeked = () => {
                            ctx.drawImage(tempVid, 0, 0, canvas.width, canvas.height);
                            const img = new Image(); img.src = canvas.toDataURL('image/jpeg', 0.5);
                            img.style.flex = '1'; img.style.height = '100%'; img.style.objectFit = 'cover';
                            container.appendChild(img);
                            r();
                        };
                    });
                }
            };
        }

        // Trimmer Drag Logic
        const handleL = document.getElementById('fs-handle-left');
        const handleR = document.getElementById('fs-handle-right');
        const track = document.getElementById('fs-filmstrip-track');
        let dragHandle = null; let tWidth = 0; let tLeft = 0;

        function onTStart(e, type) {
            dragHandle = type;
            const rect = track.getBoundingClientRect();
            tWidth = rect.width; tLeft = rect.left;
        }
        handleL.addEventListener('mousedown', e => onTStart(e, 'L')); handleL.addEventListener('touchstart', e => onTStart(e, 'L'), {passive: true});
        handleR.addEventListener('mousedown', e => onTStart(e, 'R')); handleR.addEventListener('touchstart', e => onTStart(e, 'R'), {passive: true});

        function onTMove(e) {
            if (!dragHandle) return;
            const cx = e.touches ? e.touches[0].clientX : e.clientX;
            let p = ((cx - tLeft) / tWidth) * 100;
            p = Math.max(0, Math.min(100, p));
            const maxP = (30 / fsVideoDuration) * 100;

            if (dragHandle === 'L') {
                if (p > fsTrimEndPercent - 2) p = fsTrimEndPercent - 2;
                if (fsTrimEndPercent - p > maxP) { fsTrimEndPercent = p + maxP; updateHandles(); }
                fsTrimStartPercent = p;
            } else {
                if (p < fsTrimStartPercent + 2) p = fsTrimStartPercent + 2;
                if (p - fsTrimStartPercent > maxP) { fsTrimStartPercent = p - maxP; updateHandles(); }
                fsTrimEndPercent = p;
            }
            updateHandles();
            const vid = document.getElementById('fs-preview-video');
            vid.currentTime = dragHandle === 'L' ? fsTrimStart : fsTrimEnd;
        }
        document.addEventListener('mousemove', onTMove); document.addEventListener('touchmove', onTMove, {passive: true});
        document.addEventListener('mouseup', () => dragHandle = null); document.addEventListener('touchend', () => dragHandle = null);

        function updateHandles() {
            fsTrimStart = (fsTrimStartPercent / 100) * fsVideoDuration;
            fsTrimEnd = (fsTrimEndPercent / 100) * fsVideoDuration;
            
            handleL.style.left = fsTrimStartPercent + '%';
            document.getElementById('fs-trim-left-overlay').style.width = fsTrimStartPercent + '%';
            
            handleR.style.left = fsTrimEndPercent + '%';
            document.getElementById('fs-trim-right-overlay').style.width = (100 - fsTrimEndPercent) + '%';
            
            document.getElementById('fs-trim-box').style.left = fsTrimStartPercent + '%';
            document.getElementById('fs-trim-box').style.width = (fsTrimEndPercent - fsTrimStartPercent) + '%';
            
            document.getElementById('fs-trim-start-lbl').innerText = fsTrimStart.toFixed(1) + 's';
            document.getElementById('fs-trim-end-lbl').innerText = fsTrimEnd.toFixed(1) + 's';
            document.getElementById('fs-trim-dur-lbl').innerText = (fsTrimEnd - fsTrimStart).toFixed(1) + 's';
        }

        // Extra Tools
        window.toggleFSFilter = function() {
            fsCurrentFilterIdx = (fsCurrentFilterIdx + 1) % fsFilters.length;
            fsProSettings.look = 'none';
            document.querySelector('[data-fs-setting="look"]').value = 'none';
            document.getElementById('fs-preview-video').style.filter = fsGetRenderFilter();
        };

        // --- Advanced Text Editor Logic ---
        let fsActiveTextState = { color: '#ffffff', font: 'font-classic', align: 'center', bgState: 0, scale: 1 }; // 0=None, 1=Translucent, 2=Inverted
        let fsActiveTextElement = null;
        let fsMentionTimer = null;

        window.addFSText = function(event) {
            if(event) event.stopPropagation();
            fsActiveTextElement = null; // Reset for new text
            fsActiveTextState.scale = 1;
            document.getElementById('fs-text-size-slider').value = 1;
            document.getElementById('fs-text-input-area').value = '';
            document.getElementById('fs-text-input-modal').style.display = 'flex';
            document.getElementById('fs-text-input-area').focus();
            applyFSTextStylesToTextarea();
        };

        window.updateFSTextSize = function(val) {
            fsActiveTextState.scale = parseFloat(val);
            applyFSTextStylesToTextarea();
        };

        window.fsCloseTextEditor = function() {
            const text = document.getElementById('fs-text-input-area').value.trim();
            if (text) {
                if (fsActiveTextElement) {
                    // Update existing element
                    fsActiveTextElement.innerText = text;
                    fsActiveTextElement.className = `fs-draggable fs-text ${fsActiveTextState.font}`;
                    fsActiveTextElement.style.textAlign = fsActiveTextState.align;
                    fsActiveTextElement.style.fontSize = `${2 * fsActiveTextState.scale}rem`;
                    fsActiveTextElement.style.transform = `translate(-50%, -50%)`;
                    fsActiveTextElement.dataset.scale = fsActiveTextState.scale;
                    
                    fsActiveTextElement.classList.remove('bg-active', 'bg-inverted');
                    if(fsActiveTextState.bgState === 1) fsActiveTextElement.classList.add('bg-active');
                    else if(fsActiveTextState.bgState === 2) {
                        fsActiveTextElement.classList.add('bg-inverted');
                        fsActiveTextElement.style.backgroundColor = fsActiveTextState.color;
                        fsActiveTextElement.style.color = (fsActiveTextState.color === '#ffffff' || fsActiveTextState.color === 'rgb(255, 255, 255)') ? '#000000' : '#ffffff';
                    } else {
                        fsActiveTextElement.style.color = fsActiveTextState.color;
                        fsActiveTextElement.style.backgroundColor = 'transparent';
                    }
                    fsApplyTextSettings(fsActiveTextElement);
                } else {
                    // Create new element
                    renderFSTextOnCanvas(text);
                }
            } else if (fsActiveTextElement) {
                fsActiveTextElement.remove(); // Delete if text is cleared
            }
            document.getElementById('fs-text-input-modal').style.display = 'none';
            document.getElementById('fs-mention-dropdown').style.display = 'none';
            fsActiveTextElement = null;
        };

        function renderFSTextOnCanvas(text) {
            const div = document.createElement('div');
            div.className = `fs-draggable fs-text ${fsActiveTextState.font}`;
            div.innerText = text;
            div.style.textAlign = fsActiveTextState.align;
            div.style.fontSize = `${2 * fsActiveTextState.scale}rem`;
            div.style.transform = `translate(-50%, -50%)`;
            div.dataset.scale = fsActiveTextState.scale;
            
            if(fsActiveTextState.bgState === 1) div.classList.add('bg-active');
            if(fsActiveTextState.bgState === 2) {
                div.classList.add('bg-inverted');
                div.style.backgroundColor = fsActiveTextState.color;
                div.style.color = (fsActiveTextState.color === '#ffffff' || fsActiveTextState.color === 'rgb(255, 255, 255)') ? '#000000' : '#ffffff';
            } else {
                div.style.color = fsActiveTextState.color;
            }
            fsApplyTextSettings(div);
            
            let hasMoved = false; let sX, sY;
            div.addEventListener('pointerdown', e => {
                e.stopPropagation();
                hasMoved = false;
                const r = div.getBoundingClientRect();
                sX = e.clientX - r.left - r.width/2;
                sY = e.clientY - r.top - r.height/2;
                div.setPointerCapture(e.pointerId);
            });
            div.addEventListener('pointermove', e => {
                if (!div.hasPointerCapture(e.pointerId)) return;
                hasMoved = true;
                div.style.left = (e.clientX - sX) + 'px';
                div.style.top = (e.clientY - sY) + 'px';
            });
            div.addEventListener('pointerup', e => {
                div.releasePointerCapture(e.pointerId);
                if (!hasMoved) {
                    e.stopPropagation();
                    editFSText(div);
                }
            });

            document.getElementById('fs-overlays-container').appendChild(div);
        }

        window.editFSText = (div) => {
            fsActiveTextElement = div;
            document.getElementById('fs-text-input-area').value = div.innerText;
            
            fsActiveTextState.color = div.style.color || '#ffffff';
            if (div.classList.contains('bg-active')) fsActiveTextState.bgState = 1;
            else if (div.classList.contains('bg-inverted')) fsActiveTextState.bgState = 2;
            else fsActiveTextState.bgState = 0;
            fsActiveTextState.font = Array.from(div.classList).find(c => c.startsWith('font-')) || 'font-classic';
            fsActiveTextState.align = div.style.textAlign || 'center';
            fsActiveTextState.scale = parseFloat(div.dataset.scale) || 1;
            document.getElementById('fs-text-size-slider').value = fsActiveTextState.scale;
            fsApplyTextSettings(div);
            
            document.getElementById('fs-text-input-modal').style.display = 'flex';
            document.getElementById('fs-text-input-area').focus();
            applyFSTextStylesToTextarea();
        };

        window.handleFSTextareaInput = (el) => {
            el.style.height = 'auto';
            el.style.height = (el.scrollHeight) + 'px';
        };

        window.fsSetTextColor = (hex) => {
            fsActiveTextState.color = hex;
            document.getElementById('fs-text-color-btn').style.color = hex;
            applyFSTextStylesToTextarea();
        };
        
        window.fsSetFont = (fontClass, btn) => {
            document.querySelectorAll('#fs-text-input-modal .font-circle').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            fsActiveTextState.font = fontClass;
            applyFSTextStylesToTextarea();
        };

        window.fsToggleTextAlign = () => {
            const alignMap = { 'center': 'left', 'left': 'right', 'right': 'center' };
            const iconMap = { 'center': 'align-center', 'left': 'align-left', 'right': 'align-right' };
            fsActiveTextState.align = alignMap[fsActiveTextState.align];
            document.getElementById('fs-text-align-btn').innerHTML = `<i data-lucide="${iconMap[fsActiveTextState.align]}"></i>`;
            lucide.createIcons();
            applyFSTextStylesToTextarea();
        };

        window.fsToggleTextBg = () => {
            fsActiveTextState.bgState = (fsActiveTextState.bgState + 1) % 3;
            applyFSTextStylesToTextarea();
        };

        window.fsToggleColorPicker = () => {
            const picker = document.getElementById('fs-color-selector');
            if (picker.style.display === 'none') {
                const colors = ['#ffffff', '#000000', '#ef4444', '#f59e0b', '#10b981', '#3b82f6', '#a855f7', '#ec4899'];
                picker.innerHTML = colors.map(c => `<div class="color-circle" style="background: ${c};" onclick="window.fsSetTextColor('${c}')"></div>`).join('');
                picker.style.display = 'flex';
            } else {
                picker.style.display = 'none';
            }
        };

        function applyFSTextStylesToTextarea() {
            const ta = document.getElementById('fs-text-input-area');
            ta.className = fsActiveTextState.font;
            ta.style.textAlign = fsActiveTextState.align;
            ta.style.fontSize = `${2.5 * fsActiveTextState.scale}rem`;
            ta.style.transform = `none`;
            ta.style.transformOrigin = 'center';
            
            if(fsActiveTextState.bgState === 0) {
                ta.style.background = 'transparent';
                ta.style.color = fsActiveTextState.color;
            } else if (fsActiveTextState.bgState === 1) {
                ta.style.background = 'rgba(0,0,0,0.7)';
                ta.style.color = fsActiveTextState.color;
            } else {
                ta.style.background = fsActiveTextState.color;
                ta.style.color = (fsActiveTextState.color === '#ffffff' || fsActiveTextState.color === 'rgb(255, 255, 255)') ? '#000000' : '#ffffff';
            }
        }

        window.addFSSticker = function(emoji) {
            const div = document.createElement('div');
            div.className = 'fs-draggable fs-sticker';
            div.innerText = emoji;
            div.style.cssText = 'position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); font-size: 80px; cursor: move; pointer-events: auto;';
            
            let hasMoved = false; let sX, sY;
            div.addEventListener('pointerdown', e => {
                e.stopPropagation();
                hasMoved = false;
                const r = div.getBoundingClientRect();
                sX = e.clientX - r.left - r.width/2;
                sY = e.clientY - r.top - r.height/2;
                div.setPointerCapture(e.pointerId);
            });
            div.addEventListener('pointermove', e => {
                if (!div.hasPointerCapture(e.pointerId)) return;
                hasMoved = true;
                div.style.left = (e.clientX - sX) + 'px';
                div.style.top = (e.clientY - sY) + 'px';
            });
            div.addEventListener('pointerup', e => {
                div.releasePointerCapture(e.pointerId);
                if (!hasMoved) e.stopPropagation();
            });

            document.getElementById('fs-overlays-container').appendChild(div);
        };

        // Audio Library
        let fsSavedAudios = [];
        let fsCurrentAudioTab = 'all';

        window.openFSAudioLibrary = async () => {
            document.getElementById('fs-audio-library').style.display = 'flex';
            const container = document.getElementById('fs-audio-list');
            container.innerHTML = '<p style="text-align:center; color:#aaa;">Loading audios...</p>';
            try {
                if (auth.currentUser) {
                    const userDoc = await getDoc(doc(db, "users", auth.currentUser.uid));
                    if (userDoc.exists()) fsSavedAudios = userDoc.data().savedAudios || [];
                }
                const q = query(collection(db, "audios"), orderBy("usageCount", "desc"), limit(30));
                const snap = await getDocs(q);
                let all = []; snap.forEach(d => all.push({id: d.id, ...d.data()}));
                window.fsAllAudios = all;
                fsCurrentAudioTab = 'all';
                document.getElementById('fs-audio-tab-all').style.background = '#6366f1';
                document.getElementById('fs-audio-tab-all').style.border = 'none';
                document.getElementById('fs-audio-tab-saved').style.background = '#222';
                document.getElementById('fs-audio-tab-saved').style.border = '1px solid #555';
                renderFSAudios(all);
            } catch(e) { console.error(e); }
        };

        window.fsSwitchAudioTab = (tab) => {
            fsCurrentAudioTab = tab;
            if (tab === 'all') {
                document.getElementById('fs-audio-tab-all').style.background = '#6366f1';
                document.getElementById('fs-audio-tab-all').style.border = 'none';
                document.getElementById('fs-audio-tab-saved').style.background = '#222';
                document.getElementById('fs-audio-tab-saved').style.border = '1px solid #555';
                window.searchFSAudio(document.getElementById('fs-audio-search').value);
            } else {
                document.getElementById('fs-audio-tab-saved').style.background = '#6366f1';
                document.getElementById('fs-audio-tab-saved').style.border = 'none';
                document.getElementById('fs-audio-tab-all').style.background = '#222';
                document.getElementById('fs-audio-tab-all').style.border = '1px solid #555';
                window.searchFSAudio(document.getElementById('fs-audio-search').value);
            }
        };

        window.searchFSAudio = (term) => {
            let list = window.fsAllAudios || [];
            if (fsCurrentAudioTab === 'saved') {
                list = list.filter(a => fsSavedAudios.includes(a.id));
            }
            if (!term) return renderFSAudios(list);
            const lower = term.toLowerCase();
            const filtered = list.filter(a => a.title.toLowerCase().includes(lower));
            renderFSAudios(filtered);
        };

        window.toggleFSAudioSave = async (audioId, event) => {
            if (event) event.stopPropagation();
            if (!auth.currentUser) {
                showToast("Please login to save audio", "error");
                return;
            }
            const isSaved = fsSavedAudios.includes(audioId);
            if (isSaved) {
                fsSavedAudios = fsSavedAudios.filter(id => id !== audioId);
            } else {
                fsSavedAudios.push(audioId);
            }
            window.searchFSAudio(document.getElementById('fs-audio-search').value); // Re-render
            try {
                const userRef = doc(db, "users", auth.currentUser.uid);
                if (isSaved) {
                    await updateDoc(userRef, { savedAudios: arrayRemove(audioId) });
                } else {
                    await updateDoc(userRef, { savedAudios: arrayUnion(audioId) });
                }
            } catch(e) { console.error("Error saving audio:", e); }
        };

        function renderFSAudios(audios) {
            const container = document.getElementById('fs-audio-list');
            container.innerHTML = '';
            if (audios.length === 0) {
                container.innerHTML = '<p style="text-align:center; color:#aaa;">No audios found.</p>';
                return;
            }
            audios.forEach(a => {
                const isSaved = fsSavedAudios.includes(a.id);
                const bookmarkIcon = isSaved ? '<i data-lucide="bookmark-minus" class="lucide-fill" style="color: #f59e0b;"></i>' : '<i data-lucide="bookmark"></i>';
                
                const div = document.createElement('div');
                div.style.cssText = "display: flex; align-items: center; justify-content: space-between; padding: 12px 10px; border-bottom: 1px solid #333; cursor: pointer; transition: background 0.2s;";
                div.onmouseover = () => div.style.background = 'rgba(255,255,255,0.05)';
                div.onmouseout = () => div.style.background = 'transparent';
                
                const cover = a.coverImage || 'logo.png';
                const creator = a.ownerName || 'Creator';
                const uses = a.usageCount ? (a.usageCount > 1000 ? (a.usageCount/1000).toFixed(1)+'k' : a.usageCount) + ' uses' : 'New';

                div.innerHTML = `
                    <div style="display: flex; align-items: center; gap: 15px; flex: 1; overflow: hidden;" onclick="window.previewFSAudio('${a.audioUrl}', this)">
                        <div style="position: relative; width: 50px; height: 50px; border-radius: 8px; overflow: hidden; flex-shrink: 0; background: #333;">
                            <img src="${cover}" style="width: 100%; height: 100%; object-fit: cover;">
                            <div class="play-overlay" style="position: absolute; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.4); display:flex; align-items:center; justify-content:center;"><i data-lucide="play" style="color: white; width: 20px; height: 20px; fill: white;"></i></div>
                        </div>
                        <div style="flex: 1; overflow: hidden;">
                            <div style="color: white; font-weight: bold; font-size: 1rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">${a.title}</div>
                            <div style="color: #aaa; font-size: 0.85rem; display: flex; gap: 8px; align-items: center;">
                                <span>${creator}</span>
                                <span style="font-size: 0.5rem;">•</span>
                                <span>${uses}</span>
                            </div>
                        </div>
                    </div>
                    <button onclick="window.toggleFSAudioSave('${a.id}', event)" style="background: transparent; border: none; color: white; cursor: pointer; padding: 5px; margin-left: 5px;">${bookmarkIcon}</button>
                    <button onclick="window.selectFSAudio('${a.audioUrl}', '${a.title.replace(/'/g, "\\'")}')" style="background: white; color: black; border: none; padding: 6px 16px; border-radius: 20px; font-weight: bold; cursor: pointer; margin-left: 10px; font-size: 0.85rem;">Use</button>
                `;
                container.appendChild(div);
            });
            if(window.lucide) window.lucide.createIcons();
        }

    window.fsCurrentlyPlayingAudio = null;
        window.previewFSAudio = (url, elem) => {
            const player = document.getElementById('fs-audio-preview-player');
            const overlay = elem.querySelector('.play-overlay');

        player.onended = () => {
            overlay.innerHTML = '<i data-lucide="play" style="color: white; width: 20px; height: 20px; fill: white;"></i>';
            if (window.lucide) window.lucide.createIcons({ root: overlay });
            window.fsCurrentlyPlayingAudio = null;
        };

        if (window.fsCurrentlyPlayingAudio === url && !player.paused) {
                player.pause();
                overlay.innerHTML = '<i data-lucide="play" style="color: white; width: 20px; height: 20px; fill: white;"></i>';
            } else {
                document.querySelectorAll('.play-overlay').forEach(o => o.innerHTML = '<i data-lucide="play" style="color: white; width: 20px; height: 20px; fill: white;"></i>');
                overlay.innerHTML = '<i data-lucide="pause" style="color: white; width: 20px; height: 20px; fill: white;"></i>';
                player.src = url;
                player.play().catch(e => console.error(e));
            window.fsCurrentlyPlayingAudio = url;
            }
            if(window.lucide) window.lucide.createIcons();
        };
        window.selectFSAudio = (url, title, id, start = 0) => {
           const camAudioName = document.getElementById('fs-audio-name');
            if (camAudioName) camAudioName.innerText = title;
            const camTrimBtn = document.getElementById('fs-trim-btn');
            if (camTrimBtn) camTrimBtn.style.display = 'flex';
            
            const editAudioPill = document.getElementById('fs-edit-audio-pill');
            if (editAudioPill) editAudioPill.style.display = 'flex';
            const editAudioName = document.getElementById('fs-edit-audio-name');
            if (editAudioName) editAudioName.innerText = title;
            const editTrimBtn = document.getElementById('fs-edit-trim-btn');
            if (editTrimBtn) editTrimBtn.style.display = 'flex';

            const aud = document.getElementById('fs-bg-audio');
            aud.src = url;
            fsAudioAdded = true;
            window.selectedFSAudioUrl = url;
            window.selectedFSAudioName = title;
            window.selectedFSAudioId = id;
            window.fsAudioTrimStart = start;
            aud.currentTime = start;
            fsOriginalAudioVolume = 0.2; // default dip original
            fsMusicVolume = 1;
            document.getElementById('fs-vol-original').value = 0.2;
            document.getElementById('fs-vol-music').value = 1;
            window.updateFSVolumes();
            document.getElementById('fs-audio-library').style.display = 'none';
        };
        
        window.updateFSVolumes = function() {
            fsOriginalAudioVolume = parseFloat(document.getElementById('fs-vol-original').value);
            fsMusicVolume = parseFloat(document.getElementById('fs-vol-music').value);
            document.getElementById('fs-preview-video').volume = fsOriginalAudioVolume;
            document.getElementById('fs-bg-audio').volume = fsMusicVolume;
            if (fsAudioAdded && document.getElementById('fs-bg-audio').paused) document.getElementById('fs-bg-audio').play().catch(e=>{});
        };

        // Rendering the final Video
        window.fsRenderVideo = async function() {
            window.isFSRendering = true;
            const overlay = document.getElementById('upload-progress-overlay');
            const progressText = document.getElementById('upload-progress-text');
            const progressBar = document.getElementById('upload-progress-bar');
            const cancelBtn = document.getElementById('cancel-upload-btn');
            
            overlay.style.display = 'flex';
            progressText.innerText = "Rendering Video...";
            progressBar.style.width = '0%';
            
            let isCancelled = false;
            let recorder = null;
            const cancelRender = () => {
                isCancelled = true;
                window.isFSRendering = false;
                if (recorder && recorder.state !== 'inactive') recorder.stop();
                const tempCanvas = document.getElementById('fs-temp-render-canvas');
                if (tempCanvas) tempCanvas.remove(); // Cleanup on cancel
                overlay.style.display = 'none';
                cancelBtn.removeEventListener('click', cancelRender);
                cancelBtn.onclick = null;
            };
            cancelBtn.addEventListener('click', cancelRender);
            cancelBtn.onclick = cancelRender;
            
            const video = document.getElementById('fs-preview-video');
            const audio = document.getElementById('fs-bg-audio');
            const canvas = document.createElement('canvas');
            canvas.id = 'fs-temp-render-canvas';
            canvas.width = 720;
            canvas.height = 1280;
            
            // Mobile Safari/Chrome Background Render Workaround
            canvas.style.position = 'fixed';
            canvas.style.top = '0px';
            canvas.style.left = '0px';
            canvas.style.width = '10px';
            canvas.style.height = '10px';
            canvas.style.opacity = '0';
            canvas.style.pointerEvents = 'none';
            document.body.appendChild(canvas);
            
            if (!canvas.captureStream) {
                alert("Your browser does not support Advanced Video Rendering. Try using a PC or Android device.");
                cancelRender();
                return;
            }
            
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = '#000';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            
            const audioCtx = new (window.AudioContext || window.webkitAudioContext)();
            const dest = audioCtx.createMediaStreamDestination();
            
            if (video.captureStream || video.mozCaptureStream) {
                try {
                    const vs = video.captureStream ? video.captureStream() : video.mozCaptureStream();
                    if (vs.getAudioTracks().length > 0) {
                        const src1 = audioCtx.createMediaStreamSource(vs);
                        const gain1 = audioCtx.createGain();
                        gain1.gain.value = fsOriginalAudioVolume;
                        src1.connect(gain1).connect(dest);
                    }
                } catch (err) { console.warn("Failed to capture video stream:", err); }
            }
            
            if (fsAudioAdded && (audio.captureStream || audio.mozCaptureStream)) {
                try {
                    const as = audio.captureStream ? audio.captureStream() : audio.mozCaptureStream();
                    if (as.getAudioTracks().length > 0) {
                        const src2 = audioCtx.createMediaStreamSource(as);
                        const gain2 = audioCtx.createGain();
                        gain2.gain.value = fsMusicVolume;
                        src2.connect(gain2).connect(dest);
                    }
                } catch (err) { console.warn("Failed to capture audio stream:", err); }
            }
            
            let options = { mimeType: 'video/webm; codecs=vp8,opus' };
            if (!MediaRecorder.isTypeSupported(options.mimeType)) options = { mimeType: 'video/webm' };
            if (!MediaRecorder.isTypeSupported(options.mimeType)) options = { mimeType: 'video/mp4' };

            const stream = new MediaStream([...canvas.captureStream(Number(fsProSettings.fps) || 30).getVideoTracks(), ...dest.stream.getAudioTracks()]);
            recorder = new MediaRecorder(stream, options);
            const chunks = [];
            recorder.ondataavailable = e => { if (e.data.size > 0) chunks.push(e.data); };
            
            video.currentTime = fsTrimStart;
            if (fsAudioAdded) { audio.currentTime = window.fsAudioTrimStart || 0; audio.play().catch(e=>{}); }
            try {
                await video.play();
            } catch (e) {
                if (e.name !== 'AbortError') console.error("Error playing video for render:", e);
            }
            
            recorder.start();
            
            const renderLoop = () => {
                if (isCancelled || video.currentTime >= fsTrimEnd || video.ended) {
                    recorder.stop();
                    video.pause();
                    if (fsAudioAdded) audio.pause();
                    window.isFSRendering = false;
                    return;
                }

                if (fsAudioAdded) {
                    const startA = window.fsAudioTrimStart || 0;
                    if (audio.currentTime >= startA + 30 || audio.ended) {
                        audio.currentTime = startA;
                        audio.play().catch(e=>{});
                    }
                }
                
                ctx.filter = fsGetRenderFilter() || 'none';
                const ratio = Math.max(canvas.width / video.videoWidth, canvas.height / video.videoHeight);
                const w = video.videoWidth * ratio; const h = video.videoHeight * ratio;
                if (fsProSettings.fit === 'blur') {
                    ctx.filter = 'blur(24px) brightness(0.55)';
                    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
                    ctx.filter = fsGetRenderFilter() || 'none';
                }
                ctx.save();
                if (fsProSettings.mirror === 'on') { ctx.translate(canvas.width, 0); ctx.scale(-1, 1); }
                ctx.drawImage(video, (canvas.width - w)/2, (canvas.height - h)/2, w, h);
                ctx.restore();
                ctx.filter = 'none';

                if (Number(fsProSettings.vignette) > 0) {
                    const vignette = ctx.createRadialGradient(canvas.width / 2, canvas.height / 2, canvas.height * 0.22, canvas.width / 2, canvas.height / 2, canvas.height * 0.8);
                    vignette.addColorStop(0, 'rgba(0,0,0,0)');
                    vignette.addColorStop(1, `rgba(0,0,0,${Number(fsProSettings.vignette)})`);
                    ctx.fillStyle = vignette; ctx.fillRect(0, 0, canvas.width, canvas.height);
                }
                if (Number(fsProSettings.grain) > 0) {
                    ctx.fillStyle = `rgba(255,255,255,${Number(fsProSettings.grain)})`;
                    for (let grain = 0; grain < 260; grain++) ctx.fillRect(Math.random() * canvas.width, Math.random() * canvas.height, 1, 1);
                }
                
                const container = document.getElementById('fs-overlays-container');
                const scaleX = canvas.width / container.offsetWidth;
                const scaleY = canvas.height / container.offsetHeight;
                
                document.querySelectorAll('.fs-draggable').forEach(el => {
                    const rect = el.getBoundingClientRect(); const contRect = container.getBoundingClientRect();
                    const cx = rect.left + rect.width/2 - contRect.left; const cy = rect.top + rect.height/2 - contRect.top;
                    const exportX = cx * scaleX; const exportY = cy * scaleY;
                    
                    if (el.classList.contains('fs-text')) {
                        const elScale = parseFloat(el.dataset.scale) || 1;
                        const computed = window.getComputedStyle(el);
                        const fontSize = (parseFloat(computed.fontSize) || 30) * elScale;
                        const animationProgress = (video.currentTime - fsTrimStart) / Math.max(0.01, fsTrimEnd - fsTrimStart);
                        if (fsProSettings.textAnimation === 'blink' && Math.floor(animationProgress * 12) % 2 === 1) return;
                        const animationScale = fsProSettings.textAnimation === 'pop' ? Math.min(1, animationProgress * 8) : 1;
                        const animationY = fsProSettings.textAnimation === 'rise' ? (1 - Math.min(1, animationProgress * 5)) * 45 : 0;
                        ctx.save(); ctx.translate(exportX, exportY - animationY); ctx.scale(animationScale, animationScale);
                        ctx.font = `${computed.fontStyle} ${computed.fontWeight} ${fontSize * scaleX}px ${computed.fontFamily}`;
                        ctx.textAlign = computed.textAlign || 'center'; ctx.textBaseline = 'middle'; ctx.fillStyle = computed.color || fsProSettings.textColor;
                        ctx.shadowColor = fsProSettings.textStyle === 'glow' ? fsProSettings.textColor : 'rgba(0,0,0,0.8)';
                        ctx.shadowBlur = fsProSettings.textStyle === 'glow' ? 18 : 4;
                        
                        const lines = el.innerText.split('\n');
                        const lineHeight = fontSize * 1.2 * scaleX;
                        const totalHeight = lines.length * lineHeight;
                        const startY = exportY - totalHeight / 2 + lineHeight / 2;
                        
                        lines.forEach((line, i) => { ctx.fillText(fsProSettings.textStyle === 'uppercase' ? line.toUpperCase() : line, 0, startY - exportY + i * lineHeight); });
                        ctx.restore();
                    } else if (el.classList.contains('fs-sticker')) {
                        const elScale = parseFloat(el.dataset.scale) || 1;
                        const fontSize = (parseFloat(window.getComputedStyle(el).fontSize) || 80) * elScale;
                        ctx.font = `${fontSize * scaleX}px sans-serif`;
                        ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
                        ctx.fillText(el.innerText, exportX, exportY);
                    }
                });
                
                const progress = Math.round(((video.currentTime - fsTrimStart) / (fsTrimEnd - fsTrimStart)) * 100);
                progressText.innerText = `Rendering: ${progress}%`;
                progressBar.style.width = `${progress}%`;

                requestAnimationFrame(renderLoop);
            };
            
            requestAnimationFrame(renderLoop);
            
            recorder.onstop = () => {
                cancelBtn.removeEventListener('click', cancelRender);
                cancelBtn.onclick = null;
                window.isFSRendering = false;
                if (canvas.parentNode) document.body.removeChild(canvas); // Cleanup on success
                if (isCancelled) return;

                // This function is called when rendering is complete.
                // Instead of just hiding the overlay, we'll update it to show completion
                // and give the user a button to close it. This prevents race conditions.
                const overlay = document.getElementById('upload-progress-overlay');
                const text = document.getElementById('upload-progress-text');
                const bar = document.getElementById('upload-progress-bar');
                const h2 = overlay.querySelector('h2');
                const actionBtn = document.getElementById('cancel-upload-btn');

                const blob = new Blob(chunks, { type: recorder.mimeType || 'video/webm' });
                let ext = 'webm';
                if (blob.type.includes('mp4')) ext = 'mp4';
                const file = new File([blob], `flick_rendered.${ext}`, { type: blob.type });
                const dt = new DataTransfer(); dt.items.add(file);
                document.getElementById('video-upload').files = dt.files;
                document.getElementById('video-upload').dispatchEvent(new Event('change'));
                
                if (fsAudioAdded && window.selectedFSAudioUrl) {
                    localStorage.setItem('viyou_import_audio_url', window.selectedFSAudioUrl);
                    localStorage.setItem('viyou_import_audio_name', window.selectedFSAudioName);
                    if (window.selectedFSAudioId) localStorage.setItem('viyou_import_audio_id', window.selectedFSAudioId);
                }
            
                window.closeFlicksStudio();
                
                if (h2) h2.innerText = "Processing Complete!";
                if (bar) bar.style.width = '100%';
                if (text) text.innerText = "Your video is ready.";
                if (actionBtn) actionBtn.style.display = 'none';

                setTimeout(() => {
                    overlay.style.display = 'none';
                    if (h2) h2.innerText = "Uploading Video...";
                    if (actionBtn) actionBtn.style.display = 'block';
                }, 1500);
        };
    };

        // --- Phase 2: Audio Trimmer Drag & Loop Engine (Flicks Studio) ---
        let fsAudioTrimAudio = new Audio();
        let fsAudioTrimDragging = false;
        let fsAudioTrimDuration = 30; // Max 30s
        let fsAudioTotalTime = 0;
        let fsAudioTrimInterval = null;

        function formatFSTrimTime(seconds) {
            if (isNaN(seconds) || !isFinite(seconds)) return "0:00";
            const m = Math.floor(seconds / 60);
            const s = Math.floor(seconds % 60);
            return `${m}:${s < 10 ? '0' : ''}${s}`;
        }

        window.openFSAudioTrimmer = () => {
            if (!window.selectedFSAudioUrl) return;
            
            document.getElementById('fs-audio-trimmer-sheet').style.display = 'flex';
            setTimeout(() => document.getElementById('fs-trimmer-sheet-content').style.transform = 'translateY(0)', 10);
            
            const bars = document.getElementById('fs-audio-waveform-bars');
            bars.innerHTML = '';
            for(let i=0; i<40; i++) {
                const h = Math.floor(Math.random() * 70) + 20;
                bars.innerHTML += `<div style="flex:1; height:${h}%; background:#888; border-radius:2px;"></div>`;
            }

            fsAudioTrimAudio.src = window.selectedFSAudioUrl;
            fsAudioTrimAudio.onloadedmetadata = () => {
                fsAudioTotalTime = fsAudioTrimAudio.duration;
                if(fsAudioTotalTime < fsAudioTrimDuration) fsAudioTrimDuration = fsAudioTotalTime;
                
                let boxWidth = (fsAudioTrimDuration / fsAudioTotalTime) * 100;
                document.getElementById('fs-audio-trimmer-selection-box').style.width = boxWidth + '%';
                
                let leftPercent = (window.fsAudioTrimStart / fsAudioTotalTime) * 100;
                document.getElementById('fs-audio-trimmer-selection-box').style.left = leftPercent + '%';
                
                updateFSAudioTrimDisplay();
                playFSAudioTrimAudio();
            };
        };

        const fsAudioTrimBox = document.getElementById('fs-audio-trimmer-selection-box');
        const fsAudioWaveform = document.getElementById('fs-audio-waveform-container');
        let fsAudioStartX = 0, fsAudioStartLeft = 0;

        const onFSAudioTrimDragStart = (e) => {
            fsAudioTrimDragging = true;
            fsAudioStartX = e.touches ? e.touches[0].clientX : e.clientX;
            fsAudioStartLeft = parseFloat(fsAudioTrimBox.style.left) || 0;
            fsAudioTrimAudio.pause();
        };

        const onFSAudioTrimDragMove = (e) => {
            if(!fsAudioTrimDragging) return;
            e.preventDefault();
            let currentX = e.touches ? e.touches[0].clientX : e.clientX;
            let deltaPercent = ((currentX - fsAudioStartX) / fsAudioWaveform.offsetWidth) * 100;
            let newLeft = Math.max(0, Math.min(100 - parseFloat(fsAudioTrimBox.style.width), fsAudioStartLeft + deltaPercent));
            
            fsAudioTrimBox.style.left = newLeft + '%';
            window.fsAudioTrimStart = (newLeft / 100) * fsAudioTotalTime;
            updateFSAudioTrimDisplay();
        };

        const onFSAudioTrimDragEnd = () => {
            if(!fsAudioTrimDragging) return;
            fsAudioTrimDragging = false;
            if(navigator.vibrate) navigator.vibrate(10);
            playFSAudioTrimAudio();
        };

        fsAudioTrimBox.addEventListener('mousedown', onFSAudioTrimDragStart);
        document.addEventListener('mousemove', onFSAudioTrimDragMove, {passive: false});
        document.addEventListener('mouseup', onFSAudioTrimDragEnd);
        fsAudioTrimBox.addEventListener('touchstart', onFSAudioTrimDragStart, {passive:false});
        document.addEventListener('touchmove', onFSAudioTrimDragMove, {passive:false});
        document.addEventListener('touchend', onFSAudioTrimDragEnd);

        const updateFSAudioTrimDisplay = () => {
            let end = Math.min(window.fsAudioTrimStart + fsAudioTrimDuration, fsAudioTotalTime);
            document.getElementById('fs-trimmer-time-display').innerHTML = `${formatFSTrimTime(window.fsAudioTrimStart)} <span style="color: #fff; margin: 0 5px;">-</span> ${formatFSTrimTime(end)}`;
        };

        const playFSAudioTrimAudio = () => {
            fsAudioTrimAudio.currentTime = window.fsAudioTrimStart;
            fsAudioTrimAudio.play().catch(e=>{});
            clearInterval(fsAudioTrimInterval);
            fsAudioTrimInterval = setInterval(() => {
                if(fsAudioTrimAudio.currentTime >= window.fsAudioTrimStart + fsAudioTrimDuration) {
                    fsAudioTrimAudio.currentTime = window.fsAudioTrimStart;
                    fsAudioTrimAudio.play().catch(e=>{});
                }
            }, 100);
        };

        window.closeFSAudioTrimmer = () => {
            document.getElementById('fs-trimmer-sheet-content').style.transform = 'translateY(100%)';
            setTimeout(() => document.getElementById('fs-audio-trimmer-sheet').style.display = 'none', 300);
            
            fsAudioTrimAudio.pause();
            clearInterval(fsAudioTrimInterval);
            
            const bgAudio = document.getElementById('fs-bg-audio');
            if(bgAudio && fsAudioAdded) {
                bgAudio.currentTime = window.fsAudioTrimStart;
                const vid = document.getElementById('fs-preview-video');
                if (vid && !vid.paused && document.getElementById('fs-edit-view').style.display !== 'none') {
                    bgAudio.play().catch(e=>{});
                }
            }
        };
        
    