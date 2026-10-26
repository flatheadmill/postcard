# desc
Download a Slack-hosted original to a new local file.
# opt file -- < id >
Required exact Slack file ID, as exposed in thread messages.
# opt output -- < path >
Required new local filename. Its parent directory must already exist.
# opt help
Display help for `fetch`.
# man
## DESCRIPTION
Resolve the exact file with files.info, download its original bytes privately
beside the requested output, and publish without replacing an existing path.
The saved user grant needs files:read. Shared renewal runs before auth.test
checks the saved workspace/user binding; the same grant serves every request.

Slack-hosted binary files and snippets are supported. External references,
missing original URLs, and URLs outside the exact HTTPS files.slack.com host
are refused. No redirect or request retry is performed. The bearer and original
URL stay out of argv and diagnostics. Slack's filename never chooses a path.
The byte transfer has a five-minute total timeout, including slow transfers;
API metadata requests have a thirty-second timeout.

The downloaded size must match files.info. This checks length, not a content
hash or whether Slack transformed an upload. The destination is private, with
mode 0600. Failed transfers and supported cancellation remove staging.
Uncatchable termination can leave a private .postcard.fetch.* staging
directory beside the destination.
## OUTPUT
Success returns one JSON object with account, team_id, user_id, file_id,
absolute output path, and bytes. Stdout never carries the file content.
Publication precedes JSON output. If output fails after publication, the file
remains and stderr says it already exists; repeating will not overwrite it.
## EXIT STATUS
0 means the complete file was published and its JSON receipt written.
1 means validation, transport, publication or output failed. A nonzero status
after publication can still leave the complete destination, as described above.
## EXAMPLES
```sh
postcard --account widgets fetch --file F012EXAMPLE --output report.pdf
```
## OPTIONS
> options
