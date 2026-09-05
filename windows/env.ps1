# Swift 6.3.3 on this box: the installer registers the user PATH, but shells
# opened before the install (and CI) miss it, and swiftc needs the Windows
# SDK location. Dot-source it, never run it:
#   . .\windows\env.ps1
# Paths per docs/plan-windows/01-stack.md.
$env:Path = "C:\Users\BM\AppData\Local\Programs\Swift\Toolchains\6.3.3+Asserts\usr\bin;" +
            "C:\Users\BM\AppData\Local\Programs\Swift\Runtimes\6.3.3\usr\bin;" + $env:Path
$env:SDKROOT = "C:\Users\BM\AppData\Local\Programs\Swift\Platforms\6.3.3\Windows.platform\Developer\SDKs\Windows.sdk\"
# Never set INCLUDE or LIB here: with either present the Swift toolchain
# skips MSVC auto-detection and even its own manifest compiles fail
# ('errno.h' file not found). Windows' zlib need is met by the vendored
# windows/Sources/CZlib target in Package.swift instead.
