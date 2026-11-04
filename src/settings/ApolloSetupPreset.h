#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloSetupState) {
    ApolloSetupStatePending = 1,
    ApolloSetupStateCompleted,
    ApolloSetupStateSkipped,
    ApolloSetupStateExistingInstall,
};

typedef NS_ENUM(NSInteger, ApolloSetupAppearance) {
    ApolloSetupAppearanceUnchanged = -1,
    ApolloSetupAppearanceSystem = 0,
    ApolloSetupAppearanceLight,
    ApolloSetupAppearanceDark,
};

// Foundation-only policy shared by the UI, summary, and host tests.
@interface ApolloSetupPreset : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *subtitle;
@property (nonatomic, copy, readonly) NSArray<NSString *> *highlights;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *values;
+ (NSArray<ApolloSetupPreset *> *)allPresets;
+ (nullable instancetype)presetWithIdentifier:(nullable NSString *)identifier;
@end

__BEGIN_DECLS
// Pass persistent domains, never dictionaryRepresentation (registered defaults
// make a fresh install look configured). Unknown lifecycle values fail closed.
ApolloSetupState ApolloSetupInitialState(NSDictionary *mainDomain, NSDictionary *groupDomain);
NSDictionary<NSString *, id> *ApolloSetupMainAppearanceValues(ApolloSetupAppearance appearance);
NSDictionary<NSString *, id> *ApolloSetupGroupAppearanceValues(ApolloSetupAppearance appearance);
// Writes only keys in values; returns whether their effective values changed.
BOOL ApolloSetupWriteValues(NSUserDefaults *defaults, NSDictionary<NSString *, id> *values);
__END_DECLS

NS_ASSUME_NONNULL_END
