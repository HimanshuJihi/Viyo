// Google Drive integration removed.
// This service previously provided endpoints for uploading/streaming files via Google Drive.
// Keeping a placeholder server that returns 404 for legacy endpoints to avoid accidental usage.

const express = require('express');
const app = express();
const port = process.env.PORT || 3000;
app.use((req, res, next) => {
  if (req.path.startsWith('/api/')) {
    return res.status(410).json({ error: 'Google Drive integration removed. Use Firebase Storage for uploads.' });
  }
  next();
});

app.get('/', (req, res) => res.send('Drive integration removed.'));
app.listen(port, '0.0.0.0', () => console.log(`Placeholder API running on port ${port}`));
// Remaining Google Drive code removed.
// This file retained as a placeholder indicating Drive integration has been removed.
// All endpoints under /api/* now return 410 Gone from the placeholder server at the top of the file.