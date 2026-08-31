# aur-packages

Monorepo for bermudi's AUR packages. Each subdirectory is one AUR package and
is the source of truth for its PKGBUILD, `.SRCINFO`, and auxiliary files.
GitHub Actions keep the AUR in sync.

## Layout

```
<pkgname>/            # one per AUR package
  PKGBUILD
  .SRCINFO
  *.desktop, etc.
.github/
  scripts/
    update-pkgbuild.sh    # rewrite pkgver + checksums; reset pkgrel on version bumps
    generate-srcinfo.sh   # source PKGBUILD -> .SRCINFO (no makepkg needed)
  workflows/
    <pkgname>.yml         # per-package: poll upstream, call update-aur
    update-aur.yml        # reusable: bump, commit, tag, release, push to AUR
```

## Packages

| Directory            | AUR package          | Upstream channel                  |
|----------------------|----------------------|-----------------------------------|
| `devin-desktop-next` | `devin-desktop-next` | Devin Desktop **next** (APT deb)  |
| `devin-desktop`      | `devin-desktop`      | Devin Desktop **stable** (APT deb) |
| `opencode2-bin`      | `opencode2-bin`      | opencode v2 (npm preview, `next` dist-tag) |

`devin-desktop-next` supersedes the old `windsurf-next` package
(`provides`/`conflicts`/`replaces` it).

## Adding a package

1. Create `<pkgname>/` with a `PKGBUILD` (and `.SRCINFO`, desktop files, …).
2. Add `.github/workflows/<pkgname>.yml` modelled on `devin-desktop-next.yml`.
3. Ensure the `AUR_SSH_PRIVATE_KEY` repo secret is set (shared by all packages).
   The first publish creates the AUR repo automatically (clone-or-init).
4. **Adopting an existing AUR package** (e.g. `devin-desktop`): the clone-or-init
   logic only fires when the AUR repo is missing. For an existing package the
   updater clones the current AUR tree and overwrites it with our sources —
   no special handling needed, but the first push must be verified manually
   (files, version, maintainer field) before trusting the automation.

## Secrets

- `AUR_SSH_PRIVATE_KEY` — SSH private key authorized on your AUR account.
  Required for the AUR push step; without it the workflow updates GitHub only.
