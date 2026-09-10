/// The version `infinitus-tray` reports (#486): "dev" in a working tree,
/// the tag's number in a release build — `release.yml` stamps it into
/// this file before `swift build`, the way `make-app.sh` stamps
/// `VERSION` into the Mac's Info.plist.
enum BuiltVersion {
    static let string = "dev"
}
