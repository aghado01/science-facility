# Technique Playbooks

Mechanical steps only. When / Steps / Caution.
Full catalog condensation. Prune as needed.

---

## Composing Methods

### Extract Method
- **When:** code fragment can be grouped and named by intent; method too long; comment needed; reuse opportunity
- **Steps:**
  1. Create new method named by intention.
  2. Copy fragment; replace original with call.
  3. Pass needed incoming locals as params (or first apply Replace Temp with Query).
  4. Return any value the caller still needs.
- **Caution:** do not extract pure pass-through or increase coupling

### Inline Method
- **When:** method body is clearer than its name, or pure delegation
- **Steps:**
  1. Confirm not overridden in subclasses.
  2. Replace all calls with the body.
  3. Delete the method.
- **Caution:** none major

### Extract Variable
- **When:** complex expression hard to understand
- **Steps:**
  1. Introduce named variable before the expression.
  2. Assign the sub-expression.
  3. Replace the sub-expression with the variable.
  4. Repeat for remaining complex parts.
- **Caution:** extracting conditions can change short-circuit evaluation

### Inline Temp
- **When:** temp holds simple expression and nothing more
- **Steps:**
  1. Replace all uses of the temp with the expression.
  2. Delete declaration and assignment.
- **Caution:** may lose caching of expensive expression

### Replace Temp with Query
- **When:** temp holds result of pure expression (assigned once) and blocks Extract Method
- **Steps:**
  1. Ensure single assignment (Split Temporary Variable if needed).
  2. Extract Method on the expression (must be side-effect free; otherwise Separate Query from Modifier first).
  3. Replace temp uses with the query call.
  4. Remove temp.
- **Caution:** performance only if expression is truly expensive and repeatedly evaluated

### Split Temporary Variable
- **When:** one local re-used for unrelated values (except loop vars)
- **Steps:**
  1. At first assignment, rename to match that value.
  2. Update uses of that value.
  3. Repeat for subsequent distinct assignments.
- **Caution:** none

### Remove Assignments to Parameters
- **When:** parameter is reassigned inside method
- **Steps:**
  1. Introduce local with the parameter’s initial value.
  2. Replace subsequent uses of the parameter with the local.
- **Caution:** especially important for reference parameters

### Replace Method with Method Object
- **When:** long method with locals too tangled for Extract Method
- **Steps:**
  1. Create new class named for the method’s purpose.
  2. Add field referencing original object (if needed for data).
  3. Add private fields for each local variable.
  4. Constructor accepts and initializes those values.
  5. Move original body into a main method on the new class, using fields.
  6. Original method becomes: create object + call its main method.
- **Caution:** adds a class; then split methods inside it

### Substitute Algorithm
- **When:** existing algorithm is replaceable by a clearer/better one
- **Steps:**
  1. Simplify the old algorithm first (Extract Method on non-core parts).
  2. Implement new algorithm in a new method.
  3. Replace call and test thoroughly.
  4. Delete old implementation once tests pass.
- **Caution:** verify behavioral equivalence carefully

---

## Moving Features between Objects

### Move Method
- **When:** method uses more of another class, or to concentrate Shotgun Surgery / Feature Envy
- **Steps:**
  1. Examine features used by the method; decide target class.
  2. Declare method in target; decide how source obtains the target reference.
  3. Move body; adjust for new context.
  4. Turn original into simple call (or delete and update callers).
- **Caution:** visibility and circular dependencies

### Move Field
- **When:** field used more by another class
- **Steps:**
  1. Encapsulate if public.
  2. Create field + accessors in target.
  3. Redirect all references.
  4. Delete original.
- **Caution:** none major

### Extract Class
- **When:** class has cohesive subset of fields + methods that belong together (Large Class, Divergent Change, Data Clumps)
- **Steps:**
  1. Decide the split and name the new class.
  2. Create new class; establish link (prefer unidirectional).
  3. Move Field then Move Method incrementally.
  4. Decide visibility and final ownership (composition).
- **Caution:** avoid creating cycles

### Inline Class
- **When:** class does almost nothing (Lazy Class, emptied by moves)
- **Steps:**
  1. Move public members to the recipient (or create forwarding).
  2. Update all references.
  3. Move remaining private members.
  4. Delete the class.
- **Caution:** none

### Hide Delegate
- **When:** client navigates through intermediate (Message Chains)
- **Steps:**
  1. For each client call on B via A, add delegating method on A.
  2. Update client to call A’s new method.
  3. Optionally remove direct access to B.
- **Caution:** over-use creates Middle Man

### Remove Middle Man
- **When:** class only delegates (Middle Man)
- **Steps:**
  1. Add (or expose) getter for the delegate if needed.
  2. Replace client calls to the middle man with direct calls to the delegate.
  3. Delete the pure delegating methods.
- **Caution:** do not remove intentional Proxy/Decorator/firewall

