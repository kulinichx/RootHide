# RC9 release checks

These checks preserve the existing runtime, license policy, theme behavior and
independent zqbb manager. They do not publish a release or install anything.
Python 3.11+ and Git are sufficient; no third-party Python packages are required.

## Regression checks

From the repository root:

```sh
python -m unittest discover -s tests -v
python tools/manager-trust/test_build.py
```

The first command runs the existing runtime source contracts, new license/theme
source contracts, and package-validator tests with synthetic archives.
The second tests the custom manager packaging tool, not the installed zqbb
manager. Neither command executes UIKit, Security or actual device upgrades.
The existing macOS native regression commands remain in the build workflow.

## Check an existing package

```sh
python tools/release/verify_rc9.py \
  "artifacts/RC9+黑白名单10-30/DopamineRC9_3.0.7-b8358b5_roothide.tipa" \
  --expected-build-id b8358b5544e00450bdcc4234e7fe9e955806ea7e \
  --expected-sha256 d223b09879e0926e35cf91a415e0e7b5da871978358931b8e02991c21077492c \
  --output artifacts/release-readiness-20261102/rc9-package-identity.json
```

Use the actual Python executable if `python` is a Windows Store alias.
For another candidate, supply its exact immutable build ID and known package
hash. The filename is not used as evidence of version or identity.

The checker reads archives in memory without extracting or rewriting them.
It verifies the expected Bundle ID, app version, minimum OS, basebin version
and `BaseBinBuildID`; an expected SHA-256, when supplied, must match.
It records hashes of the app executable, five runtime components and bundled
Debian resources, plus current source fingerprints and Git status.
Missing required files, duplicate archive members, malformed metadata and
identity mismatches fail the check with a nonzero exit code.

Reports distinguish current HEAD, uncommitted changes and package build ID.
`artifact_checks_passed` covers only package identity. `release_approval` stays
`not_assessed`; a Git diff or matching hash does not prove a reproducible build,
valid Apple signature, iOS loading behavior, or safe downgrade.

The build workflow runs source tests before native regressions and verifies a
full TIPA against `GITHUB_SHA` before uploading it with the JSON report. Changes
to the workflow have to reach the remote repository before these steps run.
The independent manager's actually installed version and device acceptance
remain in the release checklist, not inferred from bundled resources.

See `docs/rc9-selective-fixes-20261104.md` for this candidate's scope,
baseline evidence and manual acceptance checks.
