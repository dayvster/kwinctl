# AUR package

[`kwinctl`](kwinctl/PKGBUILD) builds a release tag from source with Zig (`ReleaseSmall`, baseline
x86-64) and runs the unit tests in `check()`. It installs the single static binary, the README
and the licence.

## Publishing for the first time

1. Add your SSH public key on the AUR: My Account, SSH Public Key.
2. Clone the empty AUR repository, add the files and push:

   ```sh
   git clone ssh://aur@aur.archlinux.org/kwinctl.git /tmp/aur-kwinctl
   cp packaging/aur/kwinctl/PKGBUILD packaging/aur/kwinctl/.SRCINFO /tmp/aur-kwinctl/
   cd /tmp/aur-kwinctl
   git add PKGBUILD .SRCINFO
   git commit -m "Initial import: kwinctl 0.1.0"
   git push
   ```

## Releasing a new version

After tagging `vX.Y.Z` and pushing the tag:

```sh
cd packaging/aur/kwinctl
sed -i 's/^pkgver=.*/pkgver=X.Y.Z/; s/^pkgrel=.*/pkgrel=1/' PKGBUILD
updpkgsums                          # from pacman-contrib: refreshes sha256sums
makepkg -f                          # builds it, which also checks the new checksum
makepkg --printsrcinfo > .SRCINFO
```

Commit the change here, then copy `PKGBUILD` and `.SRCINFO` into the AUR clone and push as above.
`updpkgsums` downloads the source tarball next to the PKGBUILD; the `.gitignore` here keeps it
and makepkg's build output out of commits.
