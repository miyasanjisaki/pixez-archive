# Pixiv bookmark visual search integration

This module searches only the bookmarks of the Pixiv account currently selected
in PixEz. It is intentionally separate from SauceNAO, IQDB, Ascii2D, document
plugins, and platform channels.

## Existing-code adapters

- `PixivCurrentUserBookmarkVisualSource` snapshots
  `accountStore.now?.userId`, checks it again before and after every request, and
  requests `/v1/user/bookmarks/illust` for that account and visibility. Search
  callers cannot provide another user ID.
- Pagination never follows `next_url` directly. The parser validates the
  `/v1/user/bookmarks/illust` path, user ID, and public/private restriction,
  extracts only the typed `max_bookmark_id` cursor (or legacy `offset`), then the
  source reissues the request with the selected account ID. Every page request
  forces a cache refresh, has a 30-second overall timeout, and is connected to
  the search cancellation token.
- Public and private pages are polled round-robin: public page 1, private page 1,
  public page 2, private page 2, and so on. Both recent scopes are therefore
  checked before an old public-only collection consumes the global work limit.
- `PixivBookmarkVisualImageFetcher` uses the app's compatible image transport,
  Pixiv referer headers, cancellation, timeouts, a concurrency limit, and a
  default 8 MiB per-image byte limit. Only HTTPS `i.pximg.net` URLs accepted from
  the Pixiv API are downloaded.
- `FlutterBookmarkVisualFingerprintComputer` runs SHA-256 and dHash work through
  Flutter `compute`, keeping image decode work off the UI isolate. Fingerprint
  jobs are serialized so two concurrent downloads cannot also create multiple
  large decoded bitmaps at once.
- `DownloadIdentityBookmarkVisualSink` adapts a confirmed match to the existing
  `DownloadIdentityIndex`. The search service never calls the sink itself.

## Page image selection

- If `meta_pages` is non-empty, every page is queued with its own
  `meta_pages[index].image_urls.medium` and its real page index.
- If `meta_pages` is empty, page 0 uses `illust.image_urls.medium`.
- `large` is only a fallback when `medium` is absent. `square_medium` is never
  used because its crop is unsuitable for whole-image dHash comparison.
- Invisible/deleted works and untrusted image hosts are skipped. Download errors
  are counted and do not prevent a later unique distance-0 candidate from being
  returned for confirmation.

## Suggested SauceStore trigger point

Do not wait for SauceNAO/IQDB to report a final zero-result error. After the
existing filename/PID/local SHA/local dHash checks miss, offer an explicit
`Search my Pixiv bookmarks` action before uploading to any third party. This
search downloads only the signed-in user's Pixiv bookmark previews, but it can
still use substantial bandwidth, so it should remain opt-in and cancellable.

```dart
final controller =
    await PixivBookmarkVisualSearchController.createDefault();
final result = await controller.search(
  queryBytes: selectedBytes,
  queryFileName: selectedName,
  onProgress: updateBookmarkScanProgress,
);
```

When `result.status == BookmarkVisualSearchStatus.matched`, show the returned
`illustId`, page index, visibility, dHash distance, and Pixiv artwork preview.
An early distance-0 result has `scanComplete == false`; it is a strong candidate,
not proof, because dHash collisions are possible. A dHash result is not returned
until both the public and private page for that polling round have been checked;
an exact SHA-256 byte match may return immediately. Only after the user accepts
the displayed Pixiv preview should the UI call:

```dart
await controller.confirmMatch(
  result: result,
  queryBytes: selectedBytes,
  queryFileName: selectedName,
);
```

That explicit call verifies the query SHA again and then writes the existing
identity index. Pass `enableConfirmedIdentityWrites: false` to `createDefault`
when the caller should never persist confirmed matches. Handle `ambiguous`,
`limitReached`, `incomplete`, `cancelled`, and `accountChanged` separately; none
of those states writes the index. Dispose the controller with the owning page.
