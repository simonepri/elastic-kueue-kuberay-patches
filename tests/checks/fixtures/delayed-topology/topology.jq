# Decode Kueue v1beta2's compact topology slices, including shared prefixes/suffixes.
def domains:
  .slices[] as $slice | range(0; $slice.domainCount) as $i |
  {count: ($slice.podCounts.universal // $slice.podCounts.individual[$i]),
   values: [$slice.valuesPerLevel[] |
     .universal // ((.individual.prefix // "") + .individual.roots[$i] + (.individual.suffix // ""))]};
def with_domains:
  .status.admission.podSetAssignments[].topologyAssignment |= . + {domains: [domains]};
