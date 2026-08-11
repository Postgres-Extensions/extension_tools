# Release Process

See [`../ai/RELEASE.md`](../ai/RELEASE.md) for the shared
Postgres-Extensions release process (versioning, `make tag`/`make dist`,
the `stable` pseudo-version, manual PGXN upload). This file covers only
what's genuinely specific to this repo.

## Critical: never cut a release while CI needs a git-source dependency override

`../ai/RELEASE.md`'s pre-release checks and "Notes / gotchas" section cover
the generic version of this warning (check any dependency-override toggle
is unset before releasing). The concrete instance affecting this repo:
`.github/workflows/ci.yml` sets `CAT_TOOLS_GIT_REF: 0.3.0` at the workflow
level, because PGXN's published `cat_tools` (a stale 2017 release) doesn't
have the function `sql/extension_drop.sql` calls
(`cat_tools.routine__parse_arg_types_text`), so it can't satisfy
`META.in.json`'s declared `cat_tools` dependency floor. While that's true,
cutting a release produces a real, publishable zip that can't actually be
built by anyone who installs it via a plain `pgxn install`.

**Before starting the shared release process**, check whether `ci.yml`
still sets `CAT_TOOLS_GIT_REF` (or `CAT_TOOLS_SKIP_INSTALL`) to a
non-empty value. If it does, stop — wait for cat_tools 0.3.0 (or later) to
actually land on PGXN, and revert `ci.yml`'s override back to unset,
before proceeding. Check `ci.yml`'s actual value, not just whether the
`Makefile`'s `cat_tools` target *supports* the override — `CAT_TOOLS_GIT_REF`
and `CAT_TOOLS_SKIP_INSTALL` always exist there now as normally-empty,
opt-in mechanisms; their mere existence doesn't mean anything is currently
pinned.
