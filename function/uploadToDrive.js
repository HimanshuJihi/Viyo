require('dotenv').config();
const express = require('express');
const cors = require('cors');
const multer = require('multer');
const { google } = require('googleapis');
const fs = require('fs');
const path = require('path');

// --- Express Server Setup ---
const app = express();
const port = process.env.PORT || 3000; // Cloud server apna port khud chunega

// 🌐 UNIVERSAL CORS FIX: Kisi bhi device aur network se allow karein
app.use(cors({ origin: '*' }));

// 🛡️ Manual Preflight Fallback (Strict headers)
app.use((req, res, next) => {
    res.header('Access-Control-Allow-Origin', '*');
    res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS, PUT, DELETE');
    res.header('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept');
    if (req.method === 'OPTIONS') return res.status(200).end();
    next();
});

// Cloud servers mein temporary files /tmp/ mein save karni chahiye
const upload = multer({ dest: '/tmp/' });

// --- OAuth2 Configuration ---
const CLIENT_ID = process.env.CLIENT_ID;
const CLIENT_SECRET = process.env.CLIENT_SECRET;
const REDIRECT_URI = 'https://developers.google.com/oauthplayground';
const REFRESH_TOKEN = process.env.REFRESH_TOKEN;

const FOLDER_ID = '1n3cRNiqozwNBDeAjVA2FZH7JQwF7FnLE';

// --- Initialize Google OAuth2 ---
const oauth2Client = new google.auth.OAuth2(
    CLIENT_ID,
    CLIENT_SECRET,
    REDIRECT_URI
);

oauth2Client.setCredentials({ refresh_token: REFRESH_TOKEN });

const drive = google.drive({ version: 'v3', auth: oauth2Client });

/**
 * Uploads a video file to the specified Google Drive folder.
 * @param {string} filePath - Local path to the video file
 * @param {string} folderId - Destination folder ID in Google Drive
 * @returns {object} The uploaded file metadata containing its ID
 */
async function uploadVideoToDrive(filePath, originalName, mimeType, folderId) {
    
    const fileMetadata = {
        name: originalName,
        parents: [folderId],
    };

    const media = {
        mimeType: mimeType, 
        body: fs.createReadStream(filePath),
    };

    try {
        console.log(`Uploading ${originalName}...`);
        const response = await drive.files.create({
            resource: fileMetadata,
            media: media,
            fields: 'id, name',
        });
        
        console.log(`✅ Video uploaded successfully. File ID: ${response.data.id}`);
        return response.data;
    } catch (error) {
        console.error('❌ Error uploading file:', error.message);
        throw error;
    }
}

/**
 * Changes file permissions to public and retrieves streamable/viewable URLs.
 * @param {string} fileId - The ID of the file in Google Drive
 * @returns {object} Object containing webViewLink and webContentLink
 */
async function generatePublicUrl(fileId) {
    try {
        console.log('Generating public permissions...');
        // Change file permission so anyone with the link can read it
        await drive.permissions.create({
            fileId: fileId,
            requestBody: {
                role: 'reader',
                type: 'anyone',
            },
        });
    } catch (permError) {
        console.log('⚠️ Warning: Could not set public permissions. Proceeding anyway...');
    }

    try {
        // Fetch the file to get the URLs
        const result = await drive.files.get({
            fileId: fileId,
            fields: 'webViewLink, webContentLink',
        });

        console.log('✅ Public links generated!');
        console.log('--------------------------------------------------');
        console.log('📺 Web View Link (Drive Player):', result.data.webViewLink);
        console.log('⬇️  Web Content Link (Direct DL/Stream):', result.data.webContentLink);
        console.log('--------------------------------------------------');

        return result.data;
    } catch (error) {
        console.error('❌ Error generating public URL:', error.message);
        throw error;
    }
}

