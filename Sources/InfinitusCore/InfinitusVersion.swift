import Foundation

/// Unified single source of truth for the app version string across platforms.
/// Mac reads CFBundleShortVersionString from Info.plist; Windows binaries and
/// shared utilities read this constant.
public enum InfinitusVersion {
    public static let current = "0.4.3"
}
