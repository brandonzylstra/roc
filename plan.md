# Monotype Specialization Store Implementation Plan

## Goal

Implement the monotype specialization store described in `design.md`:

- direct specialization lookup by checked callable identity and closed function
  type;
- immutable interned Monotype type nodes with cached digests and exact equality;
- read-only program views that can be backed by mapped cache files;
- shard-aware function slots so cached specializations can be loaded without
  rewriting function bodies;
- deterministic correctness checks that do not depend on timing benchmarks.

The performance target is to make generic higher-order wrappers scale with the
number of distinct closed types and reachable functions, not with repeated
recursive hashing or per-family specialization scans.

## Completion Criteria

- [x] `lowerTemplateWithMonoFor`, `reserveTemplateWithMonoFor`, and nested
      specialization lowering use direct `SpecStore` lookup and reservation.
- [x] Specialization lookup never linearly scans all records for one callable
      family.
- [x] A digest match is always followed by exact callable and type equality
      before a specialization is reused.
- [x] Monotype type nodes visible outside an active builder are immutable.
- [x] Recursive type groups, records, tags, functions, named types, aliases, and
      opaque types have stable digests and exact equality.
- [x] Record and tag rows are normalized once during Monotype type construction.
- [x] Function bodies can be represented by a read-only `MonoProgramView`.
- [x] Calls can target local functions or imported functions from loaded shards.
- [x] `SpecializationCacheFile` can be written, mapped, validated, and consumed
      without per-body pointer fixups.
- [x] Cache validity is computed only from data Monotype specialization consumes.
- [x] A cache hit and a fresh build produce equivalent Monotype program views.
- [x] The issue-9802 stress programs show bounded deterministic counters for
      specialization lookup and type digest work.
- [x] Deferred specialization requests carry the reserved function id and lower
      that exact placeholder, so later type-graph mutation cannot create a
      duplicate specialization and leave calls pointing at an unlowered stub.
- [x] Existing monotype, lifted, Lambda Solved, Lambda Mono, LIR, ARC, and
      backend tests pass.
- [x] Debug boundary checks reject malformed Monotype output before later stages
      consume it.

## Phase 1: Guard Rails And Repro Coverage

- [x] Add same-type and growing-structural versions of the issue-9802 program as
      compiler stress inputs.
- [x] Keep these tests free of timing assertions.
- [x] Add debug-only Monotype counters behind an explicit flag, for example:
      specialization requests, specialization hits, specialization misses,
      spec records scanned, recursive digest calls, interned type nodes, row
      normalization calls, and closed function types created.
- [x] Make the counters compile away or remain unreachable in release builds.
- [x] Record current counter values for the stress inputs before changing the
      lowering architecture.
- [x] Add a small test for a digest collision path by using a test-only digest
      provider and verifying exact equality prevents an incorrect reuse.
- [x] Add a recursive-type digest/equality test before changing the type store.
- [x] Add a row-order test that proves differently ordered source rows produce
      one normalized Monotype row.
- [x] Add a row-order guard that proves differently ordered source rows do not
      escape Monotype lowering unsorted.
- [x] Add a module-boundary test where an imported generic function and a local
      generic function produce the same reachable specialization behavior.

## Phase 2: Data Model Decisions

- [x] Define the final POD structs in `src/postcheck/monotype/type.zig`:
      `MonoTypeNode`, `MonoTypeTag`, side-pool spans, digest arrays, and row
      payload entries.
- [x] Define `MonoTypeStore` as a read-only view over node and side-pool slices.
- [x] Define `MonoTypeInterner` as the mutable builder for `MonoTypeStore`.
- [x] Define `SpecIdentity`, `CallableIdentity`, `SpecStatus`, `SpecRecord`,
      and `SpecId` in the monotype module.
- [x] Implement `SpecBuilder` in the monotype module that owns specialization
      lowering.
- [x] Define shard-aware call target data: `ShardId`, `FnSlot`, `ImportedFnId`,
      and `ImportedFn`.
- [x] Define `MonoProgramBuilder` and `MonoProgramView` in
      `src/postcheck/monotype/ast.zig`.
- [x] Decide which existing ids remain local to a shard and which ids need a
      shard-aware wrapper.
- [x] Ensure all durable structs use fixed-width integers, enum tags with fixed
      backing types, spans, and offsets.
