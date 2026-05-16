require('dotenv').config();
const { google } = require('googleapis');
const fs = require('fs');
const path = require('path');

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
async function uploadVideoToDrive(filePath, folderId) {
    const fileName = path.basename(filePath);
    
    const fileMetadata = {
        name: fileName,
        parents: [folderId],
    };

    const media = {
        mimeType: 'video/mp4', // Adjust if you are uploading .webm, .mkv, etc.
        body: fs.createReadStream(filePath),
    };

    try {
        console.log(`Uploading ${fileName}...`);
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

// --- Main Execution ---
async function main() {
    // Apni video file ka sahi naam yahan dalein, jo d:\Viyo\function folder mein hi ho.
    const videoFilePath = path.join(__dirname, 'sample-video.mp4'); 

    if (!fs.existsSync(videoFilePath)) {
        console.error(`❌ Could not find video file at ${videoFilePath}`);
        console.log('Please make sure "sample-video.mp4" exists in the "function" folder.');
        return;
    }

    try {
        // 1. Upload the video
        const uploadedFile = await uploadVideoToDrive(videoFilePath, FOLDER_ID);

        // 2. Generate and print the public URLs using the uploaded file's ID
        await generatePublicUrl(uploadedFile.id);
        
    } catch (error) {
        console.error('Process failed:', error.message);
    }
}

main();