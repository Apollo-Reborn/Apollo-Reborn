// ApolloPointerIvarSlot: the tweak's link router writes Apollo's
// AppDelegate.tabBarController through it (ApolloRouteURLThroughAppInScene).
// The slot must resolve on Apollo's class, for the delegate itself and for a
// runtime subclass such as the GUL_ proxy Firebase's GoogleUtilities swaps an
// older Apollo's delegate onto (issue #1529), and never for anything else.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ApolloSwiftRuntime.h"

static int failures = 0;

static void Expect(BOOL condition, NSString *message) {
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    }
}

static Class MakeClass(Class superclass, const char *name, const char *const *ivars, const size_t *sizes, size_t count) {
    Class cls = objc_allocateClassPair(superclass, name, 0);
    for (size_t i = 0; i < count; i++) {
        class_addIvar(cls, ivars[i], sizes[i], 3, "^v");
    }
    objc_registerClassPair(cls);
    return cls;
}

static void *SlotOf(id object, Class owner, const char *name) {
    return (uint8_t *)(__bridge void *)object + ivar_getOffset(class_getInstanceVariable(owner, name));
}

int main(void) {
    @autoreleasepool {
        const char *apolloIvars[] = { "window", "tabBarController", "apolloProProducts", "tipProducts" };
        const size_t word[] = { sizeof(void *), sizeof(void *), sizeof(void *), sizeof(void *) };
        Class apollo = MakeClass(NSObject.class, "TestApolloAppDelegate", apolloIvars, word, 4);

        // The delegate as Apollo 1.15.11 runs it.
        id plain = [apollo new];
        Expect(ApolloPointerIvarSlot(plain, "TestApolloAppDelegate", "tabBarController", "apolloProProducts") ==
                   SlotOf(plain, apollo, "tabBarController"),
               @"plain delegate resolves its tabBarController slot");

        // GoogleUtilities' proxy: same-size subclass, isa swapped, no -class
        // override. isMemberOfClass: is what 4.0.0 checked, and it fails here.
        Class gul = MakeClass(apollo, "GUL_TestApolloAppDelegate-6C2B", NULL, NULL, 0);
        id proxied = [apollo new];
        object_setClass(proxied, gul);
        Expect(![proxied isMemberOfClass:apollo], @"the GUL_ proxy is not a member of Apollo's class");
        Expect(ApolloPointerIvarSlot(proxied, "TestApolloAppDelegate", "tabBarController", "apolloProProducts") ==
                   SlotOf(proxied, apollo, "tabBarController"),
               @"GUL_ proxied delegate resolves Apollo's tabBarController slot");

        // A subclass declaring its own ivar of the same name must not win.
        const char *shadowIvars[] = { "tabBarController", "apolloProProducts" };
        Class shadow = MakeClass(apollo, "TestShadowingSubclass", shadowIvars, word, 2);
        id shadowed = [shadow new];
        Expect(ApolloPointerIvarSlot(shadowed, "TestApolloAppDelegate", "tabBarController", "apolloProProducts") ==
                   SlotOf(shadowed, apollo, "tabBarController"),
               @"a shadowing subclass ivar is ignored");

        // Same ivar names on a class outside Apollo's family.
        Class other = MakeClass(NSObject.class, "TestUnrelatedDelegate", apolloIvars, word, 4);
        Expect(ApolloPointerIvarSlot([other new], "TestApolloAppDelegate", "tabBarController", "apolloProProducts") == NULL,
               @"an unrelated delegate is rejected");

        // tabBarController wider than one word: the layout isn't the verified one.
        const size_t wide[] = { sizeof(void *), 2 * sizeof(void *), sizeof(void *), sizeof(void *) };
        Class wideClass = MakeClass(NSObject.class, "TestWideDelegate", apolloIvars, wide, 4);
        Expect(ApolloPointerIvarSlot([wideClass new], "TestWideDelegate", "tabBarController", "apolloProProducts") == NULL,
               @"a non-pointer-wide slot is rejected");

        // Following ivar declared before the slot.
        const char *swappedIvars[] = { "window", "apolloProProducts", "tabBarController", "tipProducts" };
        Class swapped = MakeClass(NSObject.class, "TestSwappedDelegate", swappedIvars, word, 4);
        Expect(ApolloPointerIvarSlot([swapped new], "TestSwappedDelegate", "tabBarController", "apolloProProducts") == NULL,
               @"a reordered layout is rejected");

        Expect(ApolloPointerIvarSlot(plain, "TestApolloAppDelegate", "tabBarController", "missingIvar") == NULL,
               @"a missing following ivar is rejected");
        Expect(ApolloPointerIvarSlot(plain, "TestMissingClass", "tabBarController", "apolloProProducts") == NULL,
               @"a missing class is rejected");
        Expect(ApolloPointerIvarSlot(nil, "TestApolloAppDelegate", "tabBarController", "apolloProProducts") == NULL,
               @"nil is rejected");
    }

    if (failures) {
        fprintf(stderr, "app_delegate_route_slot_tests: %d failure(s)\n", failures);
        return 1;
    }
    printf("app_delegate_route_slot_tests passed\n");
    return 0;
}
