# Layered Architecture

> Applies to any app that shows data fetched from a remote service. Language-neutral; the sketch uses Dart to match [`oo.md`](oo.md), which governs how the objects inside each layer are shaped.

Code is cut into three layers — **UI**, **Data**, **Web API integration** — and one place, the **composition root**, that joins them. The layers differ in what they know, and the cut is drawn so that the part most likely to change (the transport) sits furthest from the part most likely to last (the domain).

## The Layers

| Layer | Holds | Imports |
|---|---|---|
| **UI** | screens, widgets, view-models | Data's repository interface and domain models |
| **Data** | domain models, repository interface and its default concrete, the ports it needs, cache and retry rules | nothing in the app but its own models and ports |
| **Web API integration** | API client, DTOs, DTO → domain mapping, auth, error decoding | Data's port it implements, and Data's models |
| **Composition root** | wiring at app start-up | all three, concretes included |

The UI renders state and forwards intent. Data owns the state and the rules about it. The web API layer knows the wire and nothing else.

## Dependencies Point at Data

Data sits at the centre. UI depends on it; the web API layer depends on it; it depends on neither.

```
UI  ──►  Data  ◄──  Web API integration
```

- **Data declares the interfaces; the other layers meet them.** The UI calls `OrderRepository`, which Data declares. Data needs orders from somewhere, so it declares `OrderSource` in its own words; `HttpOrderSource` in the web API layer implements it. The call runs down at run time, but the source dependency runs up.
- **Each interface belongs to its consumer.** `OrderRepository` is shaped by what the UI asks; `OrderSource` by what Data needs. Neither takes the shape of the other side's convenience.
- **UI never reaches past Data.** No web API client, no DTO, no raw HTTP in a screen, and no named concrete (`DefaultOrderRepository`) either — the UI holds the interface.
- **Data imports no transport and no UI type.** An `import` of an HTTP client, a DTO, or a widget in Data is the break to look for in review.

## The Mapping Seam

A DTO is the wire's shape, not the domain's. It is born in the web API layer and stays there: the adapter maps `OrderDto` to `Order` before anything crosses into Data, so no DTO type appears in Data or the UI. Merging two endpoints into one `Order` happens in the adapter for the same reason — only the adapter knows the remote shape.

Following [`oo.md`](oo.md), `Order` is an interface. The adapter defines the concrete `DtoOrder` that wraps the transport object and returns it wrapped for the no-throw guarantee — `SafeOrder(DtoOrder(dto))`. Only the `Order` face crosses the seam; Data and the UI never name the concrete or the DTO inside it.

`OrderSource` is a port with its own verb (`fetchOrders`), not a bare producer of a collection, so `oo.md`'s plural-name rule for read sources (`Orders`) does not apply to it.

## Failure Crosses as Data's Own Type

The adapter turns a bad status or a timeout into an exception type **declared beside the port, in Data**. The repository catches it and applies the retry or cache-fallback rule: it returns the cached `Order`s when it has them, and rethrows a Data-declared exception when nothing remains to fall back on — which the UI turns into an error state. A raw `DioException`, a status code, or a response body never reaches a screen. Per [`oo.md`](oo.md), repositories and sources are action objects — they may throw; the domain models they return do not.

## The Composition Root

One place sees every concrete and joins them at start-up:

```dart
// client: the app's configured HTTP client
final repository = DefaultOrderRepository(
  HttpOrderSource(client),
);
runApp(OrdersApp(repository)); // the root widget takes the interface
```

It holds wiring and no logic. A test that builds its own container with fakes proves the logic reading the interface, not that the real app wires the real concrete — verify the real entry point does, per the DI check in `CLAUDE.md`'s *Compliance Review*.

## Naming

- The interface takes the plain domain noun: `OrderRepository`, `OrderSource`.
- A concrete is named for what distinguishes it: `DefaultOrderRepository`, `HttpOrderSource`, `FakeOrderSource`. Never an `-Impl` suffix.
- Names are nouns, no `-er`, per [`general.md`](general.md).

## Tests

- **UI tests** fake `OrderRepository` and touch nothing below it.
- **Data tests** fake `OrderSource` and exercise the cache and retry rules without a network.
- **Adapter tests** feed recorded JSON to `HttpOrderSource` and assert on the `Order` it returns.

Each layer is tested against the interface on its far side, so a change in one layer breaks only that layer's tests.

## Where the Cut Stops

One interface per layer boundary, not one per class. Do not add an interface *inside* a layer, and do not add a repository interface for a screen that reads no remote data. A project too small to bear three layers is not obliged to grow them — but when it holds all three concerns, it holds them apart as above, and a feature that starts life in one file is split before it spreads.
