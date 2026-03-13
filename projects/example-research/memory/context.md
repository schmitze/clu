---
last_verified: 2026-03-13
abstract: "Goal and requirements for a provider-agnostic agent workstation."
scope: project
type: context
---

# Project Context

## Goal
Design a provider-agnostic agent workstation setup that manages
memory, personas, and project context across different AI coding
and research tools.

## Audience
Developer/researcher who uses AI agents daily and wants to reduce
setup friction, avoid vendor lock-in, and maintain persistent
context across sessions and tools.

## Key requirements
- Start from any directory — the launcher handles routing
- All config in one backupable folder
- Adapters abstract away the specific agent framework
- Memory is structured, not flat
- Works for code AND non-code projects
