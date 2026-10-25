# Artist concerts

Any metadata extension can include an optional `concerts` list in `getArtist`
or the `artist` object returned by `handleUrl`. The native metadata bridge
preserves it as `artist_info.concerts` or `artist.concerts`, respectively.
Older extensions may omit it; no concert button is shown for an empty list.

```json
{
  "concerts": [{
    "id": "event-123",
    "location": "Example City, Region",
    "venue": "Example Hall",
    "start_at": "2026-10-07T01:00:00Z",
    "time_zone": "America/New_York",
    "detail_id": "event-123",
    "url": "https://example.com/events/123"
  }]
}
```

- `location` and a valid ISO 8601 `start_at` are required. Date-only values
  (`2026-10-06`) are supported when a time has not been announced.
- For UTC timestamps, supply the venue's IANA `time_zone`; the example above
  displays **October 6 at 21:00**, regardless of the listener's device time zone.
  Explicit offsets are also supported. Without a recognized time zone, the app
  preserves the wall-clock fields supplied in `start_at`.
- `id`, `venue`, and `url` are optional. The app deduplicates by event ID (or
  date/location/venue), orders events by date, and accepts at most 500 entries.
- Tapping an event opens its internal detail page. Only explicit ticket and map
  actions open external HTTP(S) links; the event URL is used for sharing.
- Providers should return upcoming events only. Failure to fetch this optional
  information must not fail the artist's albums or top tracks.

The badge opens a native schedule with artist identity, venue-local date tiles,
and event details. Labels are provider-neutral in both application themes.
Concert metadata is supplied with the artist response, so the schedule opens
immediately without a second loading state or network request.

The schedule follows the application's light/dark theme. The detail page uses
the artist portrait's palette and light text in either theme, including its
loading placeholders. Any metadata extension can implement `getConcert(id)`
and supply `detail_id` on its events. The app requests it only when opening an
event through `getProviderMetadata(provider, "concert", detail_id)`, receiving
the generic `concert` envelope. Older providers without `detail_id` still open
a detail page with the schedule's date and venue.

```json
{
  "id": "event-123",
  "artist_name": "Example Artist",
  "title": "Example Tour",
  "cover_url": "https://example.com/artist.jpg",
  "start_at": "2026-10-07T01:00:00Z",
  "end_at": "2026-10-07T04:00:00Z",
  "time_zone": "America/New_York",
  "venue": "Example Hall",
  "address": "123 Example Street",
  "ticket_url": "https://example.com/tickets/123",
  "map_url": "https://example.com/maps/123",
  "url": "https://example.com/events/123",
  "attribution": "Powered by Example Events",
  "set_list": {
    "id": "playlist-123",
    "name": "Example Tour Set List",
    "cover_url": "https://example.com/set-list.jpg"
  }
}
```

All detail fields are optional. Omit unavailable actions instead of fabricating
links. Set lists open the existing internal playlist screen using the same
metadata provider. Calendar actions present a system editor for the user to
review and save; no event is added automatically. iOS 17+ needs no calendar
read permission; iOS 16 requests legacy permission. Android uses an insert
intent. Failed detail requests leave the date and venue visible with Retry.
