# Object Orientation Style Guide

## Domain Objects as Abstractions

A domain object is named for the concept it represents — `User`, `Invoice`, `Pokemon` — not for where it came from. Define it as an **interface** (`abstract interface class` in Dart), never as a concrete that mixes shape with construction.

Behavior on the seam lives as **methods or getter-methods**, declared on the interface. Concretes implement them; derived behavior that should travel with every concrete lives on an extension.

**The domain does not carry programming concerns.** A `User` is what `User` *is*; whether its source was complete, parseable, or absent is not the domain's question. The seam never returns null, never carries a "missing" or "loading" state, never reports parse errors. Such concerns live in concretes (parsing) and decorators (fallback, logging, retry) — never on the seam itself.

```dart
abstract interface class User {
  String name();
  int age();
}

extension UserMaturity on User {
  bool get isAdult => age() >= 18;
}
```

> An **abstract class** or a **mixin** will also serve as the seam — the three are mechanically near-equivalent in Dart. Interface is preferred: it bears no implementation surface to surprise the reader, and the seam declares only what callers may ask. Reach for abstract class when the seam needs a shared constructor that enforces invariants; reach for mixin only when no other shape fits — its slack rules (many `with`, no constructor) suit scaffolding better than seams.

## Names Are Nouns

Every class and object — seam, concrete, decorator, mixin, value type — is a noun. Adjective + noun describes *what a thing is*; verbs and `-er` / `-or` suffixes describe *what something does* and belong on methods, not classes.

- ✅ `User`, `JsonUser`, `ConstUser`, `DtoUser`, `SafeUser`, `LoggedUser`, `ValidatedUser`, `JsonBacked`, `Money`, `Age`.
- ❌ `UserManager`, `UserValidator`, `UserLogger`, `UserChecker`, `UserHandler`, `UserParser`, `UserBuilder`.

**Pure domain objects never use `-er` / `-or` suffixes.** The rule yields at the framework boundary — first-party or third-party — when the framework's own convention bears the suffix and the class participates in that contract:

