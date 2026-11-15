#!/bin/sh

set -eu

# Build the real v.redd.it master playlist recovery helpers (Foundation-only)
# as a macOS executable and check them against the manifests and playlists
# captured from v.redd.it for issues #1698 #1714 #1716 #1720 #1721.
test_repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-reddit-video-playlist-tests.XXXXXX")
test_binary="$test_build_dir/reddit_video_playlist_tests"
trap 'rm -rf -- "$test_build_dir"' EXIT HUP INT TERM

xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fsanitize=address,undefined -framework Foundation \
    -I "$test_repo_root/src" \
    "$test_repo_root/src/ApolloRedditVideoPlaylist.m" \
    "$test_repo_root/tests/reddit_video_playlist_tests.m" \
    -o "$test_binary"

"$test_binary" "$test_repo_root/tests/fixtures/reddit_video"