// --- API Endpoint (Frontend yahan video bhejega) ---
app.post('/api/upload', upload.single('video'), async (req, res) => {
    if (!req.file) {
        return res.status(400).json({ error: 'No video file uploaded' });
    }

    try {
        const filePath = req.file.path;
        const originalName = req.file.originalname;
        const mimeType = req.file.mimetype;

        // 1. Google Drive par upload karein
        const uploadedFile = await uploadVideoToDrive(filePath, originalName, mimeType, FOLDER_ID);
        
        // 2. Public link banayein
        const links = await generatePublicUrl(uploadedFile.id);

        // 3. Computer se temporary file delete kar dein (Storage bachane ke liye)
        try {
            fs.unlinkSync(filePath);
        } catch (e) {
            console.log('⚠️ Temporary file locked by Windows, skipped deletion.');
        }

        // Frontend (Website) ko response bhej dein
        res.json({
            success: true,
            webViewLink: links.webViewLink,
            webContentLink: links.webContentLink
        });

    } catch (error) {
        console.error('API Error:', error.message);
        try {
            if (req.file && fs.existsSync(req.file.path)) fs.unlinkSync(req.file.path);
        } catch(e) {}
        res.status(500).json({ error: 'Upload failed' });
    }
});

// 🎬 Proxy Stream Endpoint for Video Playback (Bypasses Drive CORS/Virus Scan restrictions)
app.get('/api/stream/:fileId', async (req, res) => {
    try {
        const fileId = req.params.fileId;
        const range = req.headers.range;

        const options = { responseType: 'stream' };
        if (range) {
            options.headers = { Range: range };
        }

            const response = await drive.files.get({ fileId: fileId, alt: 'media', acknowledgeAbuse: true }, options);

        // Forward necessary headers to browser for seamless video seeking/playing
        const headersToForward = ['content-length', 'content-range', 'content-type', 'accept-ranges'];
        for (const header of headersToForward) {
            if (response.headers[header]) res.setHeader(header, response.headers[header]);
         }
            
            // Force accept-ranges and content-type if missing
            if (!response.headers['accept-ranges']) res.setHeader('accept-ranges', 'bytes');
            if (!response.headers['content-type'] || response.headers['content-type'] === 'application/octet-stream') {
                res.setHeader('content-type', 'video/mp4');
            
        }
        
        res.status(response.status);
        response.data.pipe(res);
        
        response.data.on('error', (err) => { console.error('Stream pipe error:', err.message); res.end(); });
    } catch (error) {
        console.error('Streaming Error:', error.message);
        if (!res.headersSent) res.status(500).send('Video stream failed');
    }
});

// 🔍 Proxy Check Endpoint: Detect if a file still exists in Google Drive
app.get('/api/check/:fileId', async (req, res) => {
    try {
        await drive.files.get({ fileId: req.params.fileId, fields: 'id' });
        res.json({ exists: true });
    } catch (error) {
        if (error.code === 404 || error.status === 404) {
            res.json({ exists: false });
        } else {
            res.status(500).json({ error: error.message });
        }
    }
});

// 🗑️ Delete Endpoint: Automatically free up Drive space when site post is deleted
app.delete('/api/file/:fileId', async (req, res) => {
    try {
        await drive.files.delete({ fileId: req.params.fileId });
        res.json({ success: true });
    } catch (error) {
        if (error.code === 404 || error.status === 404) {
            res.json({ success: true, message: 'Already deleted' });
        } else {
            res.status(500).json({ error: error.message });
        }
    }
});

// 🕒 Keep-Alive Ping Endpoint (Taaki server kabhi soye nahi)
app.get('/api/ping', (req, res) => {
    res.status(200).send('Pong! Server is awake 🚀');
});

// 🌐 '0.0.0.0' lagana zaroori hai taaki cloud external requests accept kare
const server = app.listen(port, '0.0.0.0', () => {
    console.log(`🚀 Viyo Backend API is running on port ${port}`);
});

// ⏱️ Timeout disable kar diya taaki badi videos Drive par aaram se upload ho sakein
server.setTimeout(0);