---
name: README present
scope: project
---

A foundation project carries a README that tells a reader, in a paragraph or three, what this is and how to run it. Without one, every newcomer pays a reading-the-source tax.

Scan the project root for a README:

- `README.md`, `README.rst`, `README.txt`, `README` (case-insensitive).

Pass when:
- A README file exists at the project root.
- AND it has at least 200 characters of substantive content (excluding badges, HTML comments, and YAML frontmatter).
- AND the body says more than just the project name — at minimum, what the project is.

Fail when:
- No README is found.
- The README is empty.
- The README contains only a title and badges, with no narrative body.

On fail, name what was found and why it falls short (e.g. "README.md present but body is 47 characters; only the title is written").
