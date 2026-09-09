# Distribution

Homebrew is the primary install path: `brew install leoshimo/tap/ditooctl`; update with `brew upgrade leoshimo/tap/ditooctl`. The formula installs a compiled macOS executable. `scripts/install.sh` builds from source when run in the repository, or installs the bundled binary when run in an extracted release. Both default to `~/.local/bin`, without sudo or shell-profile edits. Neither copies pairing metadata or device configuration from another machine.

`./scripts/package.sh 0.1.2` builds a universal Intel/Apple Silicon binary, adds an ad-hoc signature, verifies both architectures, and creates an archive plus SHA-256 file in ignored `dist/`. Verify a downloaded archive with `shasum -a 256 -c ARCHIVE.sha256` before extraction. The executable targets macOS 13+. The local package has been built; testing on the oldest supported OS and Apple notarization are separate from that build. This project has no configured Developer ID or notarization credentials; no quarantine settings are changed by the installer.

## GitHub Actions and Homebrew

The checked-in workflow builds on manual dispatch and version tags. A `v0.1.2` tag must match the binary version in `Sources/ditooctl/Help.swift`. It uploads the universal archive, checksum, and generated `ditooctl.rb` as build artifacts; tagged runs publish a GitHub release. The release job has repository-content write permission only when needed. A source build has no network package dependencies.

To prepare a release locally:

```sh
./scripts/package.sh 0.1.2
./scripts/formula.sh leoshimo/ditooctl 0.1.2 > /path/to/homebrew-tap/Formula/ditooctl.rb
```

The formula points to the versioned archive, uses its real SHA-256, and installs the compiled executable. Publish it in `leoshimo/homebrew-tap`, then other Macs can use:

```sh
brew install leoshimo/tap/ditooctl
brew upgrade leoshimo/tap/ditooctl
```

Publish the version tag first, then use the `ditooctl.rb` attached to that GitHub release to update the tap. CI archives can have different checksums from local archives; the formula must match the exact published archive. Verify the install from the live tap before announcing a release. A single personal tap can hold other small utilities too. Updating it is one formula change per release; a cross-repository token/bot is not required for this first version.

References: [Homebrew tap guide](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap), [GitHub hosted runner selection](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job).
