# [Change Preventers](https://refactoring.guru/refactoring/smells/change-preventers)

These smells mean that if you need to change something in one place in your code, you have to make many changes in other places too. Program development becomes much more complicated and expensive as a result.

[Divergent Change](#divergent-change)

You find yourself having to change many unrelated methods when you make changes to a class. For example, when adding a new product type you have to change the methods for finding, displaying, and ordering products.

[Shotgun Surgery](#shotgun-surgery)

Making any modifications requires that you make many small changes to many different classes.

[Parallel Inheritance Hierarchies](#parallel-inheritance-hierarchies)

Whenever you create a subclass for a class, you find yourself needing to create a subclass for another class.

### Table of Contents

- [Divergent Change](#divergent-change)
- [Parallel Inheritance Hierarchies](#parallel-inheritance-hierarchies)
- [Shotgun Surgery](#shotgun-surgery)

---

<a id="divergent-change"></a>
## [Divergent Change](https://refactoring.guru/smells/divergent-change)

> *Divergent Change* resembles [Shotgun Surgery](#shotgun-surgery) but is actually the opposite smell. *Divergent Change* is when many changes are made to a single class. *Shotgun Surgery* refers to when a single change is made to multiple classes simultaneously.

#### Signs and Symptoms

You find yourself having to change many unrelated methods when you make changes to a class. For example, when adding a new product type you have to change the methods for finding, displaying, and ordering products.

![](https://refactoring.guru/images/refactoring/content/smells/divergent-change-01.png)

#### Reasons for the Problem

Often these divergent modifications are due to poor program structure or "copypasta programming”.

#### Treatment

- Split up the behavior of the class via [Extract Class](Moving%20Features%20between%20Objects.md#extract-class).
- If different classes have the same behavior, you may want to combine the classes through inheritance ([Extract Superclass](Dealing%20with%20Generalization.md#extract-superclass) and [Extract Subclass](Dealing%20with%20Generalization.md#extract-subclass)).

![](https://refactoring.guru/images/refactoring/content/smells/divergent-change-02.png)

#### Payoff

- Improves code organization.
- Reduces code duplication.
- Simplifies support.

---

<a id="parallel-inheritance-hierarchies"></a>
## [Parallel Inheritance Hierarchies](https://refactoring.guru/smells/parallel-inheritance-hierarchies)

#### Signs and Symptoms

Whenever you create a subclass for a class, you find yourself needing to create a subclass for another class.

![](https://refactoring.guru/images/refactoring/content/smells/parallel-inheritance-hierarchies-01.png)

#### Reasons for the Problem

All was well as long as the hierarchy stayed small. But with new classes being added, making changes has become harder and harder.

#### Treatment

- You may de-duplicate parallel class hierarchies in two steps. First, make instances of one hierarchy refer to instances of another hierarchy. Then, remove the hierarchy in the referred class, by using [Move Method](Moving%20Features%20between%20Objects.md#move-method) and [Move Field](Moving%20Features%20between%20Objects.md#move-field).

#### Payoff

- Reduces code duplication.
- Can improve organization of code.

![](https://refactoring.guru/images/refactoring/content/smells/parallel-inheritance-hierarchies-02.png)

#### When to Ignore

- Sometimes having parallel class hierarchies is just a way to avoid even bigger mess with program architecture. If you find that your attempts to de-duplicate hierarchies produce even uglier code, just step out, revert all of your changes and get used to that code.

---

<a id="shotgun-surgery"></a>
## [Shotgun Surgery](https://refactoring.guru/smells/shotgun-surgery)

> *Shotgun Surgery* resembles [Divergent Change](#divergent-change) but is actually the opposite smell. *Divergent Change* is when many changes are made to a single class. *Shotgun Surgery* refers to when a single change is made to multiple classes simultaneously.

#### Signs and Symptoms

Making any modifications requires that you make many small changes to many different classes.

![](https://refactoring.guru/images/refactoring/content/smells/shotgun-surgery-01.png)

#### Reasons for the Problem

A single responsibility has been split up among a large number of classes. This can happen after overzealous application of [Divergent Change](#divergent-change).

![](https://refactoring.guru/images/refactoring/content/smells/shotgun-surgery-02.png)

#### Treatment

- Use [Move Method](Moving%20Features%20between%20Objects.md#move-method) and [Move Field](Moving%20Features%20between%20Objects.md#move-field) to move existing class behaviors into a single class. If there’s no class appropriate for this, create a new one.
- If moving code to the same class leaves the original classes almost empty, try to get rid of these now-redundant classes via [Inline Class](Moving%20Features%20between%20Objects.md#inline-class).

![](https://refactoring.guru/images/refactoring/content/smells/shotgun-surgery-03.png)

#### Payoff

- Better organization.
- Less code duplication.
- Easier maintenance.

---
