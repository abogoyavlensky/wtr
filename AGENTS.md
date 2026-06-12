# Agent Notes

## let-go language specifics

This project is written in let-go, a Clojure-like language. Differences that matter:

- **Catch forms**: let-go accepts bare `(catch e body)` and Clojure-style `(catch Exception e body)`; any class-shaped symbol (`Exception`, `Throwable`, ...) acts as a catch-all. ClojureScript-style `(catch e :default body)` compiles but evaluates `:default` as dead body code. Use the Clojure style — clj-kondo and editors understand it.
- **Built-in namespaces**: `io`, `os`, and `test` are built into the runtime; they have no source files but can be required like normal namespaces (e.g. `[io :as io]`). Clojure names alias to them (`clojure.test` → `test`, `clojure.string` → `string`). Prefer the `clojure.*` names in requires so standard Clojure tooling resolves them.
