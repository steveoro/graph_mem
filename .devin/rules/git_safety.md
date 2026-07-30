---
description: Reversible git deletion safety for untracked files
globs:
  - "**/*"
alwaysApply: true
---
# Git safety for deleting untracked files

When deleting untracked files, if in doubt first track them with `git add`, then delete them. This keeps the deletion in the staging area and makes the operation reversible anytime.
