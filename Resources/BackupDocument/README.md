# Backup document icon

`ApolloBackupIcon.png` is a 256px Default rendition exported from
`liquid-glass/icons/apollo/apollo.icon` with Icon Composer, normalized to 8-bit PNG.
This is the “Apollo” icon, not “Apollo Glass” or “Apollo Classic”.

`scripts/register-backup-document.py` copies it into the main app and registers
`.apollobackup` before signing. Both manual and automatic backups retain their
ZIP contents; `UTTypeIconText` asks iOS to render “ZIP” below the Apollo badge.
Legacy `.zip` backups remain supported. Restore through Apollo Reborn → Restore
Settings. Apollo is registered as the owner/viewer of this custom type (not of
generic ZIP archives). Opening it in Files presents the same explicit restore confirmation
as the in-app restore picker. Both warm launches and scene connection URLs are
handled; unrelated file URLs retain Apollo's native handling.

A tweak-only update cannot install this registration: reinstall a newly packaged
IPA. If Files already associates backups with ESign or another archive app, choose
Apollo in Get Info → Always Open With and apply it to all files of this type.
An existing user-selected association may survive an app update.

Regression check on device: inspect the **same backup file** in Files Browse,
Recents, Get Info, and Apollo's restore picker. An isolated rendered icon or the
containing folder's icon is not sufficient. Also open a backup with Apollo both
running and terminated, cancel the confirmation, and verify settings are unchanged.

Run `tests/run_backup_document_tests.sh` with a booted simulator for the shared
confirmation flow tests (stub restore engine; no real backup data is touched).
