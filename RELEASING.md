# Releasing klabctl

klabctl's version and the Kubernetes version it installs are separate.

- **klabctl** uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The number in [`VERSION`](VERSION) is what GitHub Releases track. Tags look like `v0.1.0`.
- **Kubernetes** is chosen at create time with `--k8s-version`. Each klabctl release records the default and the targeted minors.

Releases are cut from `main`. A release is a git tag plus the GitHub Release created from the matching section of [`CHANGELOG.md`](CHANGELOG.md). There is no separate binary. GitHub attaches the source archive.

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

## Checklist

1. Set [`VERSION`](VERSION) to `X.Y.Z` with no leading `v`.
2. Add `## [X.Y.Z] - YYYY-MM-DD` at the top of [`CHANGELOG.md`](CHANGELOG.md). Include the Kubernetes default and targeted minors in that section.
3. If the Kubernetes window moves, update the files listed above so they name the same default and minors.
4. Commit on `main`.
5. Tag that commit: `git tag vX.Y.Z`.
6. Push the branch and the tag: `git push origin main` and `git push origin vX.Y.Z`.

Pushing the tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml). The job fails when the tag does not match `VERSION`, then creates a GitHub Release titled `klabctl vX.Y.Z` whose notes are that changelog section.

Confirm the release at `https://github.com/SkaleKontrol/klabctl/releases/tag/vX.Y.Z`.

Tags are immutable. Ship a newer patch to correct a release. Do not move or delete a tag that has already been pushed.
