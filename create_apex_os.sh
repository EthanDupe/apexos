#!/usr/bin/env bash
set -e

echo "==> 1. Creating ApexOS Project Structure..."
mkdir -p app/src/main/java/com/apex/y1os
mkdir -p .github/workflows

echo "==> 2. Writing Root Gradle Files..."
cat << 'GRADLE_SETTINGS' > settings.gradle
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "ApexOS_Y1"
include ':app'
GRADLE_SETTINGS

cat << 'GRADLE_ROOT' > build.gradle
plugins {
    id 'com.android.application' version '8.2.2' apply false
}
GRADLE_ROOT

cat << 'GRADLE_PROPS' > gradle.properties
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=false
GRADLE_PROPS

cat << 'GRADLE_APP' > app/build.gradle
plugins {
    id 'com.android.application'
}

android {
    namespace 'com.apex.y1os'
    compileSdk 33

    defaultConfig {
        applicationId "com.apex.y1os"
        minSdk 21
        targetSdk 33
        versionCode 1
        versionName "1.0-ApexOS"
    }

    buildTypes {
        release {
            minifyEnabled true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt')
        }
        debug {
            minifyEnabled false
        }
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_11
        targetCompatibility JavaVersion.VERSION_11
    }
}

dependencies {
    // Zero heavy external dependencies to keep APK under 200KB and RAM usage minimal
}
GRADLE_APP

echo "==> 3. Writing AndroidManifest.xml (Full OS Home Replacement)..."
cat << 'MANIFEST_EOF' > app/src/main/AndroidManifest.xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.apex.y1os">

    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.WAKE_LOCK" />

    <application
        android:label="ApexOS Y1"
        android:hardwareAccelerated="true"
        android:largeHeap="true"
        android:theme="@android:style/Theme.NoTitleBar.Fullscreen">

        <activity
            android:name=".ApexMainActivity"
            android:exported="true"
            android:launchMode="singleTask"
            android:screenOrientation="landscape"
            android:configChanges="keyboard|keyboardHidden|orientation|screenSize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.HOME" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
MANIFEST_EOF

