# @Observable documents and `objectWillChange`

`PhosphorMetalDocument` and `PhosphorBundleDocument` are `@Observable` classes
that also conform to `ReferenceFileDocument`. That combination puts two
change-tracking systems on the same type, and the interaction is easy to
misread. This is what's actually going on.

## The situation

`ReferenceFileDocument` refines `ObservableObject`, so any document type must
supply an `objectWillChange` publisher. Both documents are also `@Observable`,
which is the modern Observation-based mechanism and the one SwiftUI actually
uses here — the views bind with `@Bindable var document: …`.

So the type carries both conformances, but only one of them does any work.

Both documents declare:

```swift
@ObservationIgnored let objectWillChange = ObservableObjectPublisher()
```

## What that line does and doesn't do

Measured on Xcode 27 / macOS 27 SDK with a macOS 26 deployment target:

- **It is not required to compile.** Removing it from both documents still
  builds. `ObservableObject` supplies a default `objectWillChange` whenever the
  publisher type is `ObservableObjectPublisher`, and that default satisfies
  `ReferenceFileDocument`.
- **It is never published to.** Nothing in the app calls
  `objectWillChange.send()`, and `@Observable` doesn't drive it. Whether the
  explicit property or the compiler-supplied default is used, the publisher
  stays silent either way.
- **SwiftUI doesn't watch it.** Change tracking flows through Observation via
  `@Bindable`, not through this publisher.

The older comment on the property said the property was needed "since the
default synthesis doesn't fire". That runs two different things together:
synthesis (which does happen, which is why removing the line still compiles)
and firing (which is a runtime matter, and doesn't apply because nothing sends
on it). The line is explicit documentation of a protocol requirement, not a
load-bearing shim.

## Why keep it

It's kept because being explicit about a satisfied-but-unused requirement is
worth a line, and because deleting it changes which publisher instance the
conformance resolves to. That's a behavioural difference on paper, even if
nothing observes it — and see the caveat below on why that hasn't been
confirmed on device.

If you do delete it, delete it from both documents together, and re-check the
save/open/undo behaviours listed below.

## Not verified

The risk originally logged with this (issue #124) was that dual
`ObservableObject` + `@Observable` conformance could cause change-tracking
glitches at runtime, and that has **not** been exercised. Specifically
untested: save, open, Save As, and undo/redo on a macOS 26 deployment.

If glitches do show up, the fallbacks are to drop `@Observable` in favour of
`@Published`, or to wrap the document in a separate observable model rather
than conforming one type to both systems.
