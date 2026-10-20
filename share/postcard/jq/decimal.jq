# Compare decimal strings by value without a floating-point conversion. Strip
# insignificant zeroes for comparison only; delivered objects keep their text.
def decimal:
    split(".") | (.[0] | sub("^0+"; "") | if . == "" then "0" else . end) as $integer |
    [$integer | length] + [$integer, (.[1] | sub("0+$"; ""))];
