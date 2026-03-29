// ============================================================
// NTE JOB TRACKER — Google Drive Upload Handler
// New Tech Engineers, Pune
// ============================================================
//
// HOW TO DEPLOY:
//   1. Go to script.google.com → New project → paste this file
//   2. Click Deploy → New deployment → Web app
//   3. Execute as: Me   |   Who has access: Anyone (even anonymous)
//   4. Click Deploy → copy the Web App URL
//   5. In the NTE Tracker app → 🗂️ Drive → paste the URL → Save
//
// Files are saved to: "NTE Job Drawings" folder in this Google account's Drive.
// ============================================================

var FOLDER_NAME = 'NTE Job Drawings';

// ── Main POST handler ──────────────────────────────────────
function doPost(e) {
  try {
    var params = JSON.parse(e.postData.contents);

    // Delete action
    if (params.action === 'delete' && params.fileId) {
      try { DriveApp.getFileById(params.fileId).setTrashed(true); } catch(ex) {}
      return out({ success: true });
    }

    // Upload action
    var base64   = params.data;
    var fileName = params.name  || ('drawing_' + Date.now());
    var mimeType = params.type  || 'application/octet-stream';
    var jobId    = params.jobId || '';

    // Prefix filename with Job ID for easy identification in Drive
    if (jobId && jobId !== 'TEST') fileName = jobId + '_' + fileName;

    // Decode and save
    var bytes  = Utilities.base64Decode(base64);
    var blob   = Utilities.newBlob(bytes, mimeType, fileName);
    var folder = getOrCreateFolder(FOLDER_NAME);
    var file   = folder.createFile(blob);

    // Make file viewable by anyone with the link
    file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);

    return out({
      success: true,
      url:     'https://drive.google.com/file/d/' + file.getId() + '/view',
      fileId:  file.getId(),
      name:    fileName
    });

  } catch (err) {
    return out({ success: false, error: err.toString() });
  }
}

// ── Helpers ───────────────────────────────────────────────
function getOrCreateFolder(name) {
  var folders = DriveApp.getFoldersByName(name);
  return folders.hasNext() ? folders.next() : DriveApp.createFolder(name);
}

function out(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// ── Test (run in Apps Script editor to verify setup) ──────
function testSetup() {
  var folder = getOrCreateFolder(FOLDER_NAME);
  Logger.log('✓ Folder: ' + folder.getUrl());
  Logger.log('✓ Drive setup is working correctly.');
}
