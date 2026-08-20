# Code Smell Cards

Detection-oriented. No narrative. Signals → Treat → Ignore.
Full catalog condensation from articles/refactor-guru/Refactoring/. Prune as needed.

---

## Bloaters

### Long Method
- **Signals:** body ≳ 10–15 lines; nested conditionals/loops; internal comments explaining sections; mixed levels of abstraction; multiple responsibilities
- **Treat:** Extract Method (primary). Blocking temps/params → Replace Temp with Query / Introduce Parameter Object / Preserve Whole Object. Extreme local-variable tangle → Replace Method with Method Object. Branches → Decompose Conditional. Loops → Extract Method on loop body
- **Ignore:** pure linear transform with clear name and no natural seams; measured hot path after profiling

### Large Class
- **Signals:** many fields + methods + LOC; hard to state single responsibility in one sentence; multiple reasons to change
- **Treat:** Extract Class (cohesive field+method subset); Extract Subclass (variant/rare behavior); Extract Interface (client contract); GUI/domain split → Duplicate Observed Data when needed
- **Ignore:** intentional facade/aggregator; pure DTO/generated container

### Primitive Obsession
- **Signals:** primitives for domain concepts (money, range, phone, coordinates, status); constants encoding types/roles; stringly-typed array indices or field names
- **Treat:** Replace Data Value with Object; Introduce Parameter Object / Preserve Whole Object; Replace Type Code with Class / Subclasses / State-Strategy; Replace Array with Object
- **Ignore:** truly primitive values with no behavior, invariants, or domain meaning

### Long Parameter List
- **Signals:** >3–4 parameters; parameters often derived from the same object or travel together
- **Treat:** Replace Parameter with Method Call (if computable inside); Preserve Whole Object; Introduce Parameter Object
- **Ignore:** removing parameters would create undesirable inter-class dependency

### Data Clumps
- **Signals:** identical groups of variables/fields/params appear in multiple places; deleting one value makes the others senseless
- **Treat:** Extract Class (fields); Introduce Parameter Object (params); Preserve Whole Object; move related behavior onto the new class
- **Ignore:** coincidental groups; object introduction would create worse coupling

---

## Object-Orientation Abusers

### Switch Statements
- **Signals:** complex switch or if-else chains (especially on type/status codes); same switch logic repeated across methods
- **Treat:** Extract Method + Move Method to isolate; Replace Type Code with Subclasses or State/Strategy; then Replace Conditional with Polymorphism; few similar calls with different params → Replace Parameter with Explicit Methods; null case → Introduce Null Object
- **Ignore:** simple stable switches; factory selection patterns

### Temporary Field
- **Signals:** fields set/used only under specific conditions; otherwise null/empty; algorithm inputs promoted to fields to avoid long param lists
- **Treat:** Extract Class (or Replace Method with Method Object) for the algorithm + its temps; Introduce Null Object for existence checks
- **Ignore:** rare legitimate optional state with clear lifecycle

### Refused Bequest
- **Signals:** subclass uses only a subset of inherited members; unused inherited methods; overrides that throw or no-op
- **Treat:** Replace Inheritance with Delegation (if hierarchy is wrong); or Extract Superclass of the truly shared part and re-parent
- **Ignore:** framework base classes that force broad interfaces

### Alternative Classes with Different Interfaces
- **Signals:** two classes do the same job but expose different method names/signatures
- **Treat:** Rename Method to unify; Move Method / Add Parameter / Parameterize Method to align signatures; partial overlap → Extract Superclass; then delete the redundant class
- **Ignore:** classes live in separate third-party libraries that cannot be merged

---

## Change Preventers

### Divergent Change
- **Signals:** one class requires many unrelated method changes for different kinds of modification (e.g. new product type touches find + display + order)
- **Treat:** Extract Class to split responsibilities; shared behavior across classes → Extract Superclass / Extract Subclass
- **Note:** opposite of Shotgun Surgery

### Shotgun Surgery
- **Signals:** one conceptual change requires many small edits across many classes
- **Treat:** Move Method / Move Field to concentrate responsibility (create target class if none exists); emptied shells → Inline Class
- **Note:** opposite of Divergent Change; often follows over-aggressive splitting

