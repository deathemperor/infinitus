# AUR packaging

One package:

- `infinitus-tray-bin/` — the prebuilt bar/panel binary from the GitHub
  release + Waybar config + Omarchy Quickshell plugin (its README has
  the release-time bump steps).

The Infinitus menu bar app itself is macOS-only.

Publishing needs an AUR account and its SSH key:

```sh
git clone ssh://aur@aur.archlinux.org/infinitus-tray-bin.git aur-infinitus-tray-bin
cp infinitus-tray-bin/PKGBUILD aur-infinitus-tray-bin/ && cd aur-infinitus-tray-bin
makepkg --printsrcinfo > .SRCINFO
makepkg -si         # build/install test on an Arch box first
git add PKGBUILD .SRCINFO && git commit -m "infinitus-tray-bin <version>" && git push
```
