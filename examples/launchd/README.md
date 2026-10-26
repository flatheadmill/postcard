# Scheduled renewal on macOS

The example LaunchAgent runs `postcard renewer` at login and every fifteen minutes while the user session is available. It visits all saved accounts; accounts not due for renewal are left alone. It does not keep a sleeping computer awake.

Replace every `/Users/johndoe` path in the plist with your home directory and adjust the executable and PATH entries for your installation. Launchd does not expand `~` or shell variables in these values. The PATH must locate `zshctl`, Zsh, jq and curl. If you use custom XDG configuration or state directories, add the matching environment variables.

After editing the example, install and load it:

```sh
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 600 examples/launchd/com.flatheadmill.postcard.renewer.plist \
    "$HOME/Library/LaunchAgents/com.flatheadmill.postcard.renewer.plist"
launchctl bootstrap "gui/$(id -u)" \
    "$HOME/Library/LaunchAgents/com.flatheadmill.postcard.renewer.plist"
launchctl print "gui/$(id -u)/com.flatheadmill.postcard.renewer"
```

RunAtLoad triggers an initial pass. A completed job normally appears as not running; inspect its last exit code and `~/Library/Logs/postcard-renewer.log` for failures. The log is not a desktop notification and is not automatically rotated. A refresh token requiring reauthorization still needs the login command reported there; the scheduled job cannot approve browser authorization.

Unload the job before replacing its configuration, or to stop scheduled renewal:

```sh
launchctl bootout "gui/$(id -u)" \
    "$HOME/Library/LaunchAgents/com.flatheadmill.postcard.renewer.plist"
```
