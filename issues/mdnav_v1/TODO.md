experimental design for prefixing strategies
 - essentially ablation study on "context prefixing" vs "no context prefixing" and analyze performance in terms of:
    - 1-hop citations
    - cross-chunk grounding
    - distance-decay mitigation
    - tokenization consistency
need to perform renovations on code to allow for careful ablation of prefixing without removing the tooling infrastructure utility 
need to carefully review skill documentation to be agnostic to prefixing scheme while indirectly engineering for ideal performance under both conditions 