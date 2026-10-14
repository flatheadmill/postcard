# The context is attribution, not identity or authority. The checked profile
# supplies the name. Escape Slack's control syntax in context and fallback;
# the Markdown block keeps the caller's body for Slack's Markdown renderer.
def escape: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
.[0] as $body | (.[1] + "'s " + $model + ", from Postcard") as $byline |
{
    text: (($byline + "\n\n" + $body) | escape),
    blocks: [
        {type:"context", elements:[{type:"mrkdwn", text:("*" + ($byline | escape) + "* :mailbox_with_mail:")}]},
        {type:"divider"},
        {type:"markdown", text:$body},
        {type:"divider"}
    ],
    mrkdwn:false, parse:"none", link_names:false, unfurl_links:false, unfurl_media:false
} |
select((.blocks[0].elements[0].text | length) <= 3000 and (.text | length) <= 40000)
