# Releasing klabctl

klabctl's version and the Kubernetes version it installs are separate.

- **klabctl** uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The number in [`VERSION`](VERSION) is what GitHub Releases and the PPA track. Tags look like `v0.1.0`.
- **Kubernetes** is chosen at create time with `--k8s-version`. Each klabctl release records the default and the targeted minors.

Releases are cut from `main`. A release is a git tag, the GitHub Release created from the matching section of [`CHANGELOG.md`](CHANGELOG.md), and that same version in [ppa:skalekontrol/klabctl](https://launchpad.net/~skalekontrol/+archive/ubuntu/klabctl). There is no separate binary. GitHub attaches the source archive. The PPA builds the `.deb`.

## SemVer

The project starts at `0.1.0`. While the major version is 0, a minor may still change flags. Call out breaking changes in the changelog.

- **Patch** (`0.1.z`): fixes. The default Kubernetes version stays put.
- **Minor** (`0.y.0`): features, and any move of the Kubernetes window.
- **Major** (`1.0.0` and later): a stable CLI we intend to keep compatible.

## Kubernetes window

Check [Kubernetes releases](https://kubernetes.io/releases/) when cutting a minor.

- Targeted minors are the three upstream patch-supported releases. Today that is `1.35`, `1.36`, and `1.37` (`K8S_SUPPORTED_MINORS` in [`scripts/cluster/create.sh`](scripts/cluster/create.sh)).
- The default is the middle of that window (newest minus one). Today that is `1.36`, so the newest minor stays available through `--k8s-version` before it becomes the default.
- When Kubernetes publishes the next minor, the following klabctl minor adds it, drops the minor that has reached end of life, and slides the default up by one.
- Patch releases of klabctl do not change those numbers.

Move these together:

- `K8S_VERSION` and `K8S_SUPPORTED_MINORS` in [`scripts/cluster/create.sh`](scripts/cluster/create.sh)
- The Kubernetes version section and create help text in [`README.md`](README.md)
- The usage text in [`klabctl.sh`](klabctl.sh) that names the default and targeted minors
- The changelog entry for that release

## Ubuntu series

Users install with:

```bash
sudo add-apt-repository --yes ppa:skalekontrol/klabctl
sudo apt update
sudo apt install klabctl
```

Publish one `X.Y.Z` to every supported series:

| Series | Ubuntu | Role |
| --- | --- | --- |
| noble | 24.04 | Upload target. Oldest supported series. |
| resolute | 26.04 | Copy from Noble after that build is published. |
| stonking | 26.10 | Copy from Noble after that build is published. |
| tenacious | 27.04 | Copy from Noble after that build is published. |

`debian/changelog` names `noble` and the same `X.Y.Z` as [`VERSION`](VERSION). Launchpad accepts each version once, into the series named in that changelog. The copy step puts that version on the other series. A binary built on a newer series cannot be copied onto an older one, so the upload always starts at the oldest series still in this table.

When Ubuntu ends support for a series, stop copying to it. When a new series opens, copy the published package to it.

The first 24.04, 26.10, and 27.04 pockets were opened as `0.1.0+24.04.1`, `0.1.0+26.10.1`, and `0.1.0+27.04.1`. Later releases stay a plain `X.Y.Z`. `0.1.1` sorts newer than those pocket versions.

## Checklist

1. Set [`VERSION`](VERSION) to `X.Y.Z` with no leading `v`.
2. Add `## [X.Y.Z] - YYYY-MM-DD` at the top of [`CHANGELOG.md`](CHANGELOG.md). Include the Kubernetes default and targeted minors in that section.
3. If the Kubernetes window moves, update the files listed above so they name the same default and minors.
4. Set `debian/changelog` to `klabctl (X.Y.Z) noble; urgency=medium`, keeping the existing maintainer identity.
5. Commit on `main`.
6. Tag that commit: `git tag vX.Y.Z`.
7. Push the branch and the tag: `git push origin main` and `git push origin vX.Y.Z`.

Pushing the tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml). The job fails when the tag does not match `VERSION`, then creates a GitHub Release titled `klabctl vX.Y.Z` whose notes are that changelog section. The PPA upload is a separate manual step.

Confirm the release at `https://github.com/SkaleKontrol/klabctl/releases/tag/vX.Y.Z`.

Tags are immutable. Ship a newer patch to correct a release. Do not move or delete a tag that has already been pushed.

## Publish to the PPA

Run this from the tagged commit. Sign with the OpenPGP key registered on the Launchpad account `~skalekontrol` (`Umesh G <gaikwadumesh123@gmail.com>`).

```bash
dpkg-buildpackage -S -d -k01C7A9EF14599910003D9F051E1600068824DA08
dput ppa:skalekontrol/klabctl ../klabctl_X.Y.Z_source.changes
```

`dpkg-buildpackage` writes the source files in the parent directory. Signing needs `devscripts`. `dput` needs the `dput` package. This upload lands on Noble only.

Wait until that version is Published for Noble: <https://launchpad.net/~skalekontrol/+archive/ubuntu/klabctl/+packages>.

Copy that package, including its binaries, from Noble to Resolute, Stonking, and Tenacious. Use [Copy packages](https://launchpad.net/~skalekontrol/+archive/ubuntu/klabctl/+copy-packages) while logged in as `~skalekontrol`. Keep the version as `X.Y.Z`.

`apt upgrade` on a series picks up the new version once that series shows Published.
