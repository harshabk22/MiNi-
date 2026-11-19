# Security policy

Mini runs commands and edits files on your Mac, and Mini Dictate can read keystrokes and paste text. Security bugs matter.

## Reporting a vulnerability
**Don't open a public issue.** Report it privately instead: in this repository's **Security** tab, click **Report a vulnerability**.

Please include what you did, what happened, and your macOS version. You'll get a reply within 7 days.

## In scope
- Mini running a command, or changing or deleting a file, without your approval
- Getting around the sandbox: writing outside Desktop / Documents / Downloads, reading private folders, uploading data
- Mini Dictate pasting into password fields, logging what you say or type, or listening when it shouldn't
- Personal data (memories, chats, vocabulary) leaking off your Mac

## Out of scope
- Mistakes in the AI model's answers (see "Limits" in the README)
- Commands you approved yourself

## Supported versions
Only the latest commit on `main` gets security fixes.
