# CLAUDE.md

## Git workflow: trunk-based

- Merging straight to `main` is allowed and preferred; no pull request is
  needed unless asked for.
- Before updating `main`, wait for the App workflow (`.github/workflows/app.yml`)
  to pass on the branch, then fast-forward `main` to it
  (`git push origin <branch>:main`). Don't force-push `main`.
- If `main` has moved on, rebase the branch onto it first and wait for the
  workflow again.
- The workflow skips pushes that only touch `firmware/`, `zephyr/` or `.md`
  files; for those the last run on the branch is the one that counts.

## Repo notes

- `Sources/WriterCore` is plain Foundation and holds everything but the UI;
  `Sources/KeyboardWriter` is the SwiftUI app (macOS only).
- A cloud session has no Swift toolchain, so the code is only checked by the
  App workflow: tests, build, then `smoke.sh` runs the built app through a
  whole flash against pretend drives. Check that run after pushing, and look
  at its `screenshots` artifact after changing a view.
- `targets.json` mirrors `build.yaml` in the config repo
  (russwinch/zmk-config): when a build there is added, renamed or gets an
  `artifact-name`, update it (and `tools/flash.py` there).
- The builds the app offers are the config repo's GitHub releases, published
  by the `release` job in its `.github/workflows/build.yml`. `Builds.swift`
  relies on that job's conventions: one `.zip` of `.uf2` files per release,
  the release name is what the list shows, branches other than `main` are
  prereleases.
- The ZMK module (`firmware/`, `zephyr/module.yml`) is pulled into the config
  repo by `config/west.yml` there; a module change only reaches a keyboard
  once that repo builds with it.
- The request for the list of builds carries `GITHUB_TOKEN` when that is set.
  A public repo doesn't need it, but CI's shared machines run out of GitHub's
  allowance for requests without a login, so the App workflow sets it.
- Not yet tried on a real keyboard: the USB conversation between the app and
  the module has only been run in CI against pretend drives. Of the builds
  feature, CI shows the real list being fetched (the smoke run's first
  screenshot) but never downloads a build. Say so plainly if asked how tested
  it is.

## README

- Keep it to what the app does and how to use it. No history, status notes or
  changelog; things like that belong here or in commit messages.
- Its pictures are in `docs/`: the app's window cropped out of the smoke
  run's screenshots (`0-builds`, `3-left`, `6-finished`), with the corners
  rounded off. Replace them when the views change. A cloud session can't
  download the `screenshots` artifact (its host is blocked), so get them
  another way, e.g. a temporary workflow step that pushes them to a branch.
