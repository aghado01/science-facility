# Tree Manifest TOC for Snapshot: `reposnapshot_20260722_195015_s*.txt`

Strategy: FixedSize | MaxShardSpanBytes: 32768 | Created: 20260722_195017 | Shards: 8

Payload:
`./reposnapshot_20260722_195015_tree.md`
`./reposnapshot_20260722_195015_s001.txt` files:6
`./reposnapshot_20260722_195015_s002.txt` files:2
`./reposnapshot_20260722_195015_s003.txt` files:2
`./reposnapshot_20260722_195015_s004.txt` files:2
`./reposnapshot_20260722_195015_s005.txt` files:2
`./reposnapshot_20260722_195015_s006.txt` files:1
`./reposnapshot_20260722_195015_s007.txt` files:1
`./reposnapshot_20260722_195015_s008.txt` files:1

## Instructions

Treat this payload like a virtual database which may be selectively scanned/seeked with byte offsets available for random-access and intentional seeking/fetching.
You can manage "firehose" context overload by selectively seeking segments of the payload file iteratively over multiple inference cycles.
Do not use grep to search the data because it will return an explosion of duplications.
Seek to `row_offset` in the .json file to read any entry directly without scanning.
The shard files are intentionally .txt to encourage use of lower level tools like `read_file` instead of json tools.

## Tree for `reposnapshot_20260722_195015_s*.txt`
```
file row metadata: name<TAB>shard_index<TAB>row_offset<TAB>row_meta_end<TAB>row_content_begin<TAB>row_content_end
reposnapshot
    reposnapshot-v3
        processors
            chain-executor.ps1	s001	0	54	58	626
            file-read.ps1	s001	630	680	684	1694
            format-ws.ps1	s001	1698	1748	1752	3772
            rs-csstrip.ps1	s001	3776	3827	3831	10310
            rs-indent.ps1	s001	10314	10364	10368	15300
            rs-psstrip.ps1	s001	15304	15356	15360	26820
            tp-perplexity.ps1	s002	0	55	59	10140
        rs.core.colonel.v2.psm1	s002	10144	10194	10198	26300
        rs.core.crawler.psm1	s003	0	46	50	7035
        rs.core.hash.psm1	s003	7039	7082	7086	16160
        rs.core.ignore.psm1	s004	0	47	51	27948
        rs.core.ingest.psm1	s004	27952	27998	28002	31571
        rs.core.internals.psm1	s005	0	49	53	3786
        rs.core.lsh.psm1	s005	3790	3834	3838	18954
        rs.core.sharding.psm1	s006	0	49	53	40760
        rs.core.template.ps1	s007	0	47	51	6584
    RepoSnapshotLts.psm1	s008	0	32	36	86078
```
