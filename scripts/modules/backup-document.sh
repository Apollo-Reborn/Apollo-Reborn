#!/bin/bash
# Register the backup file type and icon before the IPA is signed.
_BACKUP_DOCUMENT_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/register-backup-document.py"
register_backup_document_in_app() {
    python3 "$_BACKUP_DOCUMENT_SCRIPT" "$1"
}
