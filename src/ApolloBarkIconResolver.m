#import "ApolloBarkIconResolver.h"
#import "generated/ApolloBarkIconNames.gen.h"

static NSSet<NSString *> *ApolloBarkHostedIconNames(void) {
    static NSSet<NSString *> *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithObjects:ApolloBarkHostedIconNameList
                                count:ApolloBarkHostedIconNameCount];
    });
    return names;
}

NSString *ApolloBarkResolvedHostedIconName(id selectedName) {
    if ([selectedName isKindOfClass:NSString.class] &&
        [(NSString *)selectedName length] > 0 &&
        [ApolloBarkHostedIconNames() containsObject:selectedName]) {
        return selectedName;
    }
    return @"default";
}
