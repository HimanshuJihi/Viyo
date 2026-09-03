import { addDoc, collection, doc, getDoc, getDocs, query, updateDoc, where } from "https://www.gstatic.com/firebasejs/10.8.0/firebase-firestore.js";
import { db, auth } from "./firebase-config.js";

let activeContent = null;
let cachedPlaylists = [];

function contentUrl(type, id) {
    if (type === 'flick') return `flicks.html?id=${id}`;
    if (type === 'blog') return `index.html?view=blog&id=${id}`;
    return `watch.html?id=${id}`;
}

function getCover(content) {
    return content.thumbnail || content.image || (Array.isArray(content.images) ? content.images[0] : '') || '';
}

function ensureModal() {
    let modal = document.getElementById('playlist-action-modal');
    if (modal) return modal;

    modal = document.createElement('div');
    modal.id = 'playlist-action-modal';
    modal.style.cssText = 'display:none; position:fixed; inset:0; z-index:99999; background:rgba(0,0,0,.82); padding:18px; box-sizing:border-box; align-items:center; justify-content:center;';
    modal.innerHTML = `
        <div style="width:min(92vw,480px); max-height:78vh; overflow:hidden; display:flex; flex-direction:column; background:#111827; color:#fff; border:1px solid rgba(255,255,255,.12); border-radius:16px; padding:18px; box-shadow:0 25px 80px rgba(0,0,0,.5);">
            <div style="display:flex; justify-content:space-between; align-items:center; gap:12px; margin-bottom:12px;"><h3 style="margin:0; color:#f59e0b;">Save to playlist</h3><button type="button" data-close style="background:none; border:none; color:#fff; font-size:1.65rem; cursor:pointer;">&times;</button></div>
            <p id="playlist-action-content-title" style="margin:0 0 12px; color:#cbd5e1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;"></p>
            <input id="playlist-action-search" type="search" placeholder="Search your playlists" style="padding:11px; border-radius:10px; border:1px solid rgba(255,255,255,.14); background:rgba(255,255,255,.05); color:#fff; outline:none;">
            <div id="playlist-action-list" style="display:flex; flex-direction:column; gap:8px; overflow-y:auto; margin:12px 0; min-height:54px;"></div>
            <button id="playlist-action-new-toggle" type="button" style="border:1px solid rgba(129,140,248,.6); border-radius:10px; padding:10px; color:#e0e7ff; background:rgba(99,102,241,.16); font-weight:bold; cursor:pointer;">+ New playlist</button>
            <div id="playlist-action-new-form" style="display:none; gap:8px; margin-top:10px;"><input id="playlist-action-new-name" maxlength="50" placeholder="Playlist name" style="padding:11px; border-radius:10px; border:1px solid rgba(255,255,255,.14); background:rgba(255,255,255,.05); color:#fff;"><button id="playlist-action-create" type="button" style="border:none; border-radius:10px; padding:10px; color:#fff; background:#6366f1; font-weight:bold; cursor:pointer;">Create & add</button></div>
        </div>`;
    modal.addEventListener('click', event => { if (event.target === modal) modal.style.display = 'none'; });
    modal.querySelector('[data-close]').onclick = () => { modal.style.display = 'none'; };
    modal.querySelector('#playlist-action-search').oninput = event => renderPlaylists(event.target.value);
    modal.querySelector('#playlist-action-new-toggle').onclick = () => {
        const form = modal.querySelector('#playlist-action-new-form');
        form.style.display = form.style.display === 'flex' ? 'none' : 'flex';
        if (form.style.display === 'flex') modal.querySelector('#playlist-action-new-name').focus();
    };
    modal.querySelector('#playlist-action-create').onclick = createPlaylistAndSave;
    document.body.appendChild(modal);
    return modal;
}

function playlistItem() {
    return {
        id: activeContent.id,
        contentId: activeContent.id,
        type: activeContent.type,
        title: activeContent.title || 'Untitled content',
        image: getCover(activeContent),
        url: contentUrl(activeContent.type, activeContent.id),
        addedAt: new Date().toISOString()
    };
}

