# Release Process

See [`../ai/RELEASE.md`](../ai/RELEASE.md) for the shared
Postgres-Extensions release process. This file covers only what's genuinely
specific to this repo.

## Critical: never cut a release while CAT_TOOLS_GIT_REF/CAT_TOOLS_SKIP_INSTALL is set

Check `.github/workflows/ci.yml`'s top-level `env:` before starting
`../ai/RELEASE.md`'s process. If `CAT_TOOLS_GIT_REF` or
`CAT_TOOLS_SKIP_INSTALL` is non-empty there, stop and revert it first.

Why: these make the Makefile's `cat_tools` target build from a git ref
instead of PGXN, normally because PGXN's published `cat_tools` doesn't yet
satisfy `META.in.json`'s declared floor. A release cut while either is set
produces a real, publishable zip that a plain `pgxn install` can't actually
build, since the dependency it declares isn't resolvable that way.

CI's `release-safety` job (`bin/in_release` + `.github/workflows/ci.yml`)
hard-fails automatically if this combination ever occurs, but check by hand
too before starting -- don't rely on the automated gate alone to catch it
after the fact.
