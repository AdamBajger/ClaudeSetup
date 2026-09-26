---
name: youtrack
description: >
  Work with YouTrack from this agent: issues/projects/comments via the YouTrack MCP tools, and
  knowledgebase ARTICLES via the file-based `youtrack-kb` helper (download → edit → upload).
  Use when the user mentions YouTrack, an issue id (e.g. DEV-123), a KB article id (e.g. ON-A-80),
  "knowledgebase", or asks to read/update/create issues or articles.
---

YouTrack: two halves, different tools.

## Issues / projects / comments — MCP tools

`mcp__youtrack__*` tools load at session start when `youtrack.host` + token configured. Key:
`search_issues`, `get_issue`, `create_issue`, `update_issue`, `add_issue_comment`,
`link_issues`, `change_issue_assignee`, `log_work`, `manage_issue_tags`, `find_projects`,
`get_project`, `find_user`, `get_issue_fields_schema`, `get_current_user`. Load schemas via
ToolSearch (e.g. `mcp__youtrack__search_issues`) before calling. Tools absent → MCP not
configured / session needs restart — tell user.

## Knowledgebase ARTICLES — `youtrack-kb` (REST, file-based)

Articles NOT in MCP. Use baked `youtrack-kb` helper (on PATH; reads `YT_HOST` + `YT_TOKEN`
from env, set by deployment). Work on **local file** → Read/Edit tools apply:

- **Read / edit article**
  1. `youtrack-kb get ON-A-80 article.md`   — download markdown to `article.md`.
  2. Read/Edit `article.md` (plain Markdown).
  3. `youtrack-kb update ON-A-80 article.md` — upload edited file.
- **Create**: `youtrack-kb create <PROJECT> "Title" article.md` (PROJECT = short name like
  `ON`, from `find_projects`). File content = article body.
- **Delete**: `youtrack-kb delete ON-A-80`.
- **List**: `youtrack-kb list` (all) or `youtrack-kb list ON` (one project) →
  `idReadable<TAB>summary`.

Helper resolves internal ids — always pass human `idReadable` (`ON-A-80`) + project short
names.

## Notes

- Always confirm with user before `update`/`delete` on real article — mutates shared docs.
- Article embeds ```` ``` ```` fences → edited file may need 4-backtick outer fences so inner
  fences survive (YouTrack Markdown).
- `youtrack-kb` errors "set YT_HOST/YT_TOKEN" → integration not configured here.