echo "==> 4. Writing Audio & Library Manager (ApexMediaEngine.java)..."
cat << 'JAVA_MEDIA' > app/src/main/java/com/apex/y1os/ApexMediaEngine.java
package com.apex.y1os;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.MediaMetadataRetriever;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.util.LruCache;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class ApexMediaEngine {

    public static class Track {
        public final long id;
        public final String title;
        public final String artist;
        public final String album;
        public final String path;
        public final long duration;

        public Track(long id, String title, String artist, String album, String path, long duration) {
            this.id = id;
            this.title = title != null ? title : "Unknown Track";
            this.artist = artist != null ? artist : "Unknown Artist";
            this.album = album != null ? album : "Unknown Album";
            this.path = path;
            this.duration = duration;
        }
    }

    public static class LyricLine implements Comparable<LyricLine> {
        public final long timeMs;
        public final String text;
        public LyricLine(long timeMs, String text) {
            this.timeMs = timeMs;
            this.text = text;
        }
        @Override
        public int compareTo(LyricLine o) {
            return Long.compare(this.timeMs, o.timeMs);
        }
    }

    private final Context context;
    private final MediaPlayer player = new MediaPlayer();
    private final List<Track> library = new ArrayList<>();
    private final List<LyricLine> currentLyrics = new ArrayList<>();
    private final LruCache<String, Bitmap> artCache;
    private final ExecutorService bgPool = Executors.newFixedThreadPool(2);
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final File diskCacheDir;

    private int currentTrackIndex = 0;
    private volatile boolean isFastScrolling = false;
    private long lastWheelTick = 0;
    private Runnable onUiInvalidate;

    public ApexMediaEngine(Context context, Runnable onUiInvalidate) {
        this.context = context.getApplicationContext();
        this.onUiInvalidate = onUiInvalidate;

        int maxMem = (int) (Runtime.getRuntime().maxMemory() / 1024);
        artCache = new LruCache<String, Bitmap>(maxMem / 5) {
            @Override
            protected int sizeOf(String key, Bitmap value) {
                return value.getByteCount() / 1024;
            }
        };

        diskCacheDir = new File(context.getCacheDir(), "apex_art_565");
        if (!diskCacheDir.exists()) diskCacheDir.mkdirs();

        player.setOnCompletionListener(mp -> nextTrack());
    }

    public void scanLibraryAsync() {
        bgPool.submit(() -> {
            List<Track> found = new ArrayList<>();
            ContentResolver cr = context.getContentResolver();
            Uri uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI;
            String[] proj = {
                MediaStore.Audio.Media._ID,
                MediaStore.Audio.Media.TITLE,
                MediaStore.Audio.Media.ARTIST,
                MediaStore.Audio.Media.ALBUM,
                MediaStore.Audio.Media.DATA,
                MediaStore.Audio.Media.DURATION
            };
            try (Cursor c = cr.query(uri, proj, MediaStore.Audio.Media.IS_MUSIC + "!= 0", null, MediaStore.Audio.Media.TITLE + " ASC")) {
                if (c != null) {
                    while (c.moveToNext()) {
                        found.add(new Track(
                            c.getLong(0), c.getString(1), c.getString(2),
                            c.getString(3), c.getString(4), c.getLong(5)
                        ));
                    }
                }
            } catch (Exception ignored) {}

            if (found.isEmpty()) {
                // Demo fallback entries so UI and Cover Flow can be tested before loading MP3s
                found.add(new Track(1, "Vampire", "Olivia Rodrigo", "GUTS", null, 219000));
                found.add(new Track(2, "Champagne Problems", "Taylor Swift", "Evermore", null, 244000));
                found.add(new Track(3, "Midnight Rain", "Taylor Swift", "Midnights", null, 174000));
                found.add(new Track(4, "Bad Idea Right?", "Olivia Rodrigo", "GUTS", null, 184000));
                found.add(new Track(5, "Chihiro", "Billie Eilish", "Hit Me Hard and Soft", null, 303000));
            }

            synchronized (library) {
                library.clear();
                library.addAll(found);
            }
            loadLyricsForCurrentTrack();
            mainHandler.post(onUiInvalidate);
        });
    }

    public List<Track> getLibrary() {
        synchronized (library) {
            return new ArrayList<>(library);
        }
    }

    public Track getCurrentTrack() {
        synchronized (library) {
            if (library.isEmpty()) return new Track(0, "No Tracks Found", "Innioasis Y1", "ApexOS", null, 0);
            return library.get(Math.max(0, Math.min(currentTrackIndex, library.size() - 1)));
        }
    }

    public void playTrackAt(int index) {
        List<Track> tracks = getLibrary();
        if (tracks.isEmpty()) return;
        currentTrackIndex = (index + tracks.size()) % tracks.size();
        Track t = tracks.get(currentTrackIndex);
        loadLyricsForCurrentTrack();

        if (t.path == null) {
            mainHandler.post(onUiInvalidate);
            return;
        }
        try {
            player.reset();
            player.setDataSource(t.path);
            player.prepare();
            player.start();
        } catch (Exception ignored) {}
        mainHandler.post(onUiInvalidate);
    }

    public void togglePlayPause() {
        try {
            if (player.isPlaying()) player.pause();
            else player.start();
        } catch (Exception ignored) {}
        mainHandler.post(onUiInvalidate);
    }

    public void nextTrack() {
        playTrackAt(currentTrackIndex + 1);
    }

    public void prevTrack() {
        playTrackAt(currentTrackIndex - 1);
    }

    public boolean isPlaying() {
        try {
            return player.isPlaying();
        } catch (Exception e) {
            return false;
        }
    }

    public long getPositionMs() {
        try {
            return player.isPlaying() ? player.getCurrentPosition() : 0;
        } catch (Exception e) {
            return 0;
        }
    }

    public List<LyricLine> getCurrentLyrics() {
        synchronized (currentLyrics) {
            return new ArrayList<>(currentLyrics);
        }
    }

    private void loadLyricsForCurrentTrack() {
        Track t = getCurrentTrack();
        List<LyricLine> parsed = new ArrayList<>();

        if (t.path != null) {
            int dot = t.path.lastIndexOf('.');
            File lrcFile = new File((dot > 0 ? t.path.substring(0, dot) : t.path) + ".lrc");
            if (lrcFile.exists()) {
                Pattern p = Pattern.compile("\\[(\\d{2}):(\\d{2})\\.(\\d{2,3})](.*)");
                try (BufferedReader br = new BufferedReader(new FileReader(lrcFile))) {
                    String line;
                    while ((line = br.readLine()) != null) {
                        Matcher m = p.matcher(line);
                        if (m.matches()) {
                            long min = Long.parseLong(m.group(1));
                            long sec = Long.parseLong(m.group(2));
                            String msStr = m.group(3);
                            long ms = Long.parseLong(msStr) * (msStr.length() == 2 ? 10 : 1);
                            String txt = m.group(4).trim();
                            if (!txt.isEmpty()) parsed.add(new LyricLine(min * 60000 + sec * 1000 + ms, txt));
                        }
                    }
                } catch (Exception ignored) {}
            }
        }

        if (parsed.isEmpty()) {
            parsed.add(new LyricLine(0, "♪ " + t.title + " — " + t.artist));
            parsed.add(new LyricLine(4000, "Place a matching .lrc file next to your audio file"));
            parsed.add(new LyricLine(8000, "for synchronized sub-pixel lyrics scrolling."));
            parsed.add(new LyricLine(12000, "ApexOS 60 FPS Hardware Canvas Engine."));
        }
        Collections.sort(parsed);
        synchronized (currentLyrics) {
            currentLyrics.clear();
            currentLyrics.addAll(parsed);
        }
    }

    public void notifyWheelTick() {
        long now = System.currentTimeMillis();
        isFastScrolling = (now - lastWheelTick) < 45;
        lastWheelTick = now;
        mainHandler.postDelayed(() -> {
            if (System.currentTimeMillis() - lastWheelTick >= 90) {
                isFastScrolling = false;
                onUiInvalidate.run();
            }
        }, 100);
    }

    public Bitmap getAlbumArt(final Track track) {
        if (track == null || track.path == null) return null;
        final String key = track.album + "_" + track.artist;
        Bitmap cached = artCache.get(key);
        if (cached != null) return cached;
        if (isFastScrolling) return null;

        bgPool.submit(() -> {
            if (isFastScrolling) return;
            File cacheFile = new File(diskCacheDir, Math.abs(key.hashCode()) + ".jpg");
            Bitmap bmp = null;

            if (cacheFile.exists()) {
                BitmapFactory.Options opts = new BitmapFactory.Options();
                opts.inPreferredConfig = Bitmap.Config.RGB_565;
                bmp = BitmapFactory.decodeFile(cacheFile.getAbsolutePath(), opts);
            } else {
                MediaMetadataRetriever mmr = new MediaMetadataRetriever();
                try {
                    mmr.setDataSource(track.path);
                    byte[] raw = mmr.getEmbeddedPicture();
                    if (raw != null) {
                        BitmapFactory.Options opts = new BitmapFactory.Options();
                        opts.inSampleSize = 2;
                        opts.inPreferredConfig = Bitmap.Config.RGB_565;
                        Bitmap decoded = BitmapFactory.decodeByteArray(raw, 0, raw.length, opts);
                        if (decoded != null) {
                            bmp = Bitmap.createScaledBitmap(decoded, 160, 160, true);
                            try (FileOutputStream fos = new FileOutputStream(cacheFile)) {
                                bmp.compress(Bitmap.CompressFormat.JPEG, 82, fos);
                            }
                        }
                    }
                } catch (Exception ignored) {
                } finally {
                    try { mmr.release(); } catch (Exception ignored) {}
                }
            }

            if (bmp != null) {
                artCache.put(key, bmp);
                mainHandler.post(onUiInvalidate);
            }
        });
        return null;
    }
}
JAVA_MEDIA