### Parallel Inheritance Hierarchies
- **Signals:** adding a subclass in one hierarchy forces adding a subclass in another
- **Treat:** make instances of one hierarchy refer to the other; then Move Method / Move Field and remove the duplicate hierarchy
- **Ignore:** when de-duplication produces worse architecture than living with the parallel structure

---

## Dispensables

### Comments (as deodorant)
- **Signals:** explanatory comments on non-obvious code; comments restating what code does
- **Treat:** Extract Variable (complex expressions); Extract Method (commented sections — name from the comment); Rename Method; Introduce Assertion for required state
- **Keep:** comments explaining *why*, trade-offs, or irreducible algorithms after simplification attempts

### Duplicate Code
- **Signals:** identical or near-identical fragments in multiple places
- **Treat:** same class → Extract Method; same-level subclasses → Extract Method + Pull Up Field / Pull Up Constructor Body / Form Template Method; different algorithms same result → Substitute Algorithm; unrelated classes → Extract Superclass or Extract Class + share; identical conditional results → Consolidate Conditional Expression + Extract Method; identical code in all branches → Consolidate Duplicate Conditional Fragments
- **Ignore:** accidental similarity expected to diverge; rare cases where merging reduces clarity

### Data Class
- **Signals:** class holds only fields + getters/setters; no real behavior; clients operate on its data
- **Treat:** Encapsulate Field / Encapsulate Collection; Move Method / Extract Method of client behavior onto the data class; then Remove Setting Method / Hide Method to tighten access
- **Ignore:** intentional DTOs at system boundaries (serialization, API payloads) — still prefer immutability where possible

### Dead Code
- **Signals:** unused variable, parameter, field, method, class, or unreachable branch
- **Treat:** delete; unneeded class → Inline Class / Collapse Hierarchy; unused params → Remove Parameter
- **Note:** confirm with search + tests; public API → deprecate first

### Lazy Class
- **Signals:** class does almost nothing; cost of understanding exceeds value
- **Treat:** Inline Class; thin subclasses → Collapse Hierarchy
- **Ignore:** intentional placeholder for near-term planned work (balance clarity vs simplicity)

### Speculative Generality
- **Signals:** unused abstract class/interface, dead parameter, unused hook, single-concrete hierarchy, “just in case” extension points
- **Treat:** Collapse Hierarchy; Inline Class / Inline Method; Remove Parameter; delete unused fields
- **Ignore:** framework extension points required by consumers; test-only hooks needed by the suite

---

## Couplers

### Feature Envy
- **Signals:** method uses more data/methods of another class than its own; heavy getter chains on foreign object
- **Treat:** Move Method to the envied class; partial envy → Extract Method then Move the part; multi-class use → move to the class owning most of the data, or split
- **Ignore:** intentional Strategy/Visitor/policy separation of behavior from data

### Inappropriate Intimacy
- **Signals:** class reaches into another’s internals (fields, non-public methods); mutual over-dependence
- **Treat:** Move Method / Move Field; Extract Class + Hide Delegate; mutual dependency → Change Bidirectional Association to Unidirectional; subclass/superclass intimacy → consider Replace Delegation with Inheritance (or the reverse)
- **Ignore:** rare tightly-coupled pairs that are conceptually one unit and will not be reused independently

### Incomplete Library Class
- **Signals:** need additional behavior on a library/third-party class you cannot modify
- **Treat:** few methods → Introduce Foreign Method (method on client that takes the library object as first arg); many methods → Introduce Local Extension (subclass or wrapper)
- **Ignore:** when extension cost exceeds benefit or library updates will break the extension frequently

### Message Chains
- **Signals:** `a.b().c().d()` style navigation; client depends on intermediate structure
- **Treat:** Hide Delegate; or Extract Method of the ultimate purpose and Move Method toward the front of the chain
- **Ignore:** over-hiding creates Middle Man; balance against that smell

### Middle Man
- **Signals:** class mostly delegates; little or no unique behavior
- **Treat:** Remove Middle Man (have clients call the delegate directly)
- **Ignore:** intentional Proxy, Decorator, or dependency firewall; deliberate decoupling layer
