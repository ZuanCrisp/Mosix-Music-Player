#!/usr/bin/env bash
set -euo pipefail

# SDK binaries are downloaded from the application's Discord Developer Portal,
# not mirrored in this repository. No client secret or bot token is needed.
sdk_source="${1:-${DISCORD_SOCIAL_SDK_DIR:-}}"
if [[ -z "$sdk_source" ]]; then
  echo "Usage: bash scripts/setup_discord_sdk.sh /path/to/discord_social_sdk" >&2
  exit 1
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_target="$repo_root/third_party/spotiflac_discord/sdk"
for sdk_file in include/discordpp.h lib/release/discord_partner_sdk.aar lib/release/discord_partner_sdk.xcframework/Info.plist; do
  if [[ ! -f "$sdk_source/$sdk_file" ]]; then
    echo "Missing SDK file: $sdk_file" >&2
    exit 1
  fi
done
mkdir -p "$sdk_target/android"
cp "$sdk_source/lib/release/discord_partner_sdk.aar" "$sdk_target/"
unzip -oq "$sdk_target/discord_partner_sdk.aar" -d "$sdk_target/android"
mkdir -p "$repo_root/third_party/spotiflac_discord/ios/Frameworks"
cp -R "$sdk_source/lib/release/discord_partner_sdk.xcframework" "$repo_root/third_party/spotiflac_discord/ios/Frameworks/"
cp "$sdk_source/License-Notices.txt" "$sdk_target/"
mkdir -p "$sdk_target/notices"
cp "$sdk_source/License-Notices.txt" "$sdk_target/notices/Discord-License-Notices.txt"
cp "$sdk_source/License-Notices.txt" "$repo_root/third_party/spotiflac_discord/ios/Frameworks/Discord-License-Notices.txt"
cp "$repo_root/third_party/spotiflac_discord/ios/DiscordSimulator.xcconfig" "$repo_root/third_party/spotiflac_discord/ios/Frameworks/"
echo "Discord SDK staged. Run flutter pub get and rebuild both platforms."
