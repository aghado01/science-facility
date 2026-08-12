# [Catalog of Refactoring](https://refactoring.guru/refactoring/catalog)

Complete catalog of Code Smells and Refactoring Techniques, grouped by major sections.

📁 Code examples are separated into the [`examples/`](examples/README.md) directory.

## Code Smells

"Code smells" refer to recognizable patterns and signatures of infractions of solid software and system design.

### [Bloaters](Bloaters.md)

Bloaters are code, methods and classes that have increased to such gargantuan proportions that they’re hard to work with. Usually these smells don’t crop up right away, rather they accumulate over time as the program evolves (and especially when nobody makes an effort to eradicate them).

- [Long Method](Bloaters.md#long-method)
- [Large Class](Bloaters.md#large-class)
- [Primitive Obsession](Bloaters.md#primitive-obsession)
- [Long Parameter List](Bloaters.md#long-parameter-list)
- [Data Clumps](Bloaters.md#data-clumps)

### [Object-Orientation Abusers](Object-Orientation%20Abusers.md)

All these smells are incomplete or incorrect application of object-oriented programming principles.

- [Alternative Classes with Different Interfaces](Object-Orientation%20Abusers.md#alternative-classes-with-different-interfaces)
- [Refused Bequest](Object-Orientation%20Abusers.md#refused-bequest)
- [Switch Statements](Object-Orientation%20Abusers.md#switch-statements)
- [Temporary Field](Object-Orientation%20Abusers.md#temporary-field)

### [Change Preventers](Change%20Preventers.md)

These smells mean that if you need to change something in one place in your code, you have to make many changes in other places too. Program development becomes much more complicated and expensive as a result.

- [Divergent Change](Change%20Preventers.md#divergent-change)
- [Parallel Inheritance Hierarchies](Change%20Preventers.md#parallel-inheritance-hierarchies)
- [Shotgun Surgery](Change%20Preventers.md#shotgun-surgery)

### [Dispensables](Dispensables.md)

A dispensable is something pointless and unneeded whose absence would make the code cleaner, more efficient and easier to understand.

- [Comments](Dispensables.md#comments)
- [Duplicate Code](Dispensables.md#duplicate-code)
- [Data Class](Dispensables.md#data-class)
- [Dead Code](Dispensables.md#dead-code)
- [Lazy Class](Dispensables.md#lazy-class)
- [Speculative Generality](Dispensables.md#speculative-generality)

### [Couplers](Couplers.md)

All the smells in this group contribute to excessive coupling between classes or show what happens if coupling is replaced by excessive delegation.

- [Feature Envy](Couplers.md#feature-envy)
- [Inappropriate Intimacy](Couplers.md#inappropriate-intimacy)
- [Incomplete Library Class](Couplers.md#incomplete-library-class)
- [Message Chains](Couplers.md#message-chains)
- [Middle Man](Couplers.md#middle-man)

## Refactoring Techniques

### [Composing Methods](Composing%20Methods.md)

Much of refactoring is devoted to correctly composing methods. In most cases, excessively long methods are the root of all evil. The vagaries of code inside these methods conceal the execution logic and make the method extremely hard to understand—and even harder to change.

- [Extract Method](Composing%20Methods.md#extract-method)
- [Inline Method](Composing%20Methods.md#inline-method)
- [Extract Variable](Composing%20Methods.md#extract-variable)
- [Inline Temp](Composing%20Methods.md#inline-temp)
- [Replace Temp with Query](Composing%20Methods.md#replace-temp-with-query)
- [Split Temporary Variable](Composing%20Methods.md#split-temporary-variable)
- [Remove Assignments to Parameters](Composing%20Methods.md#remove-assignments-to-parameters)
- [Replace Method with Method Object](Composing%20Methods.md#replace-method-with-method-object)
- [Substitute Algorithm](Composing%20Methods.md#substitute-algorithm)

### [Moving Features between Objects](Moving%20Features%20between%20Objects.md)

Even if you have distributed functionality among different classes in a less-than-perfect way, there’s still hope.

- [Move Method](Moving%20Features%20between%20Objects.md#move-method)
- [Move Field](Moving%20Features%20between%20Objects.md#move-field)
- [Extract Class](Moving%20Features%20between%20Objects.md#extract-class)
- [Inline Class](Moving%20Features%20between%20Objects.md#inline-class)
- [Hide Delegate](Moving%20Features%20between%20Objects.md#hide-delegate)
- [Remove Middle Man](Moving%20Features%20between%20Objects.md#remove-middle-man)
- [Introduce Foreign Method](Moving%20Features%20between%20Objects.md#introduce-foreign-method)
- [Introduce Local Extension](Moving%20Features%20between%20Objects.md#introduce-local-extension)

### [Organizing Data](Organizing%20Data.md)

These refactoring techniques help with data handling, replacing primitives with rich class functionality.

- [Change Value to Reference](Organizing%20Data.md#change-value-to-reference)
- [Change Reference to Value](Organizing%20Data.md#change-reference-to-value)
- [Duplicate Observed Data](Organizing%20Data.md#duplicate-observed-data)
- [Self Encapsulate Field](Organizing%20Data.md#self-encapsulate-field)
- [Replace Data Value with Object](Organizing%20Data.md#replace-data-value-with-object)
- [Replace Array with Object](Organizing%20Data.md#replace-array-with-object)
- [Change Unidirectional Association to Bidirectional](Organizing%20Data.md#change-unidirectional-association-to-bidirectional)
- [Change Bidirectional Association to Unidirectional](Organizing%20Data.md#change-bidirectional-association-to-unidirectional)
- [Encapsulate Field](Organizing%20Data.md#encapsulate-field)
- [Encapsulate Collection](Organizing%20Data.md#encapsulate-collection)
- [Replace Magic Number with Symbolic Constant](Organizing%20Data.md#replace-magic-number-with-symbolic-constant)
- [Replace Type Code with Class](Organizing%20Data.md#replace-type-code-with-class)
- [Replace Type Code with Subclasses](Organizing%20Data.md#replace-type-code-with-subclasses)
- [Replace Type Code with State/Strategy](Organizing%20Data.md#replace-type-code-with-state-strategy)
- [Replace Subclass with Fields](Organizing%20Data.md#replace-subclass-with-fields)

### [Simplifying Conditional Expressions](Simplifying%20Conditional%20Expressions.md)

Conditionals tend to get more and more complicated in their logic over time, and there are yet more techniques to combat this as well.

- [Consolidate Conditional Expression](Simplifying%20Conditional%20Expressions.md#consolidate-conditional-expression)
- [Consolidate Duplicate Conditional Fragments](Simplifying%20Conditional%20Expressions.md#consolidate-duplicate-conditional-fragments)
- [Decompose Conditional](Simplifying%20Conditional%20Expressions.md#decompose-conditional)
- [Replace Conditional with Polymorphism](Simplifying%20Conditional%20Expressions.md#replace-conditional-with-polymorphism)
- [Remove Control Flag](Simplifying%20Conditional%20Expressions.md#remove-control-flag)
- [Replace Nested Conditional with Guard Clauses](Simplifying%20Conditional%20Expressions.md#replace-nested-conditional-with-guard-clauses)
- [Introduce Null Object](Simplifying%20Conditional%20Expressions.md#introduce-null-object)
- [Introduce Assertion](Simplifying%20Conditional%20Expressions.md#introduce-assertion)

### [Simplifying Method Calls](Simplifying%20Method%20Calls.md)

These techniques make method calls simpler and easier to understand. This, in turn, simplifies the interfaces for interaction between classes.

- [Add Parameter](Simplifying%20Method%20Calls.md#add-parameter)
- [Remove Parameter](Simplifying%20Method%20Calls.md#remove-parameter)
- [Rename Method](Simplifying%20Method%20Calls.md#rename-method)
- [Separate Query from Modifier](Simplifying%20Method%20Calls.md#separate-query-from-modifier)
- [Parameterize Method](Simplifying%20Method%20Calls.md#parameterize-method)
- [Introduce Parameter Object](Simplifying%20Method%20Calls.md#introduce-parameter-object)
- [Preserve Whole Object](Simplifying%20Method%20Calls.md#preserve-whole-object)
- [Remove Setting Method](Simplifying%20Method%20Calls.md#remove-setting-method)
- [Replace Parameter with Explicit Methods](Simplifying%20Method%20Calls.md#replace-parameter-with-explicit-methods)
- [Replace Parameter with Method Call](Simplifying%20Method%20Calls.md#replace-parameter-with-method-call)
- [Hide Method](Simplifying%20Method%20Calls.md#hide-method)
- [Replace Constructor with Factory Method](Simplifying%20Method%20Calls.md#replace-constructor-with-factory-method)
- [Replace Error Code with Exception](Simplifying%20Method%20Calls.md#replace-error-code-with-exception)
- [Replace Exception with Test](Simplifying%20Method%20Calls.md#replace-exception-with-test)

### [Dealing with Generalization](Dealing%20with%20Generalization.md)

Abstraction has its own group of refactoring techniques, primarily associated with moving functionality along the class inheritance hierarchy, creating new classes and interfaces, and replacing inheritance with delegation and vice versa.

- [Pull Up Field](Dealing%20with%20Generalization.md#pull-up-field)
- [Pull Up Method](Dealing%20with%20Generalization.md#pull-up-method)
- [Pull Up Constructor Body](Dealing%20with%20Generalization.md#pull-up-constructor-body)
- [Push Down Field](Dealing%20with%20Generalization.md#push-down-field)
- [Push Down Method](Dealing%20with%20Generalization.md#push-down-method)
- [Extract Subclass](Dealing%20with%20Generalization.md#extract-subclass)
- [Extract Superclass](Dealing%20with%20Generalization.md#extract-superclass)
- [Extract Interface](Dealing%20with%20Generalization.md#extract-interface)
- [Collapse Hierarchy](Dealing%20with%20Generalization.md#collapse-hierarchy)
- [Form Template Method](Dealing%20with%20Generalization.md#form-template-method)
- [Replace Inheritance with Delegation](Dealing%20with%20Generalization.md#replace-inheritance-with-delegation)
- [Replace Delegation with Inheritance](Dealing%20with%20Generalization.md#replace-delegation-with-inheritance)
