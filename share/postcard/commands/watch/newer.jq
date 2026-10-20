include "decimal";
($after | decimal) as $boundary |
any(.messages[]; (.ts | decimal) > $boundary)