- Framework widget or component classes whose convention bears the suffix (e.g. Flutter's `ChangeNotifier`, `ScrollController`, `AnimationController` — the framework owns the name).
- Dependency-injection vocabulary (`Provider`, `Factory`, `Module`) where the suffix is part of the framework's contract, not the domain's.
- Third-party libraries whose extension points carry the suffix (e.g. JUnit's `TestRunner`, Spring's `Controller`, RxJava's `Subscriber`, gRPC's `Interceptor`) — the suffix is the library's contract, not yours to rename.

Outside these seams, the rule holds. If a class cannot be named without a verb, it is probably a method on something else. See [`general.md`](general.md) for the broader rule.

## Source as Separate Concrete

Each construction path is its own concrete class, each implementing the interface:

- `ConstUser` — literal / constant values.
- `JsonUser` — parses a JSON map.
- `DtoUser` — wraps a transport DTO.

Each concrete carries only its parsing or wrapping logic. The interface declares what callers may ask; the concrete satisfies each method from its own internal state.

Concretes are immutable: final fields, no setters. New state means a new concrete.

The simplest case wraps literal values:

```dart
class ConstUser implements User {
  ConstUser(this._name, this._age);
  final String _name;
  final int _age;
  @override String name() => _name;
  @override int age() => _age;
}
```

Richer sources follow the same shape. `JsonUser` parses a map; `DtoUser` wraps a transport object:

```dart
class JsonUser implements User {
  JsonUser(this._json);
  final Map<String, dynamic> _json;
  @override String name() => _json['name'] as String;
  @override int age() => _json['age'] as int;
}
```

The concrete reads its source plainly. Exception handling, logging, caching, and other cross-cutting concerns are layered through **decorators** — see the next section.

## Decorators for Cross-Cutting Concerns

A decorator is a class that **implements the seam *and* takes the seam as a constructor argument** — wrapping another `User` to layer behavior around its calls. It is the natural shape for cross-cutting concerns: catch-and-fallback, logging, caching, validation, retry.

The concrete stays simple — `JsonUser` reads JSON, nothing else. Concerns that do not belong to "reading JSON" do not live there.

**Catch-and-fallback** is its own decorator. Fallback values arrive as named constructor parameters, so the call site decides what "missing" means:

```dart
class SafeUser implements User {
  SafeUser(
    this._inner, {
    String nameFallback = '',
    int ageFallback = 0,
  })  : _nameFallback = nameFallback,
        _ageFallback = ageFallback;

  final User _inner;
  final String _nameFallback;
  final int _ageFallback;

  @override String name() => _safe(() => _inner.name(), _nameFallback);
  @override int age() => _safe(() => _inner.age(), _ageFallback);

  T _safe<T>(T Function() read, T fallback) {
    try { return read(); } catch (_) { return fallback; }
  }
}
```

**Logging** is its own decorator. It does not handle the error; it records it and re-throws so an outer decorator (or the caller) decides what to do next:

```dart
class LoggedUser implements User {
  LoggedUser(this._inner, this._log);
  final User _inner;
  final void Function(Object e, StackTrace st) _log;

  @override String name() => _logged(() => _inner.name());
  @override int age() => _logged(() => _inner.age());

  T _logged<T>(T Function() read) {
    try { return read(); } catch (e, st) { _log(e, st); rethrow; }
  }
}
```

**Validation** is its own decorator. It runs the rules at construction and otherwise passes through; if a rule fails, construction throws and the wrapped object never exists:

```dart
class ValidatedUser implements User {
  ValidatedUser(this._inner) {
    if (_inner.name().isEmpty) {
      throw ArgumentError('User name must not be empty');
    }
    if (_inner.age() < 0 || _inner.age() > 150) {
      throw ArgumentError('Age out of range');
    }
  }
  final User _inner;
  @override String name() => _inner.name();
  @override int age() => _inner.age();
}
```

`ValidatedUser` is unlike per-call decorators: it runs once, at construction. Its position in a wrapping chain decides *what it sees* — wrap `JsonUser` directly to validate raw source, wrap `SafeUser(JsonUser(...))` to validate post-fallback values. After construction it is silent.

**Compose by wrapping. Order matters.**

```dart
final user = SafeUser(
  LoggedUser(JsonUser(json), logger),
  nameFallback: 'unknown',
);
```

`LoggedUser` sits between source and safety: it sees the raw exception, records it, then re-throws. `SafeUser` catches and returns the fallback. Reverse the order and `SafeUser` swallows the error before `LoggedUser` ever sees it.

Two cautions:

- **Each decorator carries one concern.** Do not fold logging into `SafeUser` for convenience — the moment a caller wants safe-without-log or log-without-safe, the convenience becomes a constraint.
- **Use fallbacks, not flags.** `0` for `age` may mean "newborn" or "missing"; the domain answers `0` either way and does not pretend to know. If the program needs to distinguish parsed from defaulted, surface that through a separate decorator (an audit log, for instance) — never as a method on the seam.

**Derived behavior survives decoration.** Extensions on `User` — `UserMaturity.isAdult` from the opening section — resolve against the static type, so they work the same whether the value is a raw `JsonUser` or three decorators deep. The extension never knows it has been wrapped.

```dart
final user = SafeUser(JsonUser(json));
user.isAdult; // resolves on User; works through any layered wrapping
```

## Domain Objects Do Not Throw

A domain object — the seam, exposed to a caller — answers without raising. A `User`'s `name()` returns a string; it does not signal failure. The concept this carries: a domain object *is* a thing in the world, and "failing to be" is not part of its identity. Throws are for objects whose role is *action*, not *being* — repositories, controllers, widgets, fetchers, anything whose primary purpose is to do work against the world rather than to expose properties.

This does not mean every concrete is internally guarded. A `JsonUser` may still cast `_json['age'] as int` and let that cast blow up when the source malforms — the concrete stays narrow, reading its source plainly. The no-throw guarantee is enforced one rung higher: **a domain seam crosses to a caller wrapped**, and the wrapper catches and substitutes a type-natural default (`""`, `0`, `[]`, `false`).

```dart
// Wrong — bare concrete exposes throws to the caller.
final user = JsonUser(json);

// Right — the wrapper makes the no-throw guarantee real.
final user = SafeUser(JsonUser(json));
```

`SafeUser` defaults to type-natural zeros. When the call site needs a *different* default — `'anonymous'` rather than `''`, `-1` rather than `0` — that is what `SafeUser`'s constructor parameters are for. The decorator's purpose sharpens: not "catch surprises" but "name the call-site default".

For objects whose role *is* action — `UserRepo.fetch(id)`, `SubmitButton.onPressed`, `HttpUserSource.read()` — throws belong. They report real events: the network failed, the row was missing, the disk is gone. The caller of an action expects to handle the failure; the caller of a domain object expects an answer.

A test for which side a class falls on: *is its primary purpose to **be** something (answer about itself), or to **do** something (act against the world)?* The first wears no-throw; the second wears throws-allowed.

## Mixins — Scaffolding, Not the Seam

A **mixin** is a bundle of methods stitched into a class without inheritance — implementation-bearing, but no parent and no type of its own.

The seam is the interface. Mixins earn their place one rung lower:

- **Shared scaffolding across concretes.** When `JsonUser`, `JsonInvoice`, and `JsonPokemon` all read a JSON map the same way, lift the boilerplate into a `JsonBacked` mixin and stitch it into each concrete.
- **Optional capabilities.** A cross-cutting trait that some domain objects bear and others do not — `Comparable`, `Serializable`, `Auditable` — fits a mixin.

Refuse them when:

- The behavior is part of the domain's contract — that belongs on the interface.
- The mixin would require state from another mixin — tangled chains are worse than honest inheritance.
- Only one class would use it — a mixin earns its keep through reuse.

Below, `JsonUser` is refactored to read its map through the mixin. The field becomes public (`json`, not `_json`) because the mixin reads it through the `json` getter — when a mixin is in play, accessibility shifts to expose what it needs.

```dart
mixin JsonBacked {
  Map<String, dynamic> get json;
  T read<T>(String key) => json[key] as T;
}

class JsonUser with JsonBacked implements User {
  JsonUser(this.json);
  @override final Map<String, dynamic> json;
  @override String name() => read<String>('name');
  @override int age() => read<int>('age');
}
```

No try/catch in the mixin — that is a decorator's job. The mixin-using `JsonUser` is still a `User`, so it wraps into `SafeUser`, `LoggedUser`, or any other decorator just like the simpler form.

## No Statics

A `static` method or field belongs to the class name, not to an instance. It cannot be overridden, cannot be substituted in a test, cannot be wrapped by a decorator — it sits outside the seam entirely. To call `User.parse(json)` is to bypass the very shape this guide stands for: the seam, the concrete, the decorator chain. The seam loses its purpose the moment a caller can reach past it.

Refuse statics in domain code:

- ❌ `static User parse(Map<String, dynamic> json)` — make it a `JsonUser` constructor.
- ❌ `static int compare(User a, User b)` — make it a method on `User`, or a free function outside the class.
- ❌ `static const defaultUser` — make it a `ConstUser` instance the caller composes.

The rule yields only at the framework boundary, where the framework's contract bears the static — Flutter's `Widget.of(context)`, route name constants on a route class, and the like. Outside those seams, a static is a sign the design has slipped into procedural shape: lift it onto the seam, push it into a concrete, or let it stand as a free function with no class wrapping it.

## Why This Shape

- **Callers depend on the concept**, not the source. A method that takes `User` works the same whether the user came from JSON, DTO, or const.
- **Sources cleave cleanly.** Adding `SqlUser` touches one new file; no existing class needs editing.
- **Construction stays in the concrete.** Parsing, validation, defaulting — all sit with the source that needs them, never on the seam.
- **Concerns layer cleanly.** Try/catch, logging, caching, validation — each is a decorator that wraps the seam. The concrete stays focused on its source; the seam stays clean for callers.
- **Substitution stays cheap.** A test can supply a `ConstUser` wherever production passes a `JsonUser`.
- **No back doors.** Statics bypass the seam; refusing them keeps every call routed through the interface, where decorators and substitutes can reach.
