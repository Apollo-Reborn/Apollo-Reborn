# iCloud backup manual validation

Use only test accounts and a newly created backup. A `.apollobackup` archive can
contain API keys and logged-in Reddit credentials.

## No iCloud Documents entitlement

1. Install an ad-hoc or free-account re-signed build without a ubiquity container.
2. Open Apollo Reborn → Data → Backup Settings.
3. Confirm `Save Copies to iCloud` is off and the status explains the missing
   entitlement. Choose an iCloud Drive folder through Files and confirm the
   toggle becomes available without changing the app's signature.
4. Create, list, restore, export, and delete a local backup. Confirm every local
   operation remains usable and no iCloud error blocks it.
5. Open Restore Settings. Confirm Local Backup and Choose from Files work, while
   iCloud Backup is disabled.

## Entitled build, account unavailable

1. Install a build provisioned with iCloud Documents, then sign out of iCloud or
   disable iCloud Drive.
2. Confirm the backup screen explains the account/Drive state and local backup
   behavior remains unchanged.

## Two-device convergence

1. Install builds signed for the same default ubiquity container on devices A
   and B. Enable iCloud copies on each device and accept the credential warning.
2. Create a backup on A. Confirm it remains in Manage Backups locally and later
   appears under Manage iCloud Backups on both devices.
3. Create backups on both devices while one is offline, reconnect both, and
   confirm both collision-resistant filenames remain visible. No device should
   automatically prune another device's archives.
   Confirm an offline copy remains visibly Pending and uploads after Apollo is
   active again.
4. Evict one archive from local iCloud storage, choose Restore in Apollo, and
   confirm Apollo downloads a protected temporary copy before showing the normal
   restore confirmation.
5. Cancel once, then restore a test archive. Confirm the existing validation and
   restart flow is unchanged.
6. Delete one iCloud archive and confirm the destructive warning explicitly says
   the deletion affects connected devices. Confirm the item disappears on both.
7. For the entitlement-free selected-folder lane, reboot both devices and reopen
   Apollo. Confirm the bookmark either reconnects cleanly or reports the folder
   unavailable without blocking local backups. Re-select the same folder and
   confirm pending copies resume without duplicate archives.

## Signing changes

1. Enable iCloud copies, then install the same app under a signing profile that
   lacks iCloud Documents access.
2. Confirm local backups still run. Confirm the retained opt-in can be switched
   off even while iCloud is unavailable.
3. Re-sign from one valid iCloud container to a different valid container.
   Confirm the old consent is rejected and Apollo requires a new credential
   warning before uploading to the new destination.
