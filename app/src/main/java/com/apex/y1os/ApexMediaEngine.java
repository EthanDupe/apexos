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
