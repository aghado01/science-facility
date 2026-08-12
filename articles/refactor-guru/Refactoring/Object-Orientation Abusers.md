# [Object-Orientation Abusers](https://refactoring.guru/refactoring/smells/oo-abusers)

All these smells are incomplete or incorrect application of object-oriented programming principles.

[Switch Statements](#switch-statements)

You have a complex `switch` operator or sequence of `if` statements.

[Temporary Field](#temporary-field)

Temporary fields get their values (and thus are needed by objects) only under certain circumstances. Outside of these circumstances, they’re empty.

[Refused Bequest](#refused-bequest)

If a subclass uses only some of the methods and properties inherited from its parents, the hierarchy is off-kilter. The unneeded methods may simply go unused or be redefined and give off exceptions.

[Alternative Classes with Different Interfaces](#alternative-classes-with-different-interfaces)

Two classes perform identical functions but have different method names.

### Table of Contents

- [Alternative Classes with Different Interfaces](#alternative-classes-with-different-interfaces)
- [Refused Bequest](#refused-bequest)
- [Switch Statements](#switch-statements)
- [Temporary Field](#temporary-field)

---

<a id="alternative-classes-with-different-interfaces"></a>
## [Alternative Classes with Different Interfaces](https://refactoring.guru/smells/alternative-classes-with-different-interfaces)

#### Signs and Symptoms

Two classes perform identical functions but have different method names.

![](https://refactoring.guru/images/refactoring/content/smells/alternative-classes-with-different-interfaces-01.png)

#### Reasons for the Problem

The programmer who created one of the classes probably didn’t know that a functionally equivalent class already existed.

#### Treatment

Try to put the interface of classes in terms of a common denominator:

- [Rename Method](Simplifying%20Method%20Calls.md#rename-method)s to make them identical in all alternative classes.
- [Move Method](Moving%20Features%20between%20Objects.md#move-method), [Add Parameter](Simplifying%20Method%20Calls.md#add-parameter) and [Parameterize Method](Simplifying%20Method%20Calls.md#parameterize-method) to make the signature and implementation of methods the same.
- If only part of the functionality of the classes is duplicated, try using [Extract Superclass](Dealing%20with%20Generalization.md#extract-superclass). In this case, the existing classes will become subclasses.
- After you have determined which treatment method to use and implemented it, you may be able to delete one of the classes.

#### Payoff

- You get rid of unnecessary duplicated code, making the resulting code less bulky.
- Code becomes more readable and understandable (you no longer have to guess the reason for creation of a second class performing the exact same functions as the first one).

![](https://refactoring.guru/images/refactoring/content/smells/alternative-classes-with-different-interfaces-02.png)

#### When to Ignore

- Sometimes merging classes is impossible or so difficult as to be pointless. One example is when the alternative classes are in different libraries that each have their own version of the class.

---

<a id="refused-bequest"></a>
## [Refused Bequest](https://refactoring.guru/smells/refused-bequest)

#### Signs and Symptoms

If a subclass uses only some of the methods and properties inherited from its parents, the hierarchy is off-kilter. The unneeded methods may simply go unused or be redefined and give off exceptions.

![](https://refactoring.guru/images/refactoring/content/smells/refused-bequest-01.png)

#### Reasons for the Problem

Someone was motivated to create inheritance between classes only by the desire to reuse the code in a superclass. But the superclass and subclass are completely different.

![](https://refactoring.guru/images/refactoring/content/smells/refused-bequest-02.png)

#### Treatment

- If inheritance makes no sense and the subclass really does have nothing in common with the superclass, eliminate inheritance in favor of [Replace Inheritance with Delegation](Dealing%20with%20Generalization.md#replace-inheritance-with-delegation).
- If inheritance is appropriate, get rid of unneeded fields and methods in the subclass. Extract all fields and methods needed by the subclass from the parent class, put them in a new superclass, and set both classes to inherit from it ([Extract Superclass](Dealing%20with%20Generalization.md#extract-superclass)).

![](https://refactoring.guru/images/refactoring/content/smells/refused-bequest-03.png)

#### Payoff

- Improves code clarity and organization. You will no longer have to wonder why the `Dog` class is inherited from the `Chair` class (even though they both have 4 legs).

---

<a id="switch-statements"></a>
## [Switch Statements](https://refactoring.guru/smells/switch-statements)

#### Signs and Symptoms

You have a complex `switch` operator or sequence of `if` statements.

![](https://refactoring.guru/images/refactoring/content/smells/switch-statements-01.png)

#### Reasons for the Problem

Relatively rare use of `switch` and `case` operators is one of the hallmarks of object-oriented code. Often code for a single `switch` can be scattered in different places in the program. When a new condition is added, you have to find all the `switch` code and modify it.

As a rule of thumb, when you see `switch` you should think of polymorphism.

#### Treatment

- To isolate `switch` and put it in the right class, you may need [Extract Method](Composing%20Methods.md#extract-method) and then [Move Method](Moving%20Features%20between%20Objects.md#move-method).
- If a `switch` is based on type code, such as when the program’s runtime mode is switched, use [Replace Type Code with Subclasses](Organizing%20Data.md#replace-type-code-with-subclasses) or [Replace Type Code with State/Strategy](Organizing%20Data.md#replace-type-code-with-state-strategy).
- After specifying the inheritance structure, use [Replace Conditional with Polymorphism](Simplifying%20Conditional%20Expressions.md#replace-conditional-with-polymorphism).
- If there aren’t too many conditions in the operator and they all call same method with different parameters, polymorphism will be superfluous. If this case, you can break that method into multiple smaller methods with [Replace Parameter with Explicit Methods](Simplifying%20Method%20Calls.md#replace-parameter-with-explicit-methods) and change the `switch` accordingly.
- If one of the conditional options is `null`, use [Introduce Null Object](Simplifying%20Conditional%20Expressions.md#introduce-null-object).

#### Payoff

- Improved code organization.

![](https://refactoring.guru/images/refactoring/content/smells/switch-statements-02.png)

#### When to Ignore

- When a `switch` operator performs simple actions, there’s no reason to make code changes.
- Often `switch` operators are used by factory design patterns ([Factory Method](https://refactoring.guru/design-patterns/factory-method) or [Abstract Factory](https://refactoring.guru/design-patterns/abstract-factory)) to select a created class.

---

<a id="temporary-field"></a>
## [Temporary Field](https://refactoring.guru/smells/temporary-field)

#### Signs and Symptoms

Temporary fields get their values (and thus are needed by objects) only under certain circumstances. Outside of these circumstances, they’re empty.

![](https://refactoring.guru/images/refactoring/content/smells/temporary-field-01.png)

#### Reasons for the Problem

Oftentimes, temporary fields are created for use in an algorithm that requires a large amount of inputs. So instead of creating a large number of parameters in the method, the programmer decides to create fields for this data in the class. These fields are used only in the algorithm and go unused the rest of the time.

This kind of code is tough to understand. You expect to see data in object fields but for some reason they’re almost always empty.

![](https://refactoring.guru/images/refactoring/content/smells/temporary-field-02.png)

#### Treatment

- Temporary fields and all code operating on them can be put in a separate class via [Extract Class](Moving%20Features%20between%20Objects.md#extract-class). In other words, you’re creating a method object, achieving the same result as if you would perform [Replace Method with Method Object](Composing%20Methods.md#replace-method-with-method-object).
- [Introduce Null Object](Simplifying%20Conditional%20Expressions.md#introduce-null-object) and integrate it in place of the conditional code which was used to check the temporary field values for existence.

![](https://refactoring.guru/images/refactoring/content/smells/temporary-field-03.png)

#### Payoff

- Better code clarity and organization.

---
