---
name: read-reposnapshot
description: Explore curated run-stamped repository snapshots of code across different languages, in an LLM-friendly pre-serialized custom piped format. The entry point is always `*_tree.md`, which is an index of the sharded payload files under the same directory and contains byte offsets and spans that can be used to selectively seek and retrieve payload content slices across files and rows. This tool is useful for deep code reviews, design/co-design work, debugging, and cross-project analysis.
---

# Reposnapshot

Reposnapshot is a code ingestion tool that preprocesses a parent directory with selective intake and content pre-processing to maximize signal to noise in a model's context stream.

## Usage

When pointed to a <YYYYMMDD_hhmmss> snapshot directory or its child `*_tree.md` index file, start by reading the tree file to orient and see the payload menu items.

Based on prompt context, iteratively explore and selectively consume payload shard rows strategically. Each payload file is LF delimited and each row contains the content of a source code file in the snapshotted directory scope.
