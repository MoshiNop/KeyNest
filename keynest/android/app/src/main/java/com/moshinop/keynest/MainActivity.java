package com.moshinop.keynest;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.UriPermission;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PersistableBundle;
import android.provider.DocumentsContract;
import android.provider.Settings;
import android.view.WindowManager;

import androidx.documentfile.provider.DocumentFile;

import org.jetbrains.annotations.NotNull;
import org.json.JSONObject;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterFragmentActivity {
    private static final String CHANNEL = "app.keynest/misc";
    private static final Logger logger = LoggerFactory.getLogger(MainActivity.class);
    private final ExecutorService safIoExecutor = Executors.newSingleThreadExecutor();

    @Override
    protected void onDestroy() {
        safIoExecutor.shutdown();
        super.onDestroy();
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        if (isSecureWindowEnabled()) {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                if (checkSelfPermission(Manifest.permission.HIDE_OVERLAY_WINDOWS) == PackageManager.PERMISSION_GRANTED) {
                    getWindow().setHideOverlayWindows(true);
                }
            } catch (Throwable t) {
                logger.warn("Unable to setHideOverlayWindows: " + t);
            }
        }
        super.onCreate(savedInstanceState);
        Intent intent = getIntent();
        logger.debug("onCreate action=" + (intent != null ? intent.getAction() : "null"));
    }

    private boolean isSecureWindowEnabled() {
        try {
            File[] candidateDirs = new File[] {
                getDir("flutter", Context.MODE_PRIVATE),
                getFilesDir(),
                getApplicationInfo().dataDir != null ? new File(getApplicationInfo().dataDir, "app_flutter") : null
            };
            for (File dir : candidateDirs) {
                if (dir != null && dir.exists()) {
                    File appDataFile = new File(dir, "AppData.json");
                    if (appDataFile.exists() && appDataFile.canRead()) {
                        String content = new String(Files.readAllBytes(appDataFile.toPath()), StandardCharsets.UTF_8);
                        JSONObject json = new JSONObject(content);
                        if (json.has("secureWindow")) {
                            return json.optBoolean("secureWindow", true);
                        }
                    }
                }
            }
        } catch (Throwable t) {
            logger.warn("Failed to check secureWindow preference, defaulting to secure: " + t);
        }
        return true; // Default is secure
    }

    @Override
    protected void onNewIntent(@NotNull Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        logger.debug("onNewIntent action=" + intent.getAction());
    }

    private static final int REQUEST_CODE_PICK_DIR_TREE = 4221;
    private MethodChannel.Result pendingDirPickResult;

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_CODE_PICK_DIR_TREE) {
            if (pendingDirPickResult != null) {
                if (resultCode == Activity.RESULT_OK && data != null && data.getData() != null) {
                    Uri treeUri = data.getData();
                    int takeFlags = data.getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
                    if (takeFlags == 0) {
                        takeFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
                    }
                    try {
                        getContentResolver().takePersistableUriPermission(treeUri, takeFlags);
                    } catch (Exception e) {
                        logger.warn("takePersistableUriPermission failed: " + e);
                    }

                    String displayPath = formatTreeUriPath(treeUri);
                    DocumentFile dir = DocumentFile.fromTreeUri(this, treeUri);
                    String dirName = (dir != null && dir.getName() != null) ? dir.getName() : "Folder";

                    Map<String, Object> resMap = new HashMap<>();
                    resMap.put("treeUri", treeUri.toString());
                    resMap.put("displayPath", displayPath);
                    resMap.put("displayName", dirName);
                    pendingDirPickResult.success(resMap);
                } else {
                    pendingDirPickResult.success(null);
                }
                pendingDirPickResult = null;
            }
        }
    }

    private String formatTreeUriPath(Uri treeUri) {
        try {
            String docId = DocumentsContract.getTreeDocumentId(treeUri);
            if (docId != null) {
                String[] parts = docId.split(":", 2);
                if (parts.length == 2) {
                    if ("primary".equalsIgnoreCase(parts[0])) {
                        return "/storage/emulated/0/" + parts[1];
                    } else {
                        return "/storage/" + parts[0] + "/" + parts[1];
                    }
                } else if (parts.length == 1) {
                    if ("primary".equalsIgnoreCase(parts[0])) {
                        return "/storage/emulated/0";
                    }
                    return parts[0];
                }
            }
        } catch (Exception ignored) {}
        DocumentFile dir = DocumentFile.fromTreeUri(this, treeUri);
        return (dir != null && dir.getName() != null) ? dir.getName() : treeUri.toString();
    }

    @Override
    public void configureFlutterEngine(@NotNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL).setMethodCallHandler((call, result) -> {
            if ("isFirebaseTestLab".equals(call.method)) {
                result.success("true".equals(Settings.System.getString(getContentResolver(), "firebase.test.lab")));
                return;
            } else if ("setSecureWindow".equals(call.method)) {
                Boolean enabled = call.argument("enabled");
                boolean secure = enabled == null || enabled;
                if (secure) {
                    getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
                } else {
                    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_SECURE);
                }
                result.success(true);
                return;
            } else if ("setSensitiveClipboard".equals(call.method)) {
                String text = call.argument("text");
                String label = call.argument("label");
                if (label == null) {
                    label = "sensitive";
                }
                ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                if (clipboard != null && text != null) {
                    ClipData clip = ClipData.newPlainText(label, text);
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        PersistableBundle extras = new PersistableBundle();
                        extras.putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true);
                        clip.getDescription().setExtras(extras);
                    }
                    clipboard.setPrimaryClip(clip);
                    result.success(true);
                    return;
                }
                result.success(false);
                return;
            } else if ("clearClipboardIfMatches".equals(call.method)) {
                String expectedText = call.argument("text");
                ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                if (clipboard != null) {
                    ClipData primaryClip = clipboard.getPrimaryClip();
                    if (primaryClip != null && primaryClip.getItemCount() > 0) {
                        CharSequence currentText = primaryClip.getItemAt(0).getText();
                        if (expectedText == null || (currentText != null && expectedText.equals(currentText.toString()))) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                clipboard.clearPrimaryClip();
                            } else {
                                clipboard.setPrimaryClip(ClipData.newPlainText("", ""));
                            }
                            result.success(true);
                            return;
                        }
                    }
                }
                result.success(false);
                return;
            } else if ("openAppSettings".equals(call.method)) {
                try {
                    Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                    intent.setData(Uri.fromParts("package", getPackageName(), null));
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    startActivity(intent);
                    result.success(true);
                    return;
                } catch (Exception e) {
                    logger.error("Failed to open application details settings", e);
                    result.success(false);
                    return;
                }
            } else if ("pickDirectoryTree".equals(call.method)) {
                pendingDirPickResult = result;
                Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION 
                    | Intent.FLAG_GRANT_WRITE_URI_PERMISSION 
                    | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION 
                    | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
                startActivityForResult(intent, REQUEST_CODE_PICK_DIR_TREE);
                return;
            } else if ("getPersistedTreeUriForPath".equals(call.method)) {
                String path = call.argument("path");
                if (path == null) {
                    result.success(null);
                    return;
                }
                String normalizedPath = path.replace("\\", "/");
                while (normalizedPath.endsWith("/")) {
                    normalizedPath = normalizedPath.substring(0, normalizedPath.length() - 1);
                }
                try {
                    List<UriPermission> perms = getContentResolver().getPersistedUriPermissions();
                    for (UriPermission perm : perms) {
                        if (perm.isWritePermission() && DocumentsContract.isTreeUri(perm.getUri())) {
                            String treePath = formatTreeUriPath(perm.getUri());
                            while (treePath.endsWith("/")) {
                                treePath = treePath.substring(0, treePath.length() - 1);
                            }
                            if (normalizedPath.equalsIgnoreCase(treePath) || 
                                normalizedPath.startsWith(treePath + "/") || 
                                (treePath.startsWith("/storage/emulated/0") && normalizedPath.equals(treePath))) {
                                result.success(perm.getUri().toString());
                                return;
                            }
                        }
                    }
                } catch (Exception e) {
                    logger.warn("Failed checking persisted uri permissions: " + e);
                }
                result.success(null);
                return;
            } else if ("safCheckFileExists".equals(call.method)) {
                String treeUriStr = call.argument("treeUri");
                String fileName = call.argument("fileName");
                String subPath = call.argument("subPath");
                if (treeUriStr != null && fileName != null) {
                    safIoExecutor.execute(() -> {
                        boolean exists = false;
                        try {
                            DocumentFile rootDir = DocumentFile.fromTreeUri(this, Uri.parse(treeUriStr));
                            DocumentFile dir = resolveSafSubdirectory(rootDir, subPath, false);
                            if (dir != null && dir.exists()) {
                                DocumentFile file = dir.findFile(fileName);
                                exists = file != null && file.exists();
                            }
                        } catch (Exception e) {
                            logger.warn("safCheckFileExists error: " + e);
                        }
                        final boolean finalExists = exists;
                        runOnUiThread(() -> result.success(finalExists));
                    });
                    return;
                }
                result.success(false);
                return;
            } else if ("safWriteFile".equals(call.method)) {
                String treeUriStr = call.argument("treeUri");
                String fileName = call.argument("fileName");
                String sourceFilePath = call.argument("sourceFilePath");
                String subPath = call.argument("subPath");
                boolean overwrite = Boolean.TRUE.equals(call.argument("overwrite"));

                if (treeUriStr == null || fileName == null || sourceFilePath == null) {
                    result.error("INVALID_ARGS", "Missing required arguments", null);
                    return;
                }

                safIoExecutor.execute(() -> {
                    File sourceFile = new File(sourceFilePath);
                    if (!sourceFile.exists()) {
                        runOnUiThread(() -> result.error("SOURCE_NOT_FOUND", "Source temporary file does not exist", null));
                        return;
                    }

                    try {
                        DocumentFile rootDir = DocumentFile.fromTreeUri(this, Uri.parse(treeUriStr));
                        if (rootDir == null || !rootDir.exists() || !rootDir.canWrite()) {
                            runOnUiThread(() -> result.error("PERMISSION_DENIED", "Destination folder does not exist or write permission was revoked.", null));
                            return;
                        }

                        DocumentFile dir = resolveSafSubdirectory(rootDir, subPath, true);
                        if (dir == null || !dir.exists() || !dir.canWrite()) {
                            runOnUiThread(() -> result.error("PERMISSION_DENIED", "Destination subfolder could not be resolved or is not writable.", null));
                            return;
                        }

                        long expectedSize = sourceFile.length();
                        DocumentFile existing = dir.findFile(fileName);
                        if (existing != null && existing.exists()) {
                            if (!overwrite) {
                                runOnUiThread(() -> result.error("FILE_EXISTS", "A file named " + fileName + " already exists in the destination folder.", null));
                                return;
                            }

                            // Stage into a sibling .tmp DocumentFile FIRST so ENOSPC or permission
                            // errors never destroy `existing` or invalidate its Document URI.
                            String tmpName = fileName + ".tmp";
                            DocumentFile staleTmp = dir.findFile(tmpName);
                            if (staleTmp != null && staleTmp.exists()) {
                                staleTmp.delete();
                            }
                            DocumentFile tmpDoc = dir.createFile("application/octet-stream", tmpName);
                            if (tmpDoc == null) {
                                runOnUiThread(() -> result.error("CREATE_FAILED", "Failed to create staging document in selected folder.", null));
                                return;
                            }

                            try {
                                copyFileToDocumentUri(sourceFile, tmpDoc.getUri(), expectedSize);
                            } catch (Exception stageEx) {
                                try {
                                    tmpDoc.delete();
                                } catch (Exception ignored) {}
                                throw stageEx;
                            }

                            // Overwrite existing Document URI in-place (preserving persistent SAF URI).
                            // If streaming into `existing` fails mid-way, `tmpDoc` still holds the valid vault.
                            copyFileToDocumentUri(sourceFile, existing.getUri(), expectedSize);
                            try {
                                tmpDoc.delete();
                            } catch (Exception ignored) {}

                            Map<String, Object> resMap = new HashMap<>();
                            resMap.put("uri", existing.getUri().toString());
                            resMap.put("fileName", existing.getName() != null ? existing.getName() : fileName);
                            resMap.put("size", expectedSize);
                            runOnUiThread(() -> result.success(resMap));
                            return;
                        }

                        DocumentFile newDoc = dir.createFile("application/octet-stream", fileName);
                        if (newDoc == null) {
                            runOnUiThread(() -> result.error("CREATE_FAILED", "Failed to create document in selected folder.", null));
                            return;
                        }

                        try {
                            copyFileToDocumentUri(sourceFile, newDoc.getUri(), expectedSize);
                            Map<String, Object> resMap = new HashMap<>();
                            resMap.put("uri", newDoc.getUri().toString());
                            resMap.put("fileName", newDoc.getName() != null ? newDoc.getName() : fileName);
                            resMap.put("size", expectedSize);
                            runOnUiThread(() -> result.success(resMap));
                        } catch (Exception writeEx) {
                            try {
                                newDoc.delete();
                            } catch (Exception ignored) {}
                            throw writeEx;
                        }
                    } catch (Exception e) {
                        logger.error("safWriteFile error: " + e.getMessage(), e);
                        runOnUiThread(() -> result.error("WRITE_ERROR", "Failed to write file to destination folder: " + e.getMessage(), null));
                    }
                });
                return;
            }
            result.notImplemented();
        });
    }

    private DocumentFile resolveSafSubdirectory(DocumentFile rootDir, String subPath, boolean createIfMissing) {
        if (rootDir == null || subPath == null || subPath.trim().isEmpty()) {
            return rootDir;
        }
        String normalized = subPath.replace("\\", "/");
        String[] segments = normalized.split("/");
        DocumentFile current = rootDir;
        for (String rawSeg : segments) {
            String seg = rawSeg.trim();
            if (seg.isEmpty() || ".".equals(seg)) {
                continue;
            }
            if ("..".equals(seg)) {
                return null;
            }
            DocumentFile next = null;
            for (DocumentFile child : current.listFiles()) {
                if (child.isDirectory() && seg.equalsIgnoreCase(child.getName())) {
                    next = child;
                    break;
                }
            }
            if (next == null) {
                if (!createIfMissing) {
                    return null;
                }
                next = current.createDirectory(seg);
                if (next == null) {
                    return null;
                }
            }
            current = next;
        }
        return current;
    }

    private void copyFileToDocumentUri(File sourceFile, Uri targetUri, long expectedSize) throws IOException {
        OutputStream rawOut = null;
        try {
            rawOut = getContentResolver().openOutputStream(targetUri, "rwt");
        } catch (Exception ignored) {
            rawOut = getContentResolver().openOutputStream(targetUri, "wt");
        }
        if (rawOut == null) {
            throw new IOException("Failed to open output stream for document.");
        }
        long totalWritten = 0;
        try (InputStream in = new FileInputStream(sourceFile);
             OutputStream out = rawOut) {
            byte[] buf = new byte[8192];
            int len;
            while ((len = in.read(buf)) != -1) {
                out.write(buf, 0, len);
                totalWritten += len;
            }
            out.flush();
            if (out instanceof FileOutputStream) {
                try {
                    ((FileOutputStream) out).getFD().sync();
                } catch (Exception ignored) {}
            }
        }
        if (totalWritten != expectedSize) {
            throw new IOException("Incomplete SAF write (" + totalWritten + " != " + expectedSize + " bytes).");
        }
    }
}
