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