async function saveToPlaylist(playlist) {
    const item = playlistItem();
    const items = Array.isArray(playlist.items) ? playlist.items : [];
    if (items.some(saved => (saved.contentId || saved.id) === item.contentId)) {
        alert('This content is already in the playlist.');
        return;
    }
    const update = { items: [...items, item] };
    if (!playlist.coverImage && item.image) update.coverImage = item.image;
    await updateDoc(doc(db, 'playlists', playlist.id), update);
    document.getElementById('playlist-action-modal').style.display = 'none';
    alert('Added to playlist.');
}

function renderPlaylists(search = '') {
    const list = document.getElementById('playlist-action-list');
    if (!list) return;
    const needle = search.trim().toLowerCase();
    const playlists = cachedPlaylists.filter(playlist => !needle || `${playlist.name || ''} ${playlist.description || ''}`.toLowerCase().includes(needle));
    list.innerHTML = '';
    if (!playlists.length) {
        list.innerHTML = '<p style="margin:6px 0; color:#9ca3af;">No matching playlists.</p>';
        return;
    }
    playlists.forEach(playlist => {
        const button = document.createElement('button');
        const count = Array.isArray(playlist.items) ? playlist.items.length : 0;
        button.type = 'button';
        button.style.cssText = 'display:flex; justify-content:space-between; align-items:center; gap:10px; width:100%; padding:11px; text-align:left; border:1px solid rgba(255,255,255,.1); border-radius:10px; color:#fff; background:rgba(255,255,255,.05); cursor:pointer;';
        button.innerHTML = `<span style="min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;"></span><span style="color:#a5b4fc; font-size:.8rem; white-space:nowrap;">Add</span>`;
        button.firstElementChild.textContent = `${playlist.name || 'Untitled playlist'} · ${count} item${count === 1 ? '' : 's'}`;
        button.onclick = () => saveToPlaylist(playlist).catch(error => { console.error(error); alert('Unable to add this content right now.'); });
        list.appendChild(button);
    });
}

async function createPlaylistAndSave() {
    const nameInput = document.getElementById('playlist-action-new-name');
    const name = nameInput.value.trim();
    if (!name || !auth.currentUser || !activeContent) return;
    const item = playlistItem();
    const playlist = {
        authorUid: auth.currentUser.uid,
        authorName: auth.currentUser.displayName || 'User',
        name,
        description: '',
        visibility: 'public',
        createdAt: new Date().toISOString(),
        items: [item],
        coverImage: item.image || ''
    };
    await addDoc(collection(db, 'playlists'), playlist);
    document.getElementById('playlist-action-modal').style.display = 'none';
    alert('Playlist created and content added.');
}

window.openPlaylistSaveForContent = async function(type, contentId) {
    if (!auth.currentUser) {
        alert('Please login to save content to a playlist.');
        return;
    }
    const contentSnap = await getDoc(doc(db, 'blogs', contentId));
    if (!contentSnap.exists()) return;
    activeContent = { id: contentSnap.id, type, ...contentSnap.data() };
    const modal = ensureModal();
    document.getElementById('playlist-action-content-title').textContent = activeContent.title || 'Untitled content';
    document.getElementById('playlist-action-search').value = '';
    document.getElementById('playlist-action-new-form').style.display = 'none';
    document.getElementById('playlist-action-new-name').value = '';
    document.getElementById('playlist-action-list').innerHTML = '<p style="margin:6px 0; color:#9ca3af;">Loading playlists...</p>';
    modal.style.display = 'flex';
    try {
        const snapshot = await getDocs(query(collection(db, 'playlists'), where('authorUid', '==', auth.currentUser.uid)));
        cachedPlaylists = [];
        snapshot.forEach(playlistDoc => cachedPlaylists.push({ id: playlistDoc.id, ...playlistDoc.data() }));
        cachedPlaylists.sort((a, b) => new Date(b.createdAt || 0) - new Date(a.createdAt || 0));
        renderPlaylists();
    } catch (error) {
        console.error('Unable to load playlists:', error);
        document.getElementById('playlist-action-list').innerHTML = '<p style="margin:6px 0; color:#fca5a5;">Unable to load playlists.</p>';
    }
};
