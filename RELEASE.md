# Release Process

How to cut a release of this distribution (`extension_drop`, name from
`META.json`'s top-level `name` field) and publish it to PGXN. Written to be
followed standalone, without other context.

## Overview

Releases use pgxntool's built-in `make tag`/`make dist` mechanics to produce a
`.zip`. There is currently **no CI automation for publishing** — the zip must
be uploaded to PGXN Manager by hand. See "Future: CI automation" below for the
planned upgrade path.

## Ongoing development (every PR, between releases)

Keep the next release ready to cut at any time:

- If a PR makes a user-facing change (bug fix, behavior change, new/changed
  function, etc. — CI config, docs-for-contributors, and other internal-only
  changes don't count), add an entry to `HISTORY.asc` at the repo root:
  - If the file's top section is already headed `STABLE`, add your
    `== <heading>` block to it.
  - If the top section is a real version number (nothing has changed since
    the last release yet), insert a new section above it headed `STABLE`
    (dashes: `------`, 6 characters) with your entry.
- If a PR changes an extension's SQL (`sql/<ext>.sql`), also maintain the
  upgrade script from the last released version to `stable`:
  `sql/<ext>--<last-released-version>--stable.sql`. Create it if it doesn't
  exist yet (first SQL-touching PR since the last release). Every subsequent
  PR that changes that extension's SQL adds whatever `ALTER ...`/
  `CREATE OR REPLACE ...` statements are needed to bring an existing install
  on the last released version up to your changes.

This way, a release is just renaming things — see step 2 below — not writing
a changelog or an upgrade path from scratch under time pressure.

## Cutting a release

1. Make sure `master` is in the state you want released, and CI is green.
   **Caveat:** as of this writing, CI passing doesn't actually mean the test
   suite passed — see "CI doesn't fail on test failures" below. Until that's
   fixed, also eyeball the actual `pg_regress` output in the CI logs (or run
   `make test` locally), not just the green checkmark.

2. Rename the accumulated `STABLE` markers to the real version number:
   - Edit `META.in.json`: bump the top-level `version` field AND the matching
     `version` under `provides.<extension>.version`. Do **not** touch
     `meta-spec.version` — that's the PGXN metadata spec version, always
     `1.0.0` regardless of your distribution's version.
   - Edit `<extension>.control`: bump `default_version` to match.
   - In `HISTORY.asc`, rename the top `STABLE` heading to the new version
     number, and its dashes line to match the new heading's length.
   - `git mv sql/<ext>--<last-released-version>--stable.sql` to
     `sql/<ext>--<last-released-version>--<new-version>.sql`.
   - Run `make META.json` (no need to `rm` it first — make only rebuilds it
     when `META.in.json` is newer). It's a derived file — never hand-edit it
     directly (see `META.in.json` vs `META.json` in `pgxntool/CLAUDE.md`).
   - Run `make test` as a final check before committing — this also
     exercises the `META.json` regeneration as part of the normal build.

3. Commit the version bump + changelog + renamed upgrade script together in
   one commit. Message convention used by this project:
   `"<version>: <one-line summary>"` (e.g. `"1.1.0: Add foo() function"`).

4. Make sure your `origin` git remote points at the canonical upstream repo
   (`Postgres-Extensions/extension_tools`, not a personal fork) —
   `make tag` pushes to whatever `origin` is, and a tag pushed to a fork does
   nothing for PGXN.

5. Run `make dist`. This:
   - Refuses to run with uncommitted changes.
   - Creates (or verifies) a git tag matching `PGXNVERSION` — the bare version
     number, e.g. `1.0.0`, no `v` prefix, matching this project's convention
     (check `meta.mk` if unsure what `PGXNVERSION` resolved to) — and pushes
     it to `origin`.
   - Runs `git archive` at that tag into `../<dist-name>-<version>.zip` (e.g.
     `../extension_drop-1.0.0.zip`).
   - If you need to redo a release before anyone's downloaded it:
     `make forcedist` (deletes + recreates the tag, rebuilds the zip). Don't
     do this once the version has been public for a while — moving a
     published tag out from under people is disruptive.

   Before running this, check `Postgres-Extensions/pgxntool`'s open issues
   labeled `make dist` — several `make dist` gaps found while writing this
   doc were filed there instead of fixed by hand each release (version
   consistency, `META.json` freshness, URL reachability, and more may
   accumulate over time). Review whether any open issue there affects this
   release before proceeding.

6. Upload the zip at https://manager.pgxn.org/ (log in, use the release form).
   You need a registered PGXN Manager account with rights to this
   distribution.

7. Verify the new version shows up at `https://pgxn.org/dist/<name>/` (can
   take a few minutes to index).

## Future: CI automation

Right now this is entirely manual. The `pgtap` extension (a sibling project,
not part of this org) has a `.github/workflows/release.yml` that
auto-publishes to PGXN on tag push, using the `pgxn/pgxn-tools` Docker image
(`pgxn-bundle` + `pgxn-release` steps), and auto-creates a GitHub release from
the changelog. Adopting the same pattern here would remove steps 5-6 above,
but requires storing PGXN Manager credentials as a GitHub Actions secret —
deliberately deferred for this release.

## Notes / gotchas discovered while writing this

- pgxntool's own `make tag`/`make dist` create a *real* git tag, despite
  `pgxntool/README.asc` describing the result as a "branch" — that's stale
  wording in the docs, not current behavior (filed upstream to get fixed).
- **CI doesn't fail on test failures.** `pgxntool/base.mk` has
  `.IGNORE: installcheck`, so `make test`/`make installcheck` always report
  success to `make` regardless of the actual `pg_regress` result — a run
  with every test failing still shows green in GitHub Actions. Confirmed
  live: PRs #6 and #7 both had every `pg_regress` test fail
  (`cat_tools.routine__parse_arg_types_text` doesn't exist in any released
  `cat_tools`; that name only exists on cat_tools' unreleased 0.3.0 branch)
  while every CI job reported `"conclusion":"success"`. Filed upstream as
  Postgres-Extensions/pgxntool#49; the `cat_tools` call in
  `sql/extension_drop.sql` also needs fixing here before this distribution
  can actually be released.
