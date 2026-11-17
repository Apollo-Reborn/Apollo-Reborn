#!/bin/sh
set -eu

# Every summary request names the summary language twice: leading the
# instructions ("You MUST respond in English.") and again after the text
# ("Write the summary in English."). The instructions line alone lost to long
# foreign-script input on the on-device model (Arabic arriyadiyah.com link
# summaries came back in Arabic under an English device), so a new summarize
# call that skips the closing line would bring that back.

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$test_root/src/ApolloAISummary.xm"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

require_count() {
    pattern=$1
    expected=$2
    description=$3
    actual=$(grep -F -c "$pattern" "$source_file" || true)
    [ "$actual" -eq "$expected" ] || fail "$description (expected $expected, found $actual)"
}

# All three generation paths (post, link/article/post-and-link, comments).
require_count '[bridge summarize:' 3 \
    'summary generation still has exactly three bridge calls'
require_count '[bridge summarize:ApolloAIPromptInSummaryLanguage(' 3 \
    'every bridge summarize call closes its text with the summary language'

# The closing line uses the same language name as the leading one, and leaves
# the text alone when no language is named.
require_count 'NSString *name = ApolloAISummaryLanguageName();' 2 \
    'instructions and prompt read one shared language name'
grep -F -q 'if (name.length == 0 || text.length == 0) return text;' "$source_file" ||
    fail 'no summary language leaves the text unchanged'
grep -F -q '@"%@\n\nWrite the summary in %@."' "$source_file" ||
    fail 'the text ends with the summary language line'

# On-device summaries cached under the old prompt regenerate once; the profile
# without a language is unchanged.
grep -F -q 'static NSString *const kApolloAIOnDevicePromptRevision = @"2";' "$source_file" ||
    fail 'on-device prompt revision is declared'
grep -F -q '[NSString stringWithFormat:@"apple|%@|%@", language, kApolloAIOnDevicePromptRevision]' "$source_file" ||
    fail 'on-device profile carries the prompt revision'
grep -F -q ': @"apple|";' "$source_file" ||
    fail 'on-device profile without a language stays "apple|"'

echo "ai_summary_language_prompt_check passed"
