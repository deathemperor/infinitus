# infinitus-tray-bin (AUR)

Prebuilt `infinitus-tray` from the GitHub release, plus the Waybar
config and the Omarchy Quickshell plugin under `/usr/share/infinitus/`.
After install, enable the Omarchy panel with:

```sh
cp -r /usr/share/infinitus/quickshell-plugin/infinitus \
      ~/.config/omarchy/plugins/infinitus
# then add { "id": "infinitus.fleet" } to bar.layout in ~/.config/omarchy/shell.json
```

## Release-time bump (manual, per release)

CI rebuilds the binaries on every tag, so checksums MUST be regenerated
from the published assets — never from a local build:

```sh
cd packaging/aur/infinitus-tray-bin
sed -i "s/^pkgver=.*/pkgver=NEW_VERSION/" PKGBUILD
updpkgsums                      # downloads the release assets, fills sums
makepkg --printsrcinfo > .SRCINFO
makepkg -si                     # install test on an Arch box
```

Publishing needs the maintainer's AUR account and SSH key:

```sh
git clone ssh://aur@aur.archlinux.org/infinitus-tray-bin.git aur-pkg
cp PKGBUILD .SRCINFO aur-pkg/ && cd aur-pkg
git add -A && git commit -m "infinitus-tray-bin NEW_VERSION" && git push
```