- [x] Keep allocator-owned arrays, hash maps, union-find nodes, and worklists
      out of every durable struct.
- [x] Define `compiler_layout_hash` inputs: struct sizes, alignments, enum tag
      values, section order, and serialization format version.
- [x] Document the `SpecializationCacheFile` header values in comments beside
      the code that writes them.

## Phase 3: Immutable Monotype Type Store

- [x] Implement child-first construction helpers:
      `internPrimitive`, `internFunc`, `internRecord`, `internTagUnion`,
      `internTuple`, `internList`, `internNamed`, `internBox`, and
      `internErased`.
- [x] Normalize record fields by explicit field-name ids before interning.
- [x] Normalize tag variants by explicit tag-name ids before interning.
- [x] Preserve tag payload position order inside each variant.
- [x] Compute node digests from the node tag, metadata, ordered child digests,
      field names, tag names, payload positions, and named-type identity.
- [x] Store the digest once beside each interned node.
- [x] Implement exact equality for every node tag and side-pool shape.
- [x] Make interner lookup use digest first, then exact equality.
- [x] Make digest collision tests exercise two non-equal nodes with the same
      forced digest.
- [x] Implement recursive group handling before exposing `TypeId` values outside
      the interner.
- [x] Add debug verification that all side-pool spans are in bounds and sorted
      where sorting is required.
- [x] Remove recursive `typeDigest` calls from specialization lookup hot paths.
- [x] Keep a compatibility-free final API: callers ask the interner for an
      immutable `TypeId`, not for a mutable slot that can be refilled later.

## Phase 4: Instantiation Graph Finalization

- [x] Audit `src/postcheck/monotype/solve.zig` for all mutable type output
      points: `monoFor`, `fillMono`, `importMono`, row flattening, row
      unification, and type cloning.
- [x] Add an `InstGraph.sealMono` primitive that copies a graph-owned mutable
      Monotype view into a non-view `TypeId`, preserving recursive references
      privately and proving later graph refills cannot mutate the sealed copy.
- [x] Add an `InstGraph.sealNode` primitive that materializes directly from
      graph nodes instead of reading draft `Type.Store` spans.
- [x] Use node-based sealing for nominal backing type-only instantiation, where
      the caller already owns the exact checked graph node to seal.
- [x] Use node-based sealing for the isolated parser method-target type
      inference path instead of returning a draft `monoFor` view from a
      temporary graph.
- [x] Use node-based sealing for the isolated `to_inspect` target type
      inference path while preserving draft views for active-graph callers.
- [x] Verify that the generic sealer is not safe to use at arbitrary existing
      production graph boundaries until body drafts translate every field name,
      tag payload span, declared-field span, and type side-pool explicitly.
- [x] Add range-based body draft finalization that seals graph-owned type views
      in emitted functions, definitions, nested definitions, expressions,
      patterns, locals, typed locals, and specialization identities before the
      graph is destroyed.
- [x] Delay nested specialization ready records until the containing graph draft
      has been sealed.
- [x] Update local specialization records when a solved draft function type is
      replaced by its sealed function type, so the direct lookup table and
      durable record use the final immutable identity.
- [x] Replace eager final `TypeId` creation with graph-node ids while solving is
      active.
- [x] Introduce a body draft representation for lowering that can hold graph
      node ids for expression, pattern, binder, and function-signature types.
- [x] Seal a body draft only after its instantiation graph is closed.
- [x] During sealing, map every graph node used by the draft to an immutable
      `TypeId` in `MonoTypeStore`.
- [x] Detect unresolved nodes during sealing and lower truly unconstrained
      variables to the empty tag union according to the existing invariant.
- [x] Treat any node that cannot be closed from checked data as a compiler bug.
- [x] Preserve the rule that deferred procedure-template body requests are made
      only after the requesting specialization has stable closed types.
- [x] Preserve the rule that nested function bodies share the requesting graph.
- [x] Keep nested function body drafts associated with the same graph until the
      graph is sealed.
- [x] Update call lowering to communicate caller and callee types through
      explicit checked type relations and closed Monotype types.
- [x] Update closure and lambda lowering so expected function types constrain
      nested specialization requests before body sealing.
- [x] Add debug checks that no graph node id escapes into a completed
      `MonoProgramView`.

## Phase 4B: Full Body Draft Rewrite

