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
- [ ] Monotype type nodes visible outside an active builder are immutable.
- [x] Recursive type groups, records, tags, functions, named types, aliases, and
      opaque types have stable digests and exact equality.
- [ ] Record and tag rows are normalized once during Monotype type construction.
- [x] Function bodies can be represented by a read-only `MonoProgramView`.
- [x] Calls can target local functions or imported functions from loaded shards.
- [x] `SpecializationCacheFile` can be written, mapped, validated, and consumed
      without per-body pointer fixups.
- [ ] Cache validity is computed only from data Monotype specialization consumes.
- [ ] A cache hit and a fresh build produce equivalent Monotype program views.
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
- [ ] Record current counter values for the stress inputs before changing the
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

- [ ] Define the final POD structs in `src/postcheck/monotype/type.zig`:
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
- [ ] Decide which existing ids remain local to a shard and which ids need a
      shard-aware wrapper.
- [ ] Ensure all durable structs use fixed-width integers, enum tags with fixed
      backing types, spans, and offsets.
- [ ] Keep allocator-owned arrays, hash maps, union-find nodes, and worklists
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
- [ ] Implement recursive group handling before exposing `TypeId` values outside
      the interner.
- [x] Add debug verification that all side-pool spans are in bounds and sorted
      where sorting is required.
- [x] Remove recursive `typeDigest` calls from specialization lookup hot paths.
- [ ] Keep a compatibility-free final API: callers ask the interner for an
      immutable `TypeId`, not for a mutable slot that can be refilled later.

## Phase 4: Instantiation Graph Finalization

- [ ] Audit `src/postcheck/monotype/solve.zig` for all mutable type output
      points: `monoFor`, `fillMono`, `importMono`, row flattening, row
      unification, and type cloning.
- [ ] Replace eager final `TypeId` creation with graph-node ids while solving is
      active.
- [ ] Introduce a body draft representation for lowering that can hold graph
      node ids for expression, pattern, binder, and function-signature types.
- [ ] Seal a body draft only after its instantiation graph is closed.
- [ ] During sealing, map every graph node used by the draft to an immutable
      `TypeId` in `MonoTypeStore`.
- [ ] Detect unresolved nodes during sealing and lower truly unconstrained
      variables to the empty tag union according to the existing invariant.
- [ ] Treat any node that cannot be closed from checked data as a compiler bug.
- [ ] Preserve the rule that deferred procedure-template body requests are made
      only after the requesting specialization has stable closed types.
- [ ] Preserve the rule that nested function bodies share the requesting graph.
- [ ] Keep nested function body drafts associated with the same graph until the
      graph is sealed.
- [ ] Update call lowering to communicate caller and callee types through
      explicit checked type relations and closed Monotype types.
- [ ] Update closure and lambda lowering so expected function types constrain
      nested specialization requests before body sealing.
- [ ] Add debug checks that no graph node id escapes into a completed
      `MonoProgramView`.

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

- [ ] Split the current monotype `Program` into a mutable builder and a
      read-only view.
- [ ] Move all allocator-owned arrays and hash maps to the builder side.
- [x] Keep the view as slices, spans, ids, and fixed records only.
- [ ] Convert Monotype Lifted lowering to consume `MonoProgramView`.
- [ ] Convert Lambda Solved input code to consume the view shape.
- [x] Convert debug Monotype verification to consume the view shape.
- [x] Replace direct function ids in call sites with `FnSlot` where cross-shard
      calls are possible.
- [x] Keep single-shard builds using local function slots only until cache
      loading is introduced.
- [x] Add a debug verifier that all local function slots point into the owning
      shard and all imported slots point into the import table.
- [x] Add debug verification that local direct-call arity and local function
      definition arity match their source Monotype function types.
- [ ] Add tests that fresh single-shard lowering produces the same function call
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
- [ ] Resolve import table entries to loaded shards and function ids once.
- [x] Avoid per-expression, per-type, per-pattern, and per-function pointer
      rewrites.