### Introduce Foreign Method
- **When:** need a few methods on a class you cannot modify (Incomplete Library Class)
- **Steps:**
  1. Create method on the client that takes the library object as first parameter.
  2. Move the needed code into it.
  3. Tag as foreign (comment or naming).
- **Caution:** limited to small additions

### Introduce Local Extension
- **When:** need many methods on a sealed library class
- **Steps:**
  1. Create subclass or wrapper of the library class.
  2. Provide converting constructor / factory.
  3. Move the foreign methods onto the extension.
  4. Replace uses of the original with the extension.
- **Caution:** library updates may break the extension

---

## Organizing Data

### Self Encapsulate Field
- **When:** want to enable subclass override of field access or prepare for later change
- **Steps:** create private accessors; use them even inside the class
- **Caution:** minor verbosity

### Encapsulate Field
- **When:** public field
- **Steps:** make private; add getters/setters; update all access
- **Caution:** none

### Encapsulate Collection
- **When:** collection field or getter returns internal mutable collection
- **Steps:** return unmodifiable view or defensive copy; provide explicit add/remove; never expose the raw collection
- **Caution:** performance of copies if large

### Replace Data Value with Object
- **When:** simple value needs behavior, validation, or identity (Primitive Obsession)
- **Steps:** create class for the value; replace the field/param with the object; move related logic onto it
- **Caution:** none

### Replace Array with Object
- **When:** array elements have different meanings (Primitive Obsession / Data Clumps)
- **Steps:** create class with named fields; replace the array; update access
- **Caution:** none

### Replace Magic Number with Symbolic Constant
- **When:** literal number has meaning
- **Steps:** introduce named constant; replace all occurrences
- **Caution:** none

### Replace Type Code with Class
- **When:** type code (int/string) with no behavior variation
- **Steps:** create class (or enum) wrapping the codes; replace the type code field
- **Caution:** none

### Replace Type Code with Subclasses
- **When:** type code drives different behavior and type is fixed after creation
- **Steps:** create subclass per type; factory returns correct subclass; replace conditionals with polymorphism
- **Caution:** only if type does not change at runtime

### Replace Type Code with State/Strategy
- **When:** type code drives behavior and type can change, or multiple orthogonal codes
- **Steps:** create State/Strategy hierarchy; hold a reference; delegate behavior; replace conditionals
- **Caution:** more classes

### Replace Subclass with Fields
- **When:** subclasses differ only by constant data
- **Steps:** move the differing constants to fields on the parent; eliminate the subclasses
- **Caution:** none

### Change Value to Reference
- **When:** many equal value objects should share identity
- **Steps:** introduce a registry/factory that returns the same instance for equal values; update creation sites
- **Caution:** mutability concerns

### Change Reference to Value
- **When:** reference object is immutable and value equality is sufficient
- **Steps:** make it a value object (equality by value); simplify clients
- **Caution:** none

### Change Unidirectional Association to Bidirectional
- **When:** need back-pointer
- **Steps:** add reverse link; maintain consistency on both sides (setters that update both)
- **Caution:** increased coupling and consistency burden

### Change Bidirectional Association to Unidirectional
- **When:** reverse link is unused
- **Steps:** remove the reverse; update any code that relied on it
- **Caution:** none

### Duplicate Observed Data
- **When:** domain data needed in UI layer with different lifecycle
- **Steps:** duplicate the data in the UI; establish observer/sync mechanism to keep consistent
- **Caution:** complexity of synchronization

---

## Simplifying Conditional Expressions

### Decompose Conditional
- **When:** complex if/then/else
- **Steps:** Extract Method on condition; Extract Method on then; Extract Method on else; name by intent
- **Caution:** none

### Consolidate Conditional Expression
- **When:** multiple conditionals yield the same result
- **Steps:** combine with && / ||; Extract Method on the combined expression
- **Caution:** side-effect-free conditions only

### Consolidate Duplicate Conditional Fragments
- **When:** identical code appears in all branches
- **Steps:** hoist common code before or after the conditional; Extract Method if non-trivial
- **Caution:** none

### Remove Control Flag
- **When:** boolean flag controls loop exit
- **Steps:** replace flag assignments with break / continue / return; remove flag variable and remaining checks
- **Caution:** none

### Replace Nested Conditional with Guard Clauses
- **When:** nested special-case checks create arrow code
- **Steps:** convert edge cases to early returns / continues; leave happy path unindented; optionally Consolidate Conditional Expression on similar guards
- **Prep:** Separate Query from Modifier if side effects present
- **Caution:** none

### Replace Conditional with Polymorphism
- **When:** behavior varies by type and multiple similar conditionals exist (or extension expected)
- **Prep:** Replace Type Code with Subclasses or State/Strategy
- **Steps:** Extract Method if mixed; for each subclass override and move matching branch; delete remaining branches; make abstract if pure
- **Caution:** higher design cost; prefer Guard Clauses or simple Extract for few stable cases

### Introduce Null Object
- **When:** repeated null checks
- **Steps:** create null-object class implementing the same interface with default/do-nothing behavior; return it instead of null; replace checks with polymorphic calls or isNull
- **Caution:** adds a class

