package com.ryanheise.audioservice;

import android.app.Instrumentation;
import android.os.SystemClock;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaControllerCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;

import androidx.media.utils.MediaConstants;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import java.lang.reflect.Field;
import java.util.Collections;

import org.junit.Test;
import org.junit.runner.RunWith;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;

/** Exercises real platform session publication when artwork/metadata arrives after state. */
@RunWith(AndroidJUnit4.class)
public class MediaControlMetadataTest {
    @Test
    public void nextTrackMetadataRefreshesPlayingStateWithoutPauseResume() throws Exception {
        verifyMetadataPublication(true);
    }

    @Test
    public void lateMetadataPreservesPausedPositionAndControls() throws Exception {
        verifyMetadataPublication(false);
    }

    private static void verifyMetadataPublication(boolean playing) throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        // Supply a real Android session without launching Flutter or replacing
        // the user's queue. Keep its playing or paused mode when metadata arrives.
        AudioService[] services = new AudioService[1];
        MediaSessionCompat[] sessions = new MediaSessionCompat[1];
        instrumentation.runOnMainSync(() -> {
            services[0] = new AudioService();
            sessions[0] = new MediaSessionCompat(
                    instrumentation.getTargetContext(), "metadata-publication-test");
        });
        AudioService service = services[0];
        MediaSessionCompat session = sessions[0];
        setField(service, "mediaSession", session);
        setField(service, "playing", playing);
        MediaControllerCompat controller = session.getController();
        try {
            service.setMetadata(metadata("first", "First song"));
            instrumentation.waitForIdleSync();
            instrumentation.runOnMainSync(() -> setState(service, 0, playing));

            // The Dart state channel can reach Android before the background
            // media worker finishes preparing the next track's artwork.
            instrumentation.runOnMainSync(() -> setState(service, 1, playing));
            service.setMetadata(metadata("second", "Second song"));
            instrumentation.waitForIdleSync();

            assertEquals("Second song", controller.getMetadata().getString(MediaMetadataCompat.METADATA_KEY_TITLE));
            PlaybackStateCompat state = controller.getPlaybackState();
            assertNotNull(state);
            assertEquals(playing ? PlaybackStateCompat.STATE_PLAYING : PlaybackStateCompat.STATE_PAUSED,
                    state.getState());
            assertEquals(1L, state.getActiveQueueItemId());
            assertEquals(6000L, state.getBufferedPosition());
            assertEquals(1.25f, state.getPlaybackSpeed(), 0f);
            if (!playing) assertEquals(2345L, state.getPosition());
            assertEquals(PlaybackStateCompat.ACTION_SKIP_TO_NEXT,
                    state.getActions() & PlaybackStateCompat.ACTION_SKIP_TO_NEXT);
            assertNotNull(state.getExtras());
            assertEquals("second", state.getExtras().getString(MediaConstants.PLAYBACK_STATE_EXTRAS_KEY_MEDIA_ID));
        } finally {
            setField(service, "destroyed", true);
            instrumentation.runOnMainSync(session::release);
        }
    }

    private static void setField(AudioService service, String name, Object value) throws Exception {
        Field field = AudioService.class.getDeclaredField(name);
        field.setAccessible(true);
        field.set(service, value);
    }

    private static MediaMetadataCompat metadata(String id, String title) {
        return new MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID, id)
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "Test artist")
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, 60000)
                .build();
    }

    private static void setState(AudioService service, long index, boolean playing) {
        service.setState(Collections.emptyList(), PlaybackStateCompat.ACTION_SKIP_TO_NEXT,
                new int[0], AudioProcessingState.ready, playing, 2345, 6000, 1.25f,
                SystemClock.elapsedRealtime(), null, null, 0, 0, false, index);
    }
}
