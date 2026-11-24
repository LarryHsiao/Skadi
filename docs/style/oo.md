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

> An **abstract class** or a **mixin** would compile as a seam too, but each invites concretes to `extends` or `with` it — to inherit code, not only the type. The seam is always an interface: a concrete `implements` it and inherits the type alone. Shared code reaches a concrete by composition (*Share by Composing, Not Mixing*), and invariants arrive by decorator (`ValidatedUser`).

## Names Are Nouns

Every class and object — seam, concrete, decorator, mixin, value type — is a noun. Adjective + noun describes *what a thing is*; verbs and `-er` / `-or` suffixes describe *what something does* and belong on methods, not classes.

- **Good:** `User`, `JsonUser`, `ConstUser`, `DtoUser`, `SafeUser`, `LoggedUser`, `ValidatedUser`, `JsonFields`, `Money`, `Age`.
- **Bad:** `UserManager`, `UserValidator`, `UserLogger`, `UserChecker`, `UserHandler`, `UserParser`, `UserBuilder`.

**Pure domain objects never use `-er` / `-or` suffixes.** The rule yields at the framework boundary — first-party or third-party — when the framework's own convention bears the suffix and the class participates in that contract:

- Framework widget or component classes whose convention bears the suffix (e.g. Flutter's `ChangeNotifier`, `ScrollController`, `AnimationController` — the framework owns the name).
- Dependency-injection vocabulary (`Provider`, `Factory`, `Module`) where the suffix is part of the framework's contract, not the domain's.
- Third-party libraries whose extension points carry the suffix (e.g. JUnit's `TestRunner`, Spring's `Controller`, RxJava's `Subscriber`, gRPC's `Interceptor`) — the suffix is the library's contract, not yours to rename.

Outside these seams, the rule holds. If a class cannot be named without a verb, it is probably a method on something else. See [`general.md`](general.md) for the broader rule.

**A read source that yields a list takes the model's plural.** `Users` yields `List<User>`; `Rates` yields `List<Rate>`. The near-twin is intended: the plural names the **producer**, the singular the **thing produced**. Alternatives such as `UserList`, `UsersSource` or `GetUsers` trade the noun for a suffix or a verb. Reach for a distinct noun only when the result is not a straight list of the model — a summary, a page, a composed view.

## Source as Separate Concrete

Each construction path is its own concrete class, each implementing the interface:

- `ConstUser` — literal / constant values.
- `JsonUser` — parses a JSON map.
- `DtoUser` — wraps a transport DTO.

Each concrete carries only its parsing or wrapping logic. The interface declares what callers may ask; the concrete satisfies each method from its own internal state.

Concretes are immutable and closed: final fields, no setters, and declared `final class` so nothing extends them. New state means a new concrete; new behavior means a decorator. The rule yields at the framework boundary, where the framework's contract is a base class to extend — Flutter's `StatelessWidget` and the like.

**Constructors only store.** A constructor assigns what it is given — at most wrapped in another object — and never calls it: no check, no parse, no call on an argument. Building a chain therefore cannot fail on a source's content; every such failure surfaces at a method call, inside the wrappers built to handle it. Dart's types already reject what a constructor check would otherwise catch — a null, a wrong type — so what is left to check is a value, and a value is weighed at the call.

The simplest case wraps literal values:

```dart
final class ConstUser implements User {
  ConstUser(this._name, this._age);
  final String _name;
  final int _age;
  @override String name() => _name;
  @override int age() => _age;
}
```

Richer sources follow the same shape. `JsonUser` parses a map; `DtoUser` wraps a transport object:

```dart
final class JsonUser implements User {
  JsonUser(this._json);
  final Map<String, dynamic> _json;
  @override String name() => _field<String>('name');
  @override int age() => _field<int>('age');

  T _field<T>(String key) {
    final value = _json[key];
    if (value is T) return value;
    throw FormatException('"$key" is not a $T', _json);
  }
}
```

The concrete reads its source plainly: a missing or mistyped field becomes a `FormatException`. Data from outside that does not fit is an exception, not a bug — a bare `as` cast would raise a `TypeError`, which [`dart-official.md`](dart-official.md) reserves for programmatic bugs. Every source keeps this contract, because `FormatException` is the one failure `SafeUser` substitutes for. Exception handling, logging, caching, and other cross-cutting concerns are layered through **decorators** — see the next section.

## Decorators for Cross-Cutting Concerns

A decorator is a class that **implements the seam *and* takes the seam as a constructor argument** — wrapping another `User` to layer behavior around its calls. It is the natural shape for cross-cutting concerns: catch-and-fallback, logging, caching, validation, retry.

The concrete stays simple — `JsonUser` reads JSON, nothing else. Concerns that do not belong to "reading JSON" do not live there.

**Catch-and-fallback** is its own decorator. Fallback values arrive as named constructor parameters, so the call site decides what "missing" means. It catches only `FormatException`, the failure a source reports, so a bug still surfaces as one:

```dart
final class SafeUser implements User {
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
    try { return read(); } on FormatException { return fallback; }
  }
}
```

**Logging** is its own decorator. It does not handle the error; it records it and re-throws so an outer decorator (or the caller) decides what to do next:

```dart
final class LoggedUser implements User {
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

**Validation** is its own decorator. Each call checks the answer the wrapped object gives and throws a `FormatException` when a rule fails; otherwise it passes the answer through:

```dart
final class ValidatedUser implements User {
  ValidatedUser(this._inner);
  final User _inner;

  @override
  String name() {
    final name = _inner.name();
    if (name.isEmpty) {
      throw const FormatException('User name is empty');
    }
    return name;
  }

  @override
  int age() {
    final age = _inner.age();
    if (age < 0 || age > _maxAge) {
      throw FormatException('Age $age is out of range');
    }
    return age;
  }
}

const _maxAge = 150;
```

The check runs at the call, not at construction: it weighs the answer the caller is about to receive, and the constructor stays a plain store. Place it beneath `SafeUser` — `SafeUser(LoggedUser(ValidatedUser(JsonUser(json)), logger))` — and a rule that fails is handled like a malformed field: logged, then replaced by the call-site default.

**Compose by wrapping. Order matters.**

```dart
final user = SafeUser(
  LoggedUser(JsonUser(json), logger),
  nameFallback: 'unknown',
);
```

`LoggedUser` sits between source and safety: it sees the raw exception, records it, then re-throws. `SafeUser` catches and returns the fallback. Reverse the order and `SafeUser` swallows the error before `LoggedUser` ever sees it.

Two cautions:

- **Each decorator carries one concern.** Do not fold logging into `SafeUser` for convenience — the moment a caller wants log-without-safe (a failure recorded, then left to propagate), the convenience becomes a constraint.
- **Use fallbacks, not flags.** `0` for `age` may mean "newborn" or "missing"; the domain answers `0` either way and does not pretend to know. If the program needs to distinguish parsed from defaulted, surface that through a separate decorator (an audit log, for instance) — never as a method on the seam.

**Derived behavior survives decoration.** Extensions on `User` — `UserMaturity.isAdult` from the opening section — resolve against the static type, so they work the same whether the value is a raw `JsonUser` or three decorators deep. The extension never knows it has been wrapped.

```dart
final user = SafeUser(LoggedUser(JsonUser(json), logger));
user.isAdult; // resolves on User; works through any layered wrapping
```

## Domain Objects Do Not Throw

A domain object — the seam, exposed to a caller — answers without raising. A `User`'s `name()` returns a string; it does not signal failure. The concept this carries: a domain object *is* a thing in the world, and "failing to be" is not part of its identity. Throws are for objects whose role is *action*, not *being* — repositories, controllers, widgets, fetchers, anything whose primary purpose is to do work against the world rather than to expose properties.

This does not mean every concrete is internally guarded. A `JsonUser` still throws a `FormatException` when the source malforms — the concrete stays narrow, reading its source plainly. The no-throw guarantee is enforced one rung higher: **a domain seam crosses to a caller wrapped**, and the wrapper catches and substitutes a type-natural default (`""`, `0`, `[]`, `false`). It catches what the data causes — a `FormatException` — and never an `Error`: a programming bug still surfaces, because a fallback must not hide one.

```dart
// Wrong — bare concrete exposes throws to the caller.
final user = JsonUser(json);

// Wrong — no throw, but a fallback that fires unheard.
final user = SafeUser(JsonUser(json));

// Right — no throw, and the log beneath records every fallback.
final user = SafeUser(LoggedUser(JsonUser(json), logger));
```

`SafeUser` defaults to type-natural zeros. When the call site needs a *different* default — `'anonymous'` rather than `''`, `-1` rather than `0` — that is what `SafeUser`'s constructor parameters are for. The decorator's purpose sharpens: not "catch surprises" but "name the call-site default".

For objects whose role *is* action — `UserRepo.fetch(id)`, `SubmitButton.onPressed`, `HttpUserSource.read()` — throws belong. They report real events: the network failed, the row was missing, the disk is gone. The caller of an action expects to handle the failure; the caller of a domain object expects an answer.

A test for which side a class falls on: *is its primary purpose to **be** something (answer about itself), or to **do** something (act against the world)?* The first wears no-throw; the second wears throws-allowed.

**A fallback is a quiet failure, so it must not be a silent one.** A defaulted `0` reads exactly like a real `0` — the cost [`universal.md`](universal.md) weighs under *Prefer the failure that is loud and local*. This guide accepts that cost for the reason above, and pays what that rule asks of every quiet option: a detector. `SafeUser` never stands without a `LoggedUser` beneath it, so every fallback that fires leaves a record.

## Share by Composing, Not Mixing

When `JsonUser`, `JsonInvoice`, and `JsonPokemon` all read a JSON map the same way, the `_field` helper recurs three times — the point at which [`universal.md`](universal.md) says to lift it. Lift it into a small object the concrete keeps private, not into a mixin. A mixin shared across files sees only its host's public members, so the host must expose what the mixin reads — the map turns public to feed it. Composition shares the code and keeps the field private:

```dart
final class JsonFields {
  JsonFields(this._json);
  final Map<String, dynamic> _json;

  T field<T>(String key) {
    final value = _json[key];
    if (value is T) return value;
    throw FormatException('"$key" is not a $T', _json);
  }
}

final class JsonUser implements User {
  JsonUser(Map<String, dynamic> json) : _fields = JsonFields(json);
  final JsonFields _fields;
  @override String name() => _fields.field<String>('name');
  @override int age() => _fields.field<int>('age');
}
```

No try/catch in `JsonFields` — that is a decorator's job. The composed `JsonUser` is still a `User`, so it wraps into `SafeUser`, `LoggedUser`, or any other decorator just like the simpler form.

A capability that some domain objects bear and others do not — `Comparable`, `Auditable` — is an interface the concrete `implements`, not a mixin. Nothing outside the UI layer takes a mixin: not Data (domain models included), the web API adapter, nor the composition root. Inside the UI layer, a mixin yields only in a class the framework asks you to extend — a `State` — and only for a contract tied to that `State`'s lifecycle: `SingleTickerProviderStateMixin`, `AutomaticKeepAliveClientMixin`, `RestorationMixin`. Prefer the framework's higher-level widget (an implicit animation) first; where a framework type can be held instead (a `ValueNotifier` exposed as a `ValueListenable`), hold it. This guide declares no mixin of its own.

## No Statics

A `static` method or field belongs to the class name, not to an instance. It cannot be overridden, cannot be substituted in a test, cannot be wrapped by a decorator — it sits outside the seam entirely. To call `User.parse(json)` is to bypass the very shape this guide stands for: the seam, the concrete, the decorator chain. The seam loses its purpose the moment a caller can reach past it.

Refuse statics in domain code:

- `static User parse(Map<String, dynamic> json)` — make it a `JsonUser` constructor.
- `static int compare(User a, User b)` — make it a method on `User`, or a free function outside the class.
- `static const defaultUser` — make it a `ConstUser` instance the caller composes.

**Extensions are not a loophole.** An extension method is statically dispatched too — it cannot be overridden, and a decorator cannot wrap it. It earns a place that a static does not because it reaches *through* the seam: `isAdult` calls `age()`, so every decorator layered around `age()` still applies. Two tests admit it: it is computed from the seam's own methods alone, and every concrete should answer it the same way. If a concrete or a decorator would ever need to answer differently, the behavior is not derived — declare it on the interface.

The rule yields only at the framework boundary, where the framework's contract bears the static — Flutter's `Widget.of(context)`, route name constants on a route class, and the like. Outside those seams, a static is a sign the design has slipped into procedural shape: lift it onto the seam, push it into a concrete, or let it stand as a free function with no class wrapping it.

## Why This Shape

The sections above give each rule its own reason. Taken together, they buy:

- **Callers depend on the concept**, not the source. A method that takes `User` works the same whether the user came from JSON, DTO, or const.
- **Sources cleave cleanly.** Adding `SqlUser` touches one new file; no existing class needs editing.
- **Substitution stays cheap.** A test can supply a `ConstUser` wherever production passes a `JsonUser`.
