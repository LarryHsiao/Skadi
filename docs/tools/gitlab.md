# GitLab

## Replying to discussions

When responding to an existing comment on a merge request or issue, always reply as a **child of that comment's thread** — never open a new root-level post. GitLab supports threaded child replies (`POST /projects/:id/merge_requests/:mr_iid/discussions/:discussion_id/notes`); reach for that endpoint, not the top-level notes one.

A new root post severs the conversation: reviewers lose the thread, the original comment never resolves, and the page fills with parallel monologues. The child reply keeps each exchange under its question, and lets the author resolve the thread when satisfied.
