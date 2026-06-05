---
name: youtrack
description: >
  Work with YouTrack from this agent: issues/projects/comments via the YouTrack MCP tools, and
  knowledgebase ARTICLES via the file-based `youtrack-kb` helper (download → edit → upload).
  Use when the user mentions YouTrack, an issue id (e.g. DEV-123), a KB article id (e.g. ON-A-80),
  "knowledgebase", or asks to read/update/create issues or articles.
---

YouTrack access has two halves with different tools.

## Issues / projects / comments — MCP tools

The `mcp__youtrack__*` tools are loaded when `youtrack.host` + a token are configured (they
load at session start). Key tools: `search_issues`, `get_issue`, `create_issue`,
`update_issue`, `add_issue_comment`, `link_issues`, `change_issue_assignee`, `log_work`,
`manage_issue_tags`, `find_projects`, `get_project`, `find_user`, `get_issue_fields_schema`,
`get_current_user`. Load schemas with ToolSearch (e.g. `mcp__youtrack__search_issues`) before
calling. If these tools are absent, the YouTrack MCP isn't configured / the session needs a
restart — tell the user.

## Knowledgebase ARTICLES — `youtrack-kb` (REST, file-based)

Articles are NOT in the MCP. Use the baked `youtrack-kb` helper (on PATH; reads `YT_HOST` +
`YT_TOKEN` from the environment, already set in the deployment). Work on a **local file** so you
can inspect/edit articles with normal Read/Edit tools:

- **Read / edit an existing article**
  1. `youtrack-kb get ON-A-80 article.md`   — downloads the markdown content to `article.md`.
  2. Inspect/modify `article.md` with Read/Edit (it's plain Markdown).
  3. `youtrack-kb update ON-A-80 article.md` — uploads the edited file back.
- **Create a new article**
  `youtrack-kb create <PROJECT> "Title" article.md`  (PROJECT = short name like `ON`; get it
  from `find_projects`). Writes the file's content as the new article body.
- **Delete an article**
  `youtrack-kb delete ON-A-80`.
- **List articles**
  `youtrack-kb list` (all) or `youtrack-kb list ON` (one project) → `idReadable<TAB>summary`.

The helper resolves YouTrack's internal ids for you — always pass the human `idReadable`
(`ON-A-80`) and project short names.

## Notes

- Always confirm before `update`/`delete` on a real article — those mutate shared docs.
- When an article embeds ```` ``` ```` fences, your edited file may need 4-backtick outer fences
  so the inner fences survive (YouTrack Markdown).
- If `youtrack-kb` errors with "set YT_HOST/YT_TOKEN", the integration isn't configured in this
  environment.
