# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

- **ALWAYS** use serena mcp to provides essential semantic code retrieval, editing, refactoring and debugging tools that are akin to an IDE’s capabilities, operating at the symbol level and exploiting relational structure.

- **ALWAYS** use context7 when I need library/API documentation, code generation, setup or configuration steps without me having to explicitly ask.

- **ALWAYS** update this guide when necessary.

## What this repo is

**Awesome VPS** — a curated collection of bash scripts that provision, configure, and secure Ubuntu VPS instances. There is no build system, package manager, or test suite: these are ops/admin scripts meant to run with `sudo` on a target VPS (often via `curl | bash`), organized into isolated "stacks" per workload.

Currently one stack exists:

- `postgres_redis/` — provisions a database VPS (PostgreSQL 17 + Redis 8 with per-app instances, TLS via Let's Encrypt, UFW, Fail2Ban) and manages per-app DB/Redis users afterward.

## Running / testing scripts

For this topic, read:

- .docs/llm/testing_scripts.md

## Architecture: postgres_redis/

For this topic, read:

- .docs/llm/postgres_redis.md

## Script conventions

For this topic, read:

- .docs/llm/script_conventions.md

## POSIX note

For this topic, read:

- .docs/llm/posix_note.md