This phase replaces the current range-sealing bridge with the final design from
`design.md`: active specialization lowering writes draft records that can carry
instantiation graph node ids, and final Monotype arrays receive only sealed
immutable `TypeId`s after the graph is closed.

- [x] Add a `DraftTypeCell` representation with exactly two cases:
      `graph_node: NodeId` for active-graph-owned type cells and
      `sealed: Type.TypeId` for closed types that were materialized before the
      graph opened.
- [x] Add debug checks that `DraftTypeCell.sealed` is used only for closed types
      with no active graph-view children.
- [x] Add a `BodyDraftStore` that mirrors final Monotype body sections:
      functions, definitions, nested definitions, expressions, patterns,
      statements, locals, typed locals, ids, side-pool spans, layout requests,
      runtime schema requests, roots, and compile-time metadata.
- [x] Make draft ids distinct from final `Ast.*Id`s so an active draft cannot be
      accidentally consumed by Monotype Lifted, Lambda Solved, LIR, or cache
      serialization.
- [x] Introduce draft expression, pattern, local, typed-local, function-template,
      definition, nested-definition, layout-request, and runtime-schema-request
      records whose type-bearing fields store `DraftTypeCell`.
- [x] Keep non-type fields in draft records in the same normalized order and
      representation as the final Monotype records, so sealing is a mechanical
      copy plus type/id/span translation.
- [x] Add draft side-pool builders for expression ids, pattern ids, statement
      ids, typed locals, record fields, tag payloads, declared fields, branches,
      if branches, string pattern steps, and debug/source metadata.
- [x] Route body-lowering creation through draft append helpers instead of
      calling `ProgramBuilder.addExpr`, `addPat`, `addLocal`,
      `addTypedLocalSpan`, `addFn`, or direct final-array appends while an
      instantiation graph is active.
- [x] Replace active body type ownership with node-returning APIs such as
      `lowerTypeNode` and `lowerExprTypeNode`; keep temporary active `TypeId`
      views only as shape-inspection adapters that are converted back to
      `DraftTypeCell.graph_node` before draft publication.
- [x] Replace active-body `graph.monoFor` call sites with node refs or with
      node-composition helpers that return `NodeId`.
- [x] Replace active-body `graphFunctionType` helpers with graph function-node
      constructors that return `NodeId`; materialize the function type only at
      draft sealing or when forming a closed external specialization request.
- [x] Update local binder restoration and copied binder constraints to use
      draft local type cells rather than reading mutable final local `TypeId`
      fields.
- [x] Update lambda and closure lowering so expected function types are
      represented as graph function nodes until their nested specialization
      request is sealed.
- [x] Update call lowering so caller and callee communicate through explicit
      checked type relations and imported sealed types, while active call
      result, argument, and callee function types are stored as graph nodes
      inside the draft and temporary shape views are not published.
- [x] Update generated helper lowering for parser runtime, encode-to runtime,
      inspection, structural equality, structural hashing, and source loops so
      all active-body generated expressions and patterns are appended to the
      draft store.
- [x] Keep hosted and imported-cache function records sealed when they are
      already closed before the graph opens, and import them into the graph only
      when the active body needs to constrain against them.
- [x] Seal deferred procedure-template requests before lowering reserved bodies:
      drain the requesting graph, convert the request function node to an
      immutable `TypeId`, update the spec identity, then lower the reserved body
      from that stable request.
- [x] Keep nested function drafts attached to the parent graph and append them
      to the final program only after the parent graph seals.
- [x] Implement a single draft sealing pass that drains dirty nodes, rejects
      remaining deferred requests, closes every `DraftTypeCell.graph_node`
      through `GraphTypeFinals.sealNode`, verifies every `DraftTypeCell.sealed`
      contains no graph views, and writes final records to `ProgramBuilder`.
- [x] During sealing, translate draft ids and spans to final shard-local ids and
      spans exactly once.
- [x] During sealing, update `SpecRecord` identities and the direct
      specialization lookup table when a request function graph node seals to a
      different immutable `TypeId` than the original request snapshot.
- [x] Delete range-based final-array sealing once no active lowering path writes
      graph views into final arrays.
- [x] Delete or make private any `InstGraph.monoFor` API that can expose a
      mutable graph view to final Monotype arrays.
- [x] Keep `InstGraph.importMono` for importing closed snapshots into a graph,
      but make it return graph nodes only.
