# Contributing

This project is an iOS tweak built with [Theos](https://theos.dev/) and [Logos](https://theos.dev/docs/logos-syntax.html). Development relies heavily on reverse engineering Apollo's binary, so an AI-assisted workflow with MCP (Model Context Protocol) tools can be super helpful.

## Getting Started

```bash
# Clone and init submodules
git submodule update --init --recursive

# Build
make package
```

## Agent-Assisted Development

This project includes an [AGENTS.md](AGENTS.md) file that gives coding agents full context about the codebase, conventions, and RE techniques.

## Disassembler MCP Setup

A disassembler with MCP support lets agents query the binary directly. This guide covers [Hopper Disassembler](https://www.hopperapp.com/) which has one built in, but other tools like Ghidra work too.

1. **Install Hopper** from [hopperapp.com](https://www.hopperapp.com/).
2. **Open Apollo's binary** in Hopper (extract from the `.ipa` → `Payload/Apollo.app/Apollo`).
3. **Configure the MCP server** in your coding agent's MCP config using the STDIO transport protocol (syntax varies):

```json
{
    "mcpServers": {
        "HopperMCPServer": {
            "command": "/Applications/Hopper Disassembler.app/Contents/MacOS/HopperMCPServer",
            "args": [],
            "env": {}
        }
    }
}
```

See [AGENTS.md](AGENTS.md) for detailed Hopper MCP tools and investigation patterns.

## Apple Developer Docs MCP Setup

The [apple-docs-mcp](https://github.com/kimsungwhee/apple-docs-mcp) server gives agents live access to Apple Developer documentation, WWDC transcripts, and framework symbol search.

```json
{
    "mcpServers": {
        "apple-dev": {
            "command": "npx",
            "args": ["-y", "apple-docs-mcp@latest"]
        }
    }
}
```

## iOS 26 Runtime Headers (for Liquid Glass work)

For iOS 26 / Liquid Glass-specific tweaks, clone these into the repo root so agents can grep them directly. Both are gitignored.

```bash
# RuntimeBrowser-style ObjC headers for every framework
git clone https://github.com/qingralf/iOS26-Runtime-Headers.git

# IDA-style decompilation of iOS 26.1. The full repo is huge; sparse-checkout
# just UIKitCore.framework (the only slice that's typically needed).
git clone --depth 1 --filter=blob:none --sparse https://github.com/EthanArbuckle/iPhone18-3_26.1_23B85_Restore.git
cd iPhone18-3_26.1_23B85_Restore
git sparse-checkout set System/Library/PrivateFrameworks/UIKitCore.framework
cd ..
```

See [AGENTS.md](AGENTS.md) for usage notes.

## Adding a New Feature

Tips for prompting effectively:

**Describe the behavior, not the implementation** — focus on what you want from the user's perspective.

> "When I scroll past an unmuted video in comments, the audio stops. Can you make it keep playing?"

**Provide runtime context** — paste crash backtraces, `ApolloLog` console output, and screenshots so the agent can diagnose quickly.
