#!/bin/bash
# Throwaway migration to validate the async-fetch + notice-file shell-launch
# flow end-to-end. When you pull this commit into a shell, the bg fetch fires
# post-merge, post-merge runs this script, and the line below should land in
# .state/notice-dotfiles and surface above your next prompt.
#
# Revert the commit and decrement .state/migrated back to 4 once verified.
echo "[test-migration 005] hello from migrations/005-test-shell-launch.sh at $(date)"