echo "==> 5. Writing 60FPS Hardware OS Canvas View (ApexSystemView.java)..."
cat << 'JAVA_VIEW' > app/src/main/java/com/apex/y1os/ApexSystemView.java
package com.apex.y1os;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.Camera;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Shader;
import android.os.BatteryManager;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.view.KeyEvent;
import android.view.View;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class ApexSystemView extends View {

    private static final int SCREEN_HOME = 0;
    private static final int SCREEN_COVERFLOW = 1;
    private static final int SCREEN_LYRICS = 2;
    private static final int SCREEN_THEMES = 3;

    private final ApexMediaEngine engine;
    private int currentScreen = SCREEN_HOME;

    // Smooth spring physics state variables
    private int homeIndex = 0;
    private float animatedHomeFocus = 0f;

    private int coverFlowIndex = 0;
    private float animatedCoverFlowIndex = 0f;

    private float animatedLyricY = 0f;

    // Built-in Themes: Obsidian Cyan, Classic iPod Silver, Cyberpunk Rose
    private int themeIndex = 0;
    private final int[][] THEMES = {
        {0xFF0D0F14, 0xFF151922, 0xFF1E293B, 0xFF38BDF8, 0xFFFFFFFF, 0xFF94A3B8},
        {0xFFE2E8F0, 0xFFFFFFFF, 0xFFCBD5E1, 0xFF0284C7, 0xFF0F172A, 0xFF475569},
        {0xFF12091C, 0xFF1F1130, 0xFF331B4F, 0xFFF43F5E, 0xFFFFFFFF, 0xFFC084FC}
    };
    private final String[] THEME_NAMES = {"Obsidian Glass Pro", "iPod Classic Silver", "Neon Synthwave"};

    private final String[] HOME_ITEMS = {
        "▶  Now Playing & Lyrics",
        "❖  3D Cover Flow",
        "♫  Shuffle All Tracks",
        "◈  Switch OS Theme",
        "⚙  Android System Settings"
    };

    private final Paint bgPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint cardPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint titlePaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint subPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final Camera camera3D = new Camera();
    private final Matrix matrix3D = new Matrix();
    private final RectF tempRect = new RectF();
    private final SimpleDateFormat clockFmt = new SimpleDateFormat("HH:mm", Locale.US);

    private long lastKeyTime = 0;

    public ApexSystemView(Context context) {
        super(context);
        setFocusable(true);
        setFocusableInTouchMode(true);
        setLayerType(LAYER_TYPE_HARDWARE, null);

        engine = new ApexMediaEngine(context, this::postInvalidateOnAnimation);
        engine.scanLibraryAsync();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        int w = getWidth();
        int h = getHeight();
        int[] palette = THEMES[themeIndex];

        // 1. Background fill
        bgPaint.setColor(palette[0]);
        canvas.drawRect(0, 0, w, h, bgPaint);

        // 2. Top Status Bar (Clock + Screen Title + Battery)
        drawStatusBar(canvas, w, palette);

        // 3. Screen Router
        boolean needsNextFrame = false;
        if (currentScreen == SCREEN_HOME) {
            needsNextFrame = drawHomeScreen(canvas, w, h, palette);
        } else if (currentScreen == SCREEN_COVERFLOW) {
            needsNextFrame = drawCoverFlowScreen(canvas, w, h, palette);
        } else if (currentScreen == SCREEN_LYRICS) {
            needsNextFrame = drawLyricsScreen(canvas, w, h, palette);
        }

        if (needsNextFrame || engine.isPlaying()) {
            postInvalidateOnAnimation();
        }
    }

    private void drawStatusBar(Canvas canvas, int w, int[] palette) {
        subPaint.setColor(palette[5]);
        subPaint.setTextSize(13f);
        canvas.drawText(clockFmt.format(new Date()), 20, 22, subPaint);

        String title = currentScreen == SCREEN_HOME ? "ApexOS 1.0" :
                       currentScreen == SCREEN_COVERFLOW ? "Cover Flow" : "Now Playing";
        float tw = subPaint.measureText(title);
        canvas.drawText(title, (w - tw) / 2f, 22, subPaint);

        String bat = getBatteryPercentage() + "%";
        float bw = subPaint.measureText(bat);
        canvas.drawText(bat, w - bw - 20, 22, subPaint);
    }

    private boolean drawHomeScreen(Canvas canvas, int w, int h, int[] palette) {
        boolean animating = false;
        float diff = homeIndex - animatedHomeFocus;
        if (Math.abs(diff) > 0.01f) {
            animatedHomeFocus += diff * 0.28f;
            animating = true;
        } else {
            animatedHomeFocus = homeIndex;
        }

        // Left Menu Stack
        for (int i = 0; i < HOME_ITEMS.length; i++) {
            float top = 42 + i * 58;
            boolean focused = (i == homeIndex);
            float scaleOffset = Math.max(0f, 1f - Math.abs(i - animatedHomeFocus));

            cardPaint.setColor(focused ? palette[2] : palette[1]);
            tempRect.set(18 + (scaleOffset * 6f), top, 242 + (scaleOffset * 6f), top + 46);
            canvas.drawRoundRect(tempRect, 12f, 12f, cardPaint);

            titlePaint.setTextSize(15f);
            titlePaint.setFakeBoldText(focused);
            titlePaint.setColor(focused ? palette[3] : palette[4]);
            canvas.drawText(HOME_ITEMS[i], 32 + (scaleOffset * 6f), top + 28, titlePaint);
        }

        // Right Showcase Panel (160x160 Album Art + Live Track Info)
        cardPaint.setColor(palette[1]);
        tempRect.set(262, 42, w - 18, h - 22);
        canvas.drawRoundRect(tempRect, 16f, 16f, cardPaint);

        ApexMediaEngine.Track track = engine.getCurrentTrack();
        Bitmap art = engine.getAlbumArt(track);
        float artLeft = 290;
        float artTop = 58;
        tempRect.set(artLeft, artTop, artLeft + 144, artTop + 144);

        if (art != null) {
            canvas.drawBitmap(art, null, tempRect, null);
        } else {
            cardPaint.setColor(palette[2]);
            canvas.drawRoundRect(tempRect, 12f, 12f, cardPaint);
            titlePaint.setColor(palette[3]);
            titlePaint.setTextSize(34f);
            canvas.drawText("♫", artLeft + 56, artTop + 84, titlePaint);
        }

        titlePaint.setColor(palette[4]);
        titlePaint.setTextSize(15f);
        titlePaint.setFakeBoldText(true);
        canvas.drawText(ellipsize(track.title, 18), 278, 232, titlePaint);

        subPaint.setColor(palette[3]);
        subPaint.setTextSize(13f);
        canvas.drawText(ellipsize(track.artist, 22), 278, 254, subPaint);

        subPaint.setColor(palette[5]);
        canvas.drawText("Theme: " + THEME_NAMES[themeIndex], 278, 286, subPaint);

        return animating;
    }

    private boolean drawCoverFlowScreen(Canvas canvas, int w, int h, int[] palette) {
        List<ApexMediaEngine.Track> tracks = engine.getLibrary();
        if (tracks.isEmpty()) return false;

        boolean animating = false;
        float diff = coverFlowIndex - animatedCoverFlowIndex;
        if (Math.abs(diff) > 0.008f) {
            animatedCoverFlowIndex += diff * 0.22f;
            animating = true;
        } else {
            animatedCoverFlowIndex = coverFlowIndex;
        }

        int centerIdx = Math.round(animatedCoverFlowIndex);
        float centerX = w / 2f;
        float centerY = h / 2f - 15f;

        // Draw outer cards first, then center card on top
        int[] drawOrder = {-3, 3, -2, 2, -1, 1, 0};
        for (int offset : drawOrder) {
            int idx = centerIdx + offset;
            if (idx < 0 || idx >= tracks.size()) continue;

            float relativeOffset = idx - animatedCoverFlowIndex;
            ApexMediaEngine.Track t = tracks.get(idx);
            Bitmap bmp = engine.getAlbumArt(t);

            canvas.save();
            camera3D.save();

            float rotY = Math.max(-55f, Math.min(55f, -relativeOffset * 42f));
            float transZ = Math.abs(relativeOffset) * 38f;
            camera3D.translate(0f, 0f, transZ);
            camera3D.rotateY(rotY);
            camera3D.getMatrix(matrix3D);
            camera3D.restore();

            float cardX = centerX + (relativeOffset * 78f);
            matrix3D.preTranslate(-75f, -75f);
            matrix3D.postTranslate(cardX, centerY);
            canvas.concat(matrix3D);

            tempRect.set(0, 0, 150, 150);
            if (bmp != null) {
                canvas.drawBitmap(bmp, null, tempRect, null);
            } else {
                cardPaint.setColor(palette[2]);
                canvas.drawRoundRect(tempRect, 10f, 10f, cardPaint);
                titlePaint.setColor(palette[3]);
                titlePaint.setTextSize(28f);
                canvas.drawText("❖", 60, 85, titlePaint);
            }
            canvas.restore();
        }

        // Focused Album Title + Artist Footer
        ApexMediaEngine.Track active = tracks.get(Math.max(0, Math.min(coverFlowIndex, tracks.size() - 1)));
        titlePaint.setColor(palette[4]);
        titlePaint.setTextSize(17f);
        titlePaint.setFakeBoldText(true);
        String tTitle = ellipsize(active.title, 28);
        canvas.drawText(tTitle, (w - titlePaint.measureText(tTitle)) / 2f, h - 52, titlePaint);

        subPaint.setColor(palette[3]);
        subPaint.setTextSize(14f);
        String tArtist = ellipsize(active.artist + " • " + active.album, 36);
        canvas.drawText(tArtist, (w - subPaint.measureText(tArtist)) / 2f, h - 28, subPaint);

        return animating;
    }

    private boolean drawLyricsScreen(Canvas canvas, int w, int h, int[] palette) {
        ApexMediaEngine.Track track = engine.getCurrentTrack();
        List<ApexMediaEngine.LyricLine> lyrics = engine.getCurrentLyrics();
        long pos = engine.getPositionMs();

        int activeIdx = 0;
        for (int i = 0; i < lyrics.size(); i++) {
            if (pos >= lyrics.get(i).timeMs) activeIdx = i;
            else break;
        }

        float targetY = activeIdx * 44f;
        boolean animating = false;
        if (Math.abs(targetY - animatedLyricY) > 0.5f) {
            animatedLyricY += (targetY - animatedLyricY) * 0.18f;
            animating = true;
        }

        // Header track bar
        titlePaint.setColor(palette[4]);
        titlePaint.setTextSize(16f);
        titlePaint.setFakeBoldText(true);
        canvas.drawText(ellipsize(track.title + " — " + track.artist, 34), 24, 54, titlePaint);

        float centerY = h / 2f + 10f;
        int contentWidth = w - 48;

        for (int i = 0; i < lyrics.size(); i++) {
            float y = centerY + (i * 44f) - animatedLyricY;
            if (y < 65 || y > h - 35) continue;

            boolean isCurrent = (i == activeIdx);
            titlePaint.setTextSize(isCurrent ? 19f : 15f);
            titlePaint.setFakeBoldText(isCurrent);
            titlePaint.setColor(isCurrent ? palette[3] : palette[5]);

            int dist = Math.abs(i - activeIdx);
            titlePaint.setAlpha(isCurrent ? 255 : Math.max(50, 175 - dist * 40));

            StaticLayout sl = new StaticLayout(
                lyrics.get(i).text, titlePaint, contentWidth,
                Layout.Alignment.ALIGN_CENTER, 1.0f, 0f, false
            );
            canvas.save();
            canvas.translate(24, y - sl.getHeight() / 2f);
            sl.draw(canvas);
            canvas.restore();
        }
        titlePaint.setAlpha(255);
        return animating;
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        long now = System.currentTimeMillis();
        // Wheel velocity acceleration: spinning fast jumps 3 items at a time
        int step = (now - lastKeyTime < 35) ? 3 : 1;
        lastKeyTime = now;
        engine.notifyWheelTick();

        // Scroll Wheel Counter-Clockwise (Up / Left)
        if (keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_DPAD_LEFT || keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (currentScreen == SCREEN_HOME) {
                homeIndex = Math.max(0, homeIndex - 1);
            } else if (currentScreen == SCREEN_COVERFLOW) {
                coverFlowIndex = Math.max(0, coverFlowIndex - step);
            } else if (currentScreen == SCREEN_LYRICS) {
                engine.prevTrack();
            }
            postInvalidateOnAnimation();
            return true;
        }

        // Scroll Wheel Clockwise (Down / Right)
        if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN || keyCode == KeyEvent.KEYCODE_DPAD_RIGHT || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (currentScreen == SCREEN_HOME) {
                homeIndex = Math.min(HOME_ITEMS.length - 1, homeIndex + 1);
            } else if (currentScreen == SCREEN_COVERFLOW) {
                int max = Math.max(0, engine.getLibrary().size() - 1);
                coverFlowIndex = Math.min(max, coverFlowIndex + step);
            } else if (currentScreen == SCREEN_LYRICS) {
                engine.nextTrack();
            }
            postInvalidateOnAnimation();
            return true;
        }

        // Center Button Press
        if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER) {
            if (currentScreen == SCREEN_HOME) {
                if (homeIndex == 0) currentScreen = SCREEN_LYRICS;
                else if (homeIndex == 1) currentScreen = SCREEN_COVERFLOW;
                else if (homeIndex == 2) {
                    int rand = (int) (Math.random() * Math.max(1, engine.getLibrary().size()));
                    engine.playTrackAt(rand);
                    currentScreen = SCREEN_LYRICS;
                } else if (homeIndex == 3) {
                    themeIndex = (themeIndex + 1) % THEMES.length;
                } else if (homeIndex == 4) {
                    try {
                        getContext().startActivity(new Intent(android.provider.Settings.ACTION_SETTINGS));
                    } catch (Exception ignored) {}
                }
            } else if (currentScreen == SCREEN_COVERFLOW) {
                engine.playTrackAt(coverFlowIndex);
                currentScreen = SCREEN_LYRICS;
            } else if (currentScreen == SCREEN_LYRICS) {
                engine.togglePlayPause();
            }
            postInvalidateOnAnimation();
            return true;
        }

        // Back / Menu Button Press
        if (keyCode == KeyEvent.KEYCODE_BACK || keyCode == KeyEvent.KEYCODE_MENU || keyCode == KeyEvent.KEYCODE_ESCAPE) {
            if (currentScreen != SCREEN_HOME) {
                currentScreen = SCREEN_HOME;
                postInvalidateOnAnimation();
            }
            return true;
        }

        return super.onKeyDown(keyCode, event);
    }

    private int getBatteryPercentage() {
        try {
            Intent bat = getContext().registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (bat != null) {
                int level = bat.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
                int scale = bat.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
                if (level >= 0 && scale > 0) return (level * 100) / scale;
            }
        } catch (Exception ignored) {}
        return 100;
    }

    private String ellipsize(String text, int maxChars) {
        if (text == null) return "";
        return text.length() <= maxChars ? text : text.substring(0, maxChars - 1) + "…";
    }
}
JAVA_VIEW

