# Universal Engineering Rules

> Unlike `general.md`, `oo.md`, `flutter.md`, and `react.md` — which are personal taste, gated in `/mithrandir` to your own repos — rules here hold regardless of whose codebase the diff lives in. They travel onto every review, the way the official Effective Dart conventions in `dart-official.md` do, because the cost they guard against lands on whoever reads the code next, not on whoever holds the repo.
>
> Add new rules here, not as one-off exceptions threaded into a skill's prose — the container is the point.

## Duplication

- **Lift duplicate shapes on the third recurrence.** Two parallel uses of a small algorithm — a condition, a method body, a transform — may read true as honest repetition; a third is the threshold where the next reader pays a tax: touch one site and the question becomes *"did the other two move with it?"* Lift it then: a private helper, a shared utility, a base method named for the intent. The exception is structural look-alikes that bear *different* meanings — same five lines, different domain concern. Coupling those by name binds two things that should drift independently. Read each site's *why*, not its syntax; lift when the why matches, leave the shapes apart when it does not.
