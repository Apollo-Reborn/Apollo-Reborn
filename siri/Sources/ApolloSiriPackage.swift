import AppIntents

/// The proof's types retain their framework module identity when embedded in
/// Apollo. No replacement UIApplication or separately installed app is involved.
public struct ApolloSiriPackage: AppIntentsPackage {
    public init() {}
}