- [x] Add an architecture check that rejects new active-body calls to
      `ProgramBuilder.addExpr`, `addPat`, `addLocal`, `addTypedLocalSpan`, and
      direct final-array appends from `BodyContext` lowering code.
- [x] Add debug verification that completed `MonoProgramView` type ids are all
      immutable interner ids and that no final type recursively contains a graph
      view.
- [x] Add tests for recursive body-local types, nested function signatures,
      closure expected types, generated opaque evidence, parser/encoder helpers,
      source loops, structural equality, structural hashing, and imported
      specialization calls under the draft sealing path.
- [x] Add a cache round-trip test that builds with the draft path, writes a
      specialization cache file, maps it back, and confirms no per-body fixups
      are needed.

## Phase 5: Direct Specialization Store

- [x] Implement `SpecBuilder.reserve(identity, fn_ty)` that returns an existing
      `SpecId` only after digest and exact type checks succeed.
- [x] Implement `SpecBuilder.markLowering(spec)` and
      `SpecBuilder.markReady(spec, fn)`.
- [x] Represent recursive specialization requests with `reserved` and `lowering`
      records instead of duplicate function bodies.
- [x] Replace `lowered_templates` per-family arrays with the direct store.
- [x] Replace nested-function specialization arrays with the direct store.
- [x] Update `lowerTemplateWithMonoFor` to perform one direct lookup or reserve.
- [x] Update `reserveTemplateWithMonoFor` to avoid per-family linear scans.
- [x] Update `lowerNestedFnRequest` to use the same identity and exact equality
      rules.
- [x] Store source function type digest and closed function type digest once in
      each `SpecRecord`.
- [x] Ensure source callable identity includes checked module id, procedure
      template id, nested site id, and owner function digest where needed.
- [x] Add tests for two nested sites with equal function types but different
      checked sites.
- [x] Add tests for one nested site specialized at two different closed function
      types.
- [x] Add tests for one top-level generic function reached through multiple
      call paths at the same closed function type.

## Phase 6: Program Builder And Read-Only View

- [x] Split the current monotype `Program` into a mutable builder and a
      read-only view.
- [x] Move all allocator-owned arrays and hash maps to the builder side.
- [x] Keep the view as slices, spans, ids, and fixed records only.
- [x] Convert Monotype Lifted lowering to consume `MonoProgramView`.
- [x] Convert Lambda Solved input code to consume the view shape.
- [x] Convert debug Monotype verification to consume the view shape.
- [x] Replace direct function ids in call sites with `FnSlot` where cross-shard
      calls are possible.
- [x] Keep single-shard builds using local function slots only until cache
      loading is introduced.
- [x] Add a debug verifier that all local function slots point into the owning
      shard and all imported slots point into the import table.
- [x] Add debug verification that local direct-call arity and local function
      definition arity match their source Monotype function types.
- [x] Add tests that fresh single-shard lowering produces the same function call
      graph as the old program representation.

## Phase 7: Specialization Cache File

- [x] Add `src/postcheck/monotype/serialize.zig`.
- [x] Reuse the existing serialized-slice pattern for offset and length
      sections.
- [x] Define the `SpecializationCacheHeader` exactly once in code and keep it
      synchronized with `design.md`.
- [x] Write cache files with sorted sections and alignment padding.
- [x] Validate magic, format version, compiler layout hash, validity id, section
      bounds, section alignment, and section ordering before constructing a
      view.
- [x] Map a valid file's top-level sections into typed process slices.
- [x] Map a valid file and create `MonoProgramView` by converting top-level
      file slices to process slices.
- [x] Assign one `ShardId` to each mapped file.
- [x] Resolve import table entries to loaded shards and function ids once.
- [x] Avoid per-expression, per-type, per-pattern, and per-function pointer
      rewrites.
- [x] Add round-trip tests for empty programs, one function, nested functions,
      imported calls, records, tags, named types, and recursive types.
- [x] Add a test that a mapped cache view can be consumed after the original
      builder allocations have been freed.
- [x] Add malformed-file tests for bounds, alignment, bad section order, bad
      version, and wrong validity id.
- [x] Treat a matching cache file with malformed internal data as compiler cache
      corruption rather than silently using another lowering result.

## Phase 8: Cache Integration

- [x] Define the validity id builder for Monotype specialization files.
- [x] Include root checked module id and every checked module id read by stored
      specializations.
