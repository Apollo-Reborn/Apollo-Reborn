#!/bin/sh
set -eu

unset CDPATH
test_repo_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
test_source="$test_repo_root/src/ApolloHiddenContentMenu.xm"

fail() {
    printf 'hidden_content_adapter_scope_tests: %s\n' "$1" >&2
    exit 1
}

# The Hidden & Deleted shortcut is implemented by replacing a profile row's
# Texture node factory. Apollo's ListAdapter class is shared by feeds and other
# lists, whose Swift factories must be returned without an extra wrapper.
profile_lookup_line=$(grep -n -F 'UIViewController *profileController = ApolloHiddenProfileControllerForAdapter(self' "$test_source" | cut -d: -f1)
scope_guard_line=$(grep -n -F 'if (!profileController) return originalBlock;' "$test_source" | cut -d: -f1)
wrapper_line=$(grep -n -F 'return [^id {' "$test_source" | cut -d: -f1)

[ -n "$profile_lookup_line" ] || fail 'profile lookup is missing from the ListAdapter hook'
[ -n "$scope_guard_line" ] || fail 'non-profile adapters are still wrapped'
[ -n "$wrapper_line" ] || fail 'profile node wrapper is missing'
[ "$profile_lookup_line" -lt "$scope_guard_line" ] || fail 'scope guard must follow profile resolution'
[ "$scope_guard_line" -lt "$wrapper_line" ] || fail 'scope guard must run before creating the wrapper block'
grep -F 'UIViewController *owner = ApolloReadSwiftWeakObjectIvar(adapter, "viewController");' "$test_source" >/dev/null || \
    fail 'ListAdapter weak owner is not the primary scope signal'
grep -F 'return [owner isKindOfClass:profileClass] ? owner : nil;' "$test_source" >/dev/null || \
    fail 'attached non-profile adapters must fail closed'
if grep -F 'for (UIWindow *window in [ApolloAllWindows() reverseObjectEnumerator])' "$test_source" >/dev/null; then
    fail 'global visible-profile fallback can misclassify background adapters'
fi

printf '%s\n' 'hidden_content_adapter_scope_tests passed'
