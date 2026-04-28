#!/bin/bash
# No-op. This migration was originally a test fixture for the shell-launch
# async/notice-file flow (Apr 2026); a few machines auto-updated and ran it
# before it could be cleaned up. Migrations are append-only across the
# fleet — reverting would force every already-bumped machine to manually
# rewind .state/migrated, which is worse than leaving a no-op behind.
# Future migrations resume at 006.
exit 0
