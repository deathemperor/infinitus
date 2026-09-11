# AUR packaging

Two packages, one directory each (two PKGBUILDs can't share a dir):

- `claude-swap/` — the engine CLI (builds from PyPI).
- `infinitus-tray-bin/` — the prebuilt bar/panel binary from the GitHub
  release + Waybar config + Omarchy Quickshell plugin (its README has
  the release-time bump steps).

The Infinitus menu bar app itself is macOS-only.

Publishing needs an AUR account and its SSH key:

```sh
git clone ssh://aur@aur.archlinux.org/claude-swap.git aur-claude-swap
cp PKGBUILD aur-claude-swap/ && cd aur-claude-swap
makepkg --printsrcinfo > .SRCINFO
makepkg -si         # build/install test on an Arch box first
git add PKGBUILD .SRCINFO && git commit -m "claude-swap 0.25.0" && git push
```

Note: `python-truststore` may need to come from the AUR itself on a
stock system; `python-textual` is in [extra].
