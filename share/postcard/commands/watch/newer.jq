include "decimal";
($after | decimal) as $boundary |
.messages[] | select((.ts | decimal) > $boundary) | .ts
