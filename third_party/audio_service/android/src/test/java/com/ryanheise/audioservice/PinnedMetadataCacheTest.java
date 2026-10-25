package com.ryanheise.audioservice;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import org.junit.Test;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

public class PinnedMetadataCacheTest {
    @Test
    public void queueLargerThanRecentLimitAndCurrentStayAvailableAfterChurn() {
        PinnedMetadataCache<String> cache = new PinnedMetadataCache<>(2);
        Map<String, String> queue = new HashMap<>();
        for (int i = 0; i < 10; i++) queue.put("queue-" + i, "metadata-" + i);
        cache.setQueue(queue);
        queue.clear();
        cache.setCurrent("playing", "current");
        for (int i = 0; i < 1000; i++) cache.put("browser-" + i, "old");
        for (int i = 0; i < 10; i++) assertEquals("metadata-" + i, cache.get("queue-" + i));
        assertEquals("current", cache.get("playing"));
        assertEquals(2, cache.recentSize());
        cache.setQueue(new HashMap<>());
        assertNull(cache.get("queue-0"));
        cache.clear();
        assertNull(cache.get("playing"));
        assertEquals(0, cache.recentSize());
    }

    @Test
    public void recentBrowserReadsRefreshEvictionOrder() {
        PinnedMetadataCache<String> cache = new PinnedMetadataCache<>(2);
        cache.put("first", "a");
        cache.put("second", "b");
        assertEquals("a", cache.get("first"));
        cache.put("third", "c");
        assertNull(cache.get("second"));
        assertEquals("a", cache.get("first"));
    }

    @Test
    public void concurrentBrowserAndWorkerWritesRemainBounded() throws Exception {
        PinnedMetadataCache<String> cache = new PinnedMetadataCache<>(16);
        cache.setCurrent("playing", "current");
        ExecutorService workers = Executors.newFixedThreadPool(4);
        List<Future<?>> results = new ArrayList<>();
        try {
            for (int i = 0; i < 1000; i++) {
                final String id = "item-" + i;
                results.add(workers.submit(() -> {
                    cache.put(id, id);
                    cache.get(id);
                }));
            }
        } finally {
            workers.shutdown();
        }
        org.junit.Assert.assertTrue(workers.awaitTermination(5, TimeUnit.SECONDS));
        for (Future<?> result : results) result.get();
        assertEquals(16, cache.recentSize());
        assertEquals("current", cache.get("playing"));
    }
}
