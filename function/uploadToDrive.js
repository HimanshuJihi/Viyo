require('dotenv').config();
const express = require('express');
const cors = require('cors');
const multer = require('multer');
const { google } = require('googleapis');
const fs = require('fs');
const path = require('path');

// --- Express Server Setup ---
const app = express();
const port = 3000;
app.use(cors()); // Frontend ko access dene ke liye

// Uploads folder setup jahan files temporarily save hongi
const upload = multer({ dest: 'uploads/' });

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

const server = app.listen(port, () => {
    console.log(`🚀 Viyo Backend API is running on http://localhost:${port}`);
});

// ⏱️ Timeout disable kar diya taaki badi videos Drive par aaram se upload ho sakein
server.setTimeout(0);