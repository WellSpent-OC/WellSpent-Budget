/// A feature the server drives, turned on per environment by a variable set to
/// "on". Anything else, unset included, is off, so live keeps today's
/// behavior until a release train turns the feature on.
enum ServerSwitch {
    static func isOn(_ variable: String?) -> Bool { variable == "on" }
}
