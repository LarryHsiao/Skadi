# React Style Guide

## Hook dependency arrays

The dependency array of `useEffect`, `useCallback`, `useMemo`, `useImperativeHandle`, and `useLayoutEffect` carries one duty: declare the reactive values the body reads, so the hook re-fires only when those values change. The opposite duty — listing values whose identity *cannot* change between renders — earns nothing. The hook will not re-fire on a stable value; naming it in the array is line noise that misleads the next reader into thinking the hook depends on it.

React guarantees stable identity for these:

- The **setter** returned by `useState` — `setX` in `const [x, setX] = useState(...)`.
- The **dispatch** returned by `useReducer` — `dispatch` in `const [state, dispatch] = useReducer(...)`.
- The **action-state setter** returned by `useActionState` (React 19+).
- A `useRef` instance itself; and `ref.current` is not reactive in the dep-array sense at all.

Omit them. The lint rule `react-hooks/exhaustive-deps` already hard-codes these as stable (the check lives in `ExhaustiveDeps.ts` in `eslint-plugin-react-hooks`) and will not warn on their absence. The React docs say plainly:

> "The `set` function has a stable identity, so you will often see it omitted from Effect dependencies, but including it will not cause the Effect to fire. If the linter lets you omit a dependency without errors, it is safe to do."

When a reviewer — human or bot — suggests adding a stable setter to the array, point at this rule and at the React docs; do not add it. Where a bot's reasoning rests on "the linter will warn", verify the project's `eslint.config.js` actually enables `react-hooks/exhaustive-deps` before acting on the advice — the bot may be reasoning against a config the project does not run.

## Initializing useState with a typed empty container

A `useState([])` returning an empty literal infers `useState<never[]>`. The first read of an element — `xs[0]` — types as `never`, and downstream property access either fails to compile or forces a redundant coercion (`String(item.id)` to "rescue" the value back to `string`). The rescue line hides the real flaw: the state was never named.

When the array's element type is known from the schema or DTO it will hold, name the type at the call site:

```ts
const [items, setItems] = useState<TemplateItem[]>([]);
```

Now `items[0]` is `TemplateItem`, `items[0].id` is `string`, and the downstream code reads the field plainly — no cast, no wrapper.

The same care applies to other empty initializers:

- `useState<Map<string, User>>(new Map())` — `useState(new Map())` alone infers `Map<unknown, unknown>`.
- `useState<Foo | null>(null)` — `useState(null)` alone infers `null` and rejects any later non-null assignment.
- `useState<Set<string>>(new Set())` — same shape; the empty container cannot speak for the type it will hold.

The rule generalizes to one principle: **when the initial value is a blank slate, the slate cannot speak for the type it will hold**. Name the type yourself, or the inferred `never` (or `unknown`, or `null`) will leak through every subsequent read.
