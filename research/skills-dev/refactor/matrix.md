# Smell → Technique Matrix

Quick crosswalk. Primary techniques listed first. See smells.md and techniques.md for full cards.

| Smell | Primary techniques |
|-------|--------------------|
| Long Method | Extract Method; Replace Temp with Query; Introduce Parameter Object; Preserve Whole Object; Replace Method with Method Object; Decompose Conditional |
| Large Class | Extract Class; Extract Subclass; Extract Interface; Duplicate Observed Data |
| Primitive Obsession | Replace Data Value with Object; Introduce Parameter Object; Preserve Whole Object; Replace Type Code with Class / Subclasses / State-Strategy; Replace Array with Object |
| Long Parameter List | Replace Parameter with Method Call; Preserve Whole Object; Introduce Parameter Object |
| Data Clumps | Extract Class; Introduce Parameter Object; Preserve Whole Object |
| Switch Statements | Replace Conditional with Polymorphism; Replace Type Code with Subclasses / State-Strategy; Replace Parameter with Explicit Methods; Introduce Null Object; Decompose Conditional |
| Temporary Field | Extract Class; Replace Method with Method Object; Introduce Null Object |
| Refused Bequest | Replace Inheritance with Delegation; Extract Superclass |
| Alternative Classes with Different Interfaces | Rename Method; Move Method; Add Parameter; Parameterize Method; Extract Superclass |
| Divergent Change | Extract Class; Extract Superclass; Extract Subclass |
| Shotgun Surgery | Move Method; Move Field; Inline Class |
| Parallel Inheritance Hierarchies | Move Method; Move Field (then collapse one hierarchy) |
| Comments | Extract Variable; Extract Method; Rename Method; Introduce Assertion |
| Duplicate Code | Extract Method; Pull Up Method / Field; Form Template Method; Extract Superclass / Extract Class; Substitute Algorithm; Consolidate Conditional Expression; Consolidate Duplicate Conditional Fragments |
| Data Class | Encapsulate Field; Encapsulate Collection; Move Method; Extract Method; Remove Setting Method; Hide Method |
| Dead Code | delete; Remove Parameter; Inline Class; Collapse Hierarchy |
| Lazy Class | Inline Class; Collapse Hierarchy |
| Speculative Generality | Collapse Hierarchy; Inline Class; Inline Method; Remove Parameter |
| Feature Envy | Move Method; Extract Method then Move |
| Inappropriate Intimacy | Move Method; Move Field; Extract Class; Hide Delegate; Change Bidirectional Association to Unidirectional |
| Incomplete Library Class | Introduce Foreign Method; Introduce Local Extension |
| Message Chains | Hide Delegate; Extract Method + Move Method |
| Middle Man | Remove Middle Man |

Secondary / supporting techniques appear in the individual smell Treat lists.
