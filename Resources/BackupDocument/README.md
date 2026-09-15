# Backup document icon

`ApolloBackupIcon.png` is a 256px Default rendition exported from
`liquid-glass/icons/apollo/apollo.icon` with Icon Composer, normalized to 8-bit PNG.
This is the “Apollo” icon, not “Apollo Glass” or “Apollo Classic”.

`scripts/register-backup-document.py` copies it into the main app and registers
`.apollobackup` before signing. Both manual and automatic backups retain their
ZIP contents; `UTTypeIconText` asks iOS to render “ZIP” below the Apollo badge. Legacy `.zip` backups remain supported. Restore through Apollo
Reborn → Restore Settings. The document declaration does not claim an Open In
handler. A tweak-only update cannot install this icon registration: reinstall a
newly packaged IPA. Files may cache document icons until after reinstallation.
