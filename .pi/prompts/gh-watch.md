---
description: Start a streamed main CI monitor
---
From the repo root, run `scripts/main-watch.sh $ARGUMENTS` with async_bash,
stream: true, name "main-watch". The script resolves commit arguments and exits
if a watcher is already running.

When a notification from this process arrives you don't need to react to and
print something to user, unless there's a failure and you want to take action
to fix it or suggest to user.

Now end the turn, don't reply to the user, they know about watcher and how it's setup.
