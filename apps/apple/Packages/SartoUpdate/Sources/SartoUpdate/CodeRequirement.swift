import Foundation

public enum UpdateRequirement {
    /// What a new app's code signature must satisfy: this app's bundle identifier, under a
    /// certificate Apple issued to this app's team. Any of the team's certificates passes, so a
    /// build signed for development updates to one signed with Developer ID without a reinstall,
    /// while nobody outside the team can sign an update. Nil when the running app has no team,
    /// as an ad-hoc build, which then holds updates to its designated requirement.
    public static func text(bundleIdentifier: String, teamIdentifier: String?) -> String? {
        guard let team = teamIdentifier,
              team.count == 10,
              team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              (1...255).contains(bundleIdentifier.count),
              bundleIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
