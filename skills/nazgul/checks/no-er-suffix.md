---
name: No -er suffix on classes or packages
scope: [diff, project]
---

The project style rejects agent-noun suffixes on class and package names — no Manager, Helper, Handler, Processor, Builder, Runner, Controller, Worker, Coordinator, Formatter, Parser, and the like. Classes and packages are nouns, named for the domain concept they represent, not for what they do.

Scan the given target for class, interface, struct, object, trait, module, or package declarations whose names end in an agent -er/-or suffix (a "thing that <verbs>"). The target is either a captured diff or a project root — adapt as below.

**When the target is a diff** — flag only changes the diff itself introduces:

- Pass when no NEW or RENAMED offending names appear in the diff. An existing offender merely referenced (not created or renamed) does not count.
- Fail when a new type or package is introduced with an offending suffix, or an existing name is renamed TO an offending form.

**When the target is a project root** — survey the standing tree under the conventional source directories (`lib/`, `src/`, `app/`, `pkg/`, language-appropriate equivalents). Skip third-party / vendored / generated code (e.g. `*.g.dart`, `*_pb.go`, `__generated__/`, `node_modules/`, `vendor/`):

- Pass when no offending class or package names appear in first-party source.
- Fail when one or more first-party declarations carry an offending suffix.

Do not flag, in either mode:

- Methods, variables, or parameters — only types and packages.
- Names where -er is part of the domain noun, not an agent form: Header, Footer, Border, Container, Buffer, Number, Order, Member, Filter (when it names a filter *concept*, not "thing that filters").
- When in doubt, prefer to flag and let the human judge.

On fail, name each offender with `file:line`. For the project mode, if many offenders surface, list up to five and append a count like "and 12 more".
