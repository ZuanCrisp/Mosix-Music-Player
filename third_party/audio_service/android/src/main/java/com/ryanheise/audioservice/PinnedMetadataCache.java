package com.ryanheise.audioservice;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

/** Keeps current/queue items while bounding metadata retained from older browsers. */
final class PinnedMetadataCache<T> {
    private final int recentLimit;
    private final Map<String, T> recent = new LinkedHashMap<>(16, 0.75f, true);
    private Map<String, T> queue = new HashMap<>();
    private String currentId;
    private T current;

    PinnedMetadataCache(int recentLimit) {
        if (recentLimit < 1) throw new IllegalArgumentException("recentLimit must be positive");
        this.recentLimit = recentLimit;
    }

    synchronized void put(String id, T metadata) {
        recent.put(id, metadata);
        while (recent.size() > recentLimit) {
            recent.remove(recent.keySet().iterator().next());
        }
    }

    synchronized T get(String id) {
        if (id != null && id.equals(currentId)) return current;
        T metadata = queue.get(id);
        return metadata != null ? metadata : recent.get(id);
    }

    synchronized void setCurrent(String id, T metadata) {
        currentId = id;
        current = metadata;
    }

    synchronized void setQueue(Map<String, T> metadata) {
        queue = new HashMap<>(metadata);
    }

    synchronized void clear() {
        recent.clear();
        queue.clear();
        currentId = null;
        current = null;
    }

    synchronized int recentSize() {
        return recent.size();
    }
}
