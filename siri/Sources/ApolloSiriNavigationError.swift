import Foundation

enum ApolloSiriNavigationError: Error, CustomLocalizedStringResourceConvertible {
    case sceneUnavailable
    case routerUnavailable
    case invalidRoute
    case emptyQuery
    case searchUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .sceneUnavailable:
            "Apollo could not open its window. Open Apollo and try again."
        case .routerUnavailable:
            "Apollo Reborn's navigation handler is unavailable. Check that the tweak is loaded and try again."
        case .invalidRoute:
            "Apollo can't open this link."
        case .emptyQuery:
            "Enter something to search for in Apollo."
        case .searchUnavailable:
            "Apollo's native search is unavailable. Close any presented sheet and try again."
        }
    }
}