echo "==> 6. Writing Main OS Activity (ApexMainActivity.java)..."
cat << 'JAVA_MAIN' > app/src/main/java/com/apex/y1os/ApexMainActivity.java
package com.apex.y1os;

import android.app.Activity;
import android.os.Bundle;
import android.view.Window;
import android.view.WindowManager;

public class ApexMainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(
            WindowManager.LayoutParams.FLAG_FULLSCREEN,
            WindowManager.LayoutParams.FLAG_FULLSCREEN
        );
        setContentView(new ApexSystemView(this));
    }

    @Override
    public void onBackPressed() {
        // Block exiting the OS shell when pressing back on the home screen
    }
}
JAVA_MAIN

echo "==> 7. Writing GitHub Actions Cloud Builder (.github/workflows/build-apex-os.yml)..."
cat << 'YAML_EOF' > .github/workflows/build-apex-os.yml
name: Build ApexOS Y1 APK

on:
  push:
    branches: [ "main", "master" ]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'

      - name: Setup Gradle & Build APK
        uses: gradle/actions/setup-gradle@v3
        with:
          gradle-version: '8.4'

      - name: Assemble Debug APK
        run: gradle assembleDebug --no-daemon

      - name: Upload ApexOS APK Artifact
        uses: actions/upload-artifact@v4
        with:
          name: ApexOS-Y1-Installer
          path: app/build/outputs/apk/debug/*.apk
YAML_EOF

echo "==> ApexOS project generated! Commit and push to GitHub to build your APK automatically."
