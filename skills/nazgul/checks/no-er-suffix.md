---
name: No -er suffix on classes or packages
---

The project style rejects agent-noun suffixes on class and package names — no Manager, Helper, Handler, Processor, Builder, Runner, Controller, Worker, Coordinator, Formatter, Parser, and the like. Classes and packages are nouns, named for the domain concept they represent, not for what they do.

Scan the diff for any NEW or RENAMED class, interface, struct, object, trait, module, or package whose name ends in an agent -er/-or suffix (a "thing that <verbs>").

Pass when:
- No new or renamed offending names appear in the diff.
- An existing offending name is merely referenced (not created or renamed).

Fail when:
- A new type or package is introduced with an offending suffix.
- An existing name is renamed TO an offending form.

Do not flag:
- Methods, variables, or parameters — only types and packages.
- Names where -er is part of the domain noun, not an agent form: Header, Footer, Border, Container, Buffer, Number, Order, Member, Filter (when it names a filter *concept*, not "thing that filters").
- When in doubt, prefer to flag and let the human judge.

On fail, name each offender with `file:line`.