### Introduce Assertion
- **When:** code relies on invariants / preconditions that must hold
- **Steps:** add assertion for the required condition
- **Caution:** do not use for recoverable user/system errors (use real exceptions)

---

## Simplifying Method Calls

### Rename Method
- **When:** name does not reveal purpose
- **Steps:** change name; update all callers
- **Caution:** public API may need deprecation path

### Add Parameter / Remove Parameter
- **When:** method needs more (or less) data
- **Steps:** update signature and all call sites; for remove, ensure the parameter is truly unused
- **Caution:** none

### Separate Query from Modifier
- **When:** method both returns a value and changes state
- **Steps:** split into pure query + modifier; have callers call both as needed
- **Caution:** none

### Parameterize Method
- **When:** multiple methods do similar work with different values
- **Steps:** create one method that takes the varying value as parameter; replace the similar methods with calls
- **Caution:** none

### Introduce Parameter Object
- **When:** group of parameters travel together (Long Parameter List / Data Clumps)
- **Steps:** create object holding the group; replace the individual parameters with the object; move related behavior onto the object when appropriate
- **Caution:** avoid unwanted dependency

### Preserve Whole Object
- **When:** several values from one object are passed as separate parameters
- **Steps:** pass the whole object instead; update method to extract what it needs
- **Caution:** may increase coupling if only a few values are needed

### Remove Setting Method
- **When:** field should be set only at construction
- **Steps:** remove the setter; set via constructor only
- **Caution:** none

### Replace Parameter with Explicit Methods
- **When:** parameter selects among a few behaviors
- **Steps:** create explicit methods for each case; update callers
- **Caution:** only for small stable set of cases

### Replace Parameter with Method Call
- **When:** parameter value can be obtained by calling a method on an existing object
- **Steps:** remove the parameter; obtain the value inside via the method call
- **Caution:** none

### Hide Method
- **When:** method is not used outside its class
- **Steps:** make private (or more restricted)
- **Caution:** none

### Replace Constructor with Factory Method
- **When:** construction needs more flexibility (type selection, caching, complex setup)
- **Steps:** create static factory; make constructor private or protected; update creation sites
- **Caution:** none

### Replace Error Code with Exception
- **When:** method returns special error codes
- **Steps:** throw exception instead; update callers to catch
- **Caution:** only for truly exceptional cases

### Replace Exception with Test
- **When:** exception is used for a condition that can be tested beforehand
- **Steps:** add explicit test; avoid the exception path for the expected case
- **Caution:** none

---

## Dealing with Generalization

### Pull Up Field
- **When:** identical field in subclasses
- **Steps:** unify names; declare in superclass; remove from subclasses; optionally Self Encapsulate
- **Caution:** none

### Pull Up Method
- **When:** similar methods in subclasses
- **Steps:** make identical; copy to superclass (handle missing members via Pull Up or abstract); remove from subclasses
- **Caution:** none

### Pull Up Constructor Body
- **When:** common prefix in subclass constructors
- **Steps:** create superclass constructor with the common code; call super() first in subclasses
- **Caution:** none

### Push Down Field
- **When:** field used only in some subclasses
- **Steps:** move declaration to those subclasses; remove from superclass
- **Caution:** none

### Push Down Method
- **When:** method used only in some subclasses
- **Steps:** copy to those subclasses; remove from superclass
- **Caution:** intermediate subclass if needed by several but not all

### Extract Subclass
- **When:** features used only in certain cases
- **Steps:** create subclass; Push Down the special members; replace type-code checks with polymorphism
- **Caution:** none

### Extract Superclass
- **When:** two classes share fields/methods
- **Steps:** create abstract superclass; Pull Up shared members; update client types
- **Caution:** classes must not already have a different superclass

### Extract Interface
- **When:** clients share a subset of operations, or two classes share interface portion
- **Steps:** create interface; declare the common operations; implement; update client type declarations
- **Caution:** does not remove implementation duplication (pair with Extract Class/Superclass)

### Collapse Hierarchy
- **When:** subclass nearly identical to superclass
- **Steps:** merge differences via Pull Up / Push Down; update references; delete empty class
- **Caution:** remaining subclasses must still satisfy Liskov under the collapsed parent

### Form Template Method
- **When:** subclasses implement algorithms with identical step order but different details
- **Steps:** Extract Method on the steps; Pull Up identical steps; abstract the varying steps; Pull Up the skeleton method
- **Caution:** none

### Replace Inheritance with Delegation
- **When:** subclass uses only portion of parent or Liskov is violated
- **Steps:** add field of parent type; delegate needed methods; remove inheritance; initialize the field
- **Caution:** none

### Replace Delegation with Inheritance
- **When:** class has many pure delegators covering (nearly) the whole public interface of one object and has no parent
- **Steps:** inherit from the delegate; redirect internal uses to self; delete pure delegators; remove the field
- **Caution:** only when the full interface is needed
