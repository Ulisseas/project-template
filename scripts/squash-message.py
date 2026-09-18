#!/usr/bin/env python3
"""Print the commit message GitHub will create when a PR is squash-merged.

GitHub uses the PR title with " (#N)" appended as the subject and the PR body,
word-wrapped at 72 columns without splitting long tokens, as the body
(repo settings: squash_merge_commit_title=PR_TITLE,
squash_merge_commit_message=PR_BODY). CI pipes this into commitlint so the
message is checked before the merge, not after.

Reads PR_TITLE, PR_BODY and PR_NUMBER from the environment; never from argv,
so attacker-controlled text is not interpolated into a shell.
"""
import os
import sys
import textwrap

title = os.environ["PR_TITLE"]
number = os.environ["PR_NUMBER"]
body = os.environ.get("PR_BODY", "").replace("\r\n", "\n").replace("\r", "\n")

out = [f"{title} (#{number})", ""]
for line in body.split("\n"):
    if line.strip():
        out.extend(textwrap.wrap(line, 72, break_long_words=False, break_on_hyphens=False))
    else:
        out.append("")
sys.stdout.write("\n".join(out).rstrip("\n") + "\n")