- [ ] Add round-trip tests for empty programs, one function, nested functions,
      imported calls, records, tags, named types, and recursive types.
- [ ] Add a test that a mapped cache view can be consumed after the original
      builder allocations have been freed.
- [x] Add malformed-file tests for bounds, alignment, bad section order, bad
      version, and wrong validity id.
- [ ] Treat a matching cache file with malformed internal data as compiler cache
      corruption rather than silently using another lowering result.

## Phase 8: Cache Integration

- [x] Define the validity id builder for Monotype specialization files.
- [ ] Include root checked module id and every checked module id read by stored
      specializations.
- [x] Include the explicit root request set.
- [x] Include Monotype configuration that can affect reachable specializations.
- [x] Include builtin module data consumed by Monotype.
- [x] Include source callable identities and source function type digests for
      stored specialization records.
- [x] Exclude LIR layout decisions, ARC output, backend symbols, object-format
      choices, pointer width, and code-generation options from Monotype cache
      validity.
- [ ] Load candidate shards before root specialization begins.
- [ ] Insert loaded `SpecRecord` entries into the transient direct lookup table.
- [ ] Verify loaded records with the same exact identity and type checks used
      for fresh records.
- [ ] Lower missing specializations normally when no loaded record matches.
- [ ] Write newly completed specializations to a new cache file only after the
      full Monotype program view verifies.
- [ ] Use atomic file replacement for completed cache writes.
- [ ] Keep cache writes disabled for failed compilations.
- [ ] Add a build option or internal flag to disable specialization cache reads
      and writes for debugging.
- [ ] Add a test that disabling cache use does not change Monotype output.
- [ ] Add a test that cache read plus fresh missing specialization write creates
      the same final program as a no-cache build.

## Phase 9: Checked Type Root Output Cleanup

- [ ] Audit checked type root output for repeated construction of equivalent
      normalized type payloads.
- [ ] Memoize checked type root payloads during checked module output where the
      checker already has explicit type identity.
- [ ] Keep the memoization inside checked module output; do not make Monotype
      rediscover missing checked relations.
- [ ] Preserve checked module cache validity rules when changing the stored type
      root format.
- [ ] Add tests that repeated expression roots with the same checked type do not
      produce duplicated stored payloads when the payload can be shared exactly.
- [ ] Add tests that distinct checked variables with equal shape remain distinct
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
- [ ] Run fuzz tests that generate small typed higher-order programs rather
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
- [ ] Capture a clean-machine benchmark after deterministic counters show the
      expected shape.

## Deletion Checklist

- [x] Delete old per-family specialization scan code.
- [x] Delete old recursive digest recomputation from specialization lookup.
- [ ] Delete mutable Monotype type refill APIs that expose final `TypeId` values
      before the type is sealed.
- [ ] Delete builder hash maps from any data path that is written to a cache
      file.
- [ ] Delete any Monotype consumer dependency on allocator-owned program arrays.
- [ ] Delete any call-site assumption that all functions live in one local
      function id space.
- [ ] Delete any cache loading code that rewrites expression or function body
      arrays after mapping.

## Review Checklist

- [ ] Every post-check stage consumes explicit data from the previous stage.
- [ ] No backend code learns anything new about reference counting.
- [ ] No checked module stores post-check specialization, layout, callable
      representation, ARC, or backend data.
- [ ] Monotype specialization remains target-independent unless a Monotype input
      explicitly becomes target-dependent.
- [ ] Every durable record has a versioned layout.
- [x] Every digest use has an exact equality check on the correctness path.
- [ ] Every cache validity input is justified by a Monotype data dependency.
- [ ] Every cache validity exclusion is justified by not being consumed by
      Monotype.
- [ ] Module boundaries do not affect reachable specializations or callable
      behavior.
- [x] Debug invariants catch malformed Monotype output before later stages run.
