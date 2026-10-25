# Local Android audio patch

Based on audioplayers_android 5.3.0 (license retained in LICENSE).

`UrlSource` duplicates app-owned `/proc/self/fd/<fd>` sources and passes the
descriptor directly to MediaPlayer. Android AppFuse proxies, including remote
SAF providers, permit only the original open; reopening the proc path fails.
The caller must hold the original lease until source preparation completes.
Other URLs and file paths retain upstream behavior.
