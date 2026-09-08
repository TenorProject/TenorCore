# Tooling setup

Committed config gets you most of the way. Two steps are per-developer.

## Already in the repo, nothing to do

- **`.claude/skills/tenor-hedera/SKILL.md`** — our verified Hedera and ATS findings. Loads
  automatically for anyone working in this repo. This is a week of debugging compressed into one
  file: read it before trusting any Hedera or ATS documentation.
- **`.mcp.json`** — two Hedera MCP servers. Claude will ask you to approve them on first use.
  - `hedera-docs` (`https://docs.hedera.com/mcp`) searches the whole Hedera knowledge base. No auth.
  - `hedera-testnet` (`https://agentic-testnet-mcp.hedera.com/mcp`) reads balances, tokens and
    records. State-changing calls come back as unsigned bytes you sign locally; **no private key
    ever leaves your machine**. Testnet only.
- **`.claude/settings.json`** — registers Hedera's plugin marketplace and lists the plugins we want.

## Step 1: your account ID

```bash
cp .claude/settings.local.json.example .claude/settings.local.json
```

Put your Hedera account ID in it. The file is gitignored. The `hedera-testnet` MCP server needs it
as a header.

## Step 2: install the Hedera plugins

The marketplace is registered by the committed settings, but plugins from external marketplaces
still need an install per developer. In Claude Code:

```
/plugin install system-contracts@hedera
/plugin install native-services-js@hedera
/plugin install hackathon-helper@hedera
```

- **system-contracts** — HTS (`0x167`) and Schedule Service (`0x16b`) references in Solidity.
  Directly what `TenorSettlement` is built on.
- **native-services-js** — HTS and HCS via the Hiero JS SDK. What `services/hcs/` needs, since HCS
  is unreachable from Solidity.
- **hackathon-helper** — project scoring and submission validation. Useful this week specifically.

Skipped deliberately: `agent-kit-plugin` (we are not building an Agent Kit extension) and
`dev-intelligence` (workflow tooling, not worth the context this week).

## One caveat worth stating

Hedera's own documentation has been wrong in at least four places we hit: the lock-hash DvP flow
that does not exist, clearing-mode irreversibility, which role creates clearing operations, and hold
expiration semantics. The docs MCP is a fast way to find leads. **It is not a source of truth.**
Confirm anything load-bearing against the ATS Solidity or against testnet.