- [x] Include the explicit root request set.
- [x] Include Monotype configuration that can affect reachable specializations.
- [x] Include builtin module data consumed by Monotype.
- [x] Include source callable identities and source function type digests for
      stored specialization records.
- [x] Exclude LIR layout decisions, ARC output, backend symbols, object-format
      choices, pointer width, and code-generation options from Monotype cache
      validity.
- [x] Load candidate shards before root specialization begins.
- [x] Insert loaded `SpecRecord` entries into the transient direct lookup table.
- [x] Verify loaded records with the same exact identity and type checks used
      for fresh records.
- [x] Lower missing specializations normally when no loaded record matches.
- [x] Write newly completed specializations to a new cache file only after the
      full Monotype program view verifies.
- [x] Use atomic file replacement for completed cache writes.
- [x] Keep cache writes disabled for failed compilations.
- [x] Add a build option or internal flag to disable specialization cache reads
      and writes for debugging.
- [x] Add a test that disabling cache use does not change Monotype output.
- [x] Add a test that cache read plus fresh missing specialization write creates
      the same final program as a no-cache build.

## Phase 9: Checked Type Root Output Cleanup

- [x] Audit checked type root output for repeated construction of equivalent
      normalized type payloads.
- [x] Memoize checked type root payloads during checked module output where the
      checker already has explicit type identity.
- [x] Keep the memoization inside checked module output; do not make Monotype
      rediscover missing checked relations.
- [x] Preserve checked module cache validity rules when changing the stored type
      root format.
- [x] Add tests that repeated expression roots with the same checked type do not
      produce duplicated stored payloads when the payload can be shared exactly.
- [x] Add tests that distinct checked variables with equal shape remain distinct
      where Monotype instantiation needs distinct graph nodes.

## Phase 10: Verification

- [x] Run unit tests for the monotype type store, type interner, spec store,
      serializer, and cache loader.
- [x] Run integration tests for local generics, imported generics, nested
      lambdas, closures, static dispatch, structural equality, named types,
      opaque types, records, tags, tuples, lists, and recursive types.
- [x] Run the issue-9802 same-type stress input and confirm direct lookup hits
      after the first closed function type is produced.
- [x] Run the issue-9802 growing-structural stress input and confirm digest work
      grows with interned nodes rather than repeated full-prefix walks.
- [x] Run fuzz tests that generate small typed higher-order programs rather
      than cataloged scenario emitters.
- [x] Run `zig build run-test-zig` once the focused unit and integration tests
      pass.
- [x] Run `zig build minici`; when one section fails, fix that section and rerun
      the section before returning to the full command.
- [x] Run `zig build roc`.
- [x] Run Windows CLI and glue tests through
      `/Users/rtfeldman/.agents/roc-windows.sh` after macOS tests pass.
- [x] Confirm release builds do not retain debug-only verifier work or counter
      overhead.
- [x] Record that clean-machine timing must be captured on an otherwise quiet
      machine or dedicated benchmark host after this branch lands; this worktree
      is suitable for deterministic counters and correctness tests, not timing
      conclusions.

## Deletion Checklist

- [x] Delete old per-family specialization scan code.
- [x] Delete old recursive digest recomputation from specialization lookup.
- [x] Delete mutable Monotype type refill APIs that expose final `TypeId` values
      before the type is sealed.
- [x] Delete builder hash maps from any data path that is written to a cache
      file.
- [x] Delete any Monotype consumer dependency on allocator-owned program arrays.
- [x] Delete any call-site assumption that all functions live in one local
      function id space.
- [x] Delete any cache loading code that rewrites expression or function body
      arrays after mapping.

## Review Checklist

- [x] Every post-check stage consumes explicit data from the previous stage.
- [x] No backend code learns anything new about reference counting.
- [x] No checked module stores post-check specialization, layout, callable
      representation, ARC, or backend data.
- [x] Monotype specialization remains target-independent unless a Monotype input
      explicitly becomes target-dependent.
- [x] Every durable record has a versioned layout.
- [x] Every digest use has an exact equality check on the correctness path.
- [x] Every cache validity input is justified by a Monotype data dependency.
- [x] Every cache validity exclusion is justified by not being consumed by
      Monotype.
- [x] Module boundaries do not affect reachable specializations or callable
      behavior.
- [x] Debug invariants catch malformed Monotype output before later stages run.
