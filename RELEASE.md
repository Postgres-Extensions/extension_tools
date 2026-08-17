# Release Process

See [`../ai/RELEASE.md`](../ai/RELEASE.md) for the shared
Postgres-Extensions release process. This file covers only what's genuinely
specific to this repo.

## Git-pinned dependencies are enforced by CI, not just by convention

CI's `release-safety` job fails the build if `default_version` is a real
version (i.e. cutting a release) while `CAT_TOOLS_GIT_REF` or
`CAT_TOOLS_SKIP_INSTALL` is set at the workflow level (`bin/in_release` +
`.github/workflows/ci.yml`). This is the automated form of `../ai/RELEASE.md`'s
"no dependency-override toggle" pre-release check for this repo's one
current override; if this repo grows another such override later, extend
the same job rather than trusting the manual check alone.
