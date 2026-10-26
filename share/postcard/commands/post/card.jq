# The context is attribution, not identity or authority. The checked profile
# supplies the name. Escape Slack's control syntax in context and fallback;
# the Markdown block keeps the caller's body for Slack's Markdown renderer.
def escape: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
.[0] as $body | (.[1] + "'s " + $model + ", from Postcard") as $byline |
([if $slug != "" then "in " + $slug else empty end,
  if $where != "" then "on " + $where else empty end] | join(" ")) as $origin |
(if $origin == "" then "" else " — " + $origin end) as $aside |
{
    text: (($byline + $aside + "\n\n" + $body) | escape),
    blocks: [
        {type:"context", elements:([
            {type:"mrkdwn", text:("*" + ($byline | escape) + "* :mailbox_with_mail:")}
        ] + if $origin == "" then [] else [
            # Literal names can contain underscores and other markup. Context
            # keeps this aside quiet; plain_text preserves the caller's spelling.
            {type:"plain_text", text:("— " + $origin), emoji:false}
        ] end)},
        {type:"divider"},
        (if $body == "" then empty else {type:"markdown", text:$body} end),
        {type:"divider"}
    ],
    mrkdwn:false, parse:"none", link_names:false, unfurl_links:false, unfurl_media:false
} |
select(all(.blocks[0].elements[]; (.text | length) <= 3000) and (.text | length) <= 40000)
