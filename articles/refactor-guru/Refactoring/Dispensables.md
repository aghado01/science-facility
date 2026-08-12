# [Dispensables](https://refactoring.guru/refactoring/smells/dispensables)

A dispensable is something pointless and unneeded whose absence would make the code cleaner, more efficient and easier to understand.

[Comments](#comments)

A method is filled with explanatory comments.

[Duplicate Code](#duplicate-code)

Two code fragments look almost identical.

[Lazy Class](#lazy-class)

Understanding and maintaining classes always costs time and money. So if a class doesn’t do enough to earn your attention, it should be deleted.

[Data Class](#data-class)

A data class refers to a class that contains only fields and crude methods for accessing them (getters and setters). These are simply containers for data used by other classes. These classes don’t contain any additional functionality and can’t independently operate on the data that they own.

[Dead Code](#dead-code)

A variable, parameter, field, method or class is no longer used (usually because it’s obsolete).

[Speculative Generality](#speculative-generality)

There’s an unused class, method, field or parameter.

### Table of Contents

- [Comments](#comments)
- [Duplicate Code](#duplicate-code)
- [Data Class](#data-class)
- [Dead Code](#dead-code)
- [Lazy Class](#lazy-class)
- [Speculative Generality](#speculative-generality)

---

<a id="comments"></a>
## [Comments](https://refactoring.guru/smells/comments)

#### Signs and Symptoms

A method is filled with explanatory comments.

![](https://refactoring.guru/images/refactoring/content/smells/comments-01.png)

#### Reasons for the Problem

Comments are usually created with the best of intentions, when the author realizes that his or her code isn’t intuitive or obvious. In such cases, comments are like a deodorant masking the smell of fishy code that could be improved.

> The best comment is a good name for a method or class.

If you feel that a code fragment can’t be understood without comments, try to change the code structure in a way that makes comments unnecessary.

#### Treatment

- If a comment is intended to explain a complex expression, the expression should be split into understandable subexpressions using [Extract Variable](Composing%20Methods.md#extract-variable).
- If a comment explains a section of code, this section can be turned into a separate method via [Extract Method](Composing%20Methods.md#extract-method). The name of the new method can be taken from the comment text itself, most likely.
- If a method has already been extracted, but comments are still necessary to explain what the method does, give the method a self-explanatory name. Use [Rename Method](Simplifying%20Method%20Calls.md#rename-method) for this.
- If you need to assert rules about a state that’s necessary for the system to work, use [Introduce Assertion](Simplifying%20Conditional%20Expressions.md#introduce-assertion).

#### Payoff

- Code becomes more intuitive and obvious.

![](https://refactoring.guru/images/refactoring/content/smells/comments-02.png)

#### When to Ignore

Comments can sometimes be useful:

- When explaining **why** something is being implemented in a particular way.
- When explaining complex algorithms (when all other methods for simplifying the algorithm have been tried and come up short).

---

<a id="duplicate-code"></a>
## [Duplicate Code](https://refactoring.guru/smells/duplicate-code)

#### Signs and Symptoms

Two code fragments look almost identical.

![](https://refactoring.guru/images/refactoring/content/smells/duplicate-code-01.png)

#### Reasons for the Problem

Duplication usually occurs when multiple programmers are working on different parts of the same program at the same time. Since they’re working on different tasks, they may be unaware their colleague has already written similar code that could be repurposed for their own needs.

There’s also more subtle duplication, when specific parts of code look different but actually perform the same job. This kind of duplication can be hard to find and fix.

Sometimes duplication is purposeful. When rushing to meet deadlines and the existing code is “almost right” for the job, novice programmers may not be able to resist the temptation of copying and pasting the relevant code. And in some cases, the programmer is simply too lazy to de-clutter.

#### Treatment

- If the same code is found in two or more methods in the same class: use [Extract Method](Composing%20Methods.md#extract-method) and place calls for the new method in both places.
  ![](https://refactoring.guru/images/refactoring/content/smells/duplicate-code-02.png)
- If the same code is found in two subclasses of the same level:
  - Use [Extract Method](Composing%20Methods.md#extract-method) for both classes, followed by [Pull Up Field](Dealing%20with%20Generalization.md#pull-up-field) for the fields used in the method that you’re pulling up.
  - If the duplicate code is inside a constructor, use [Pull Up Constructor Body](Dealing%20with%20Generalization.md#pull-up-constructor-body).
  - If the duplicate code is similar but not completely identical, use [Form Template Method](Dealing%20with%20Generalization.md#form-template-method).
  - If two methods do the same thing but use different algorithms, select the best algorithm and apply [Substitute Algorithm](Composing%20Methods.md#substitute-algorithm).
- If duplicate code is found in two different classes:
  - If the classes aren’t part of a hierarchy, use [Extract Superclass](Dealing%20with%20Generalization.md#extract-superclass) in order to create a single superclass for these classes that maintains all the previous functionality.
  - If it’s difficult or impossible to create a superclass, use [Extract Class](Moving%20Features%20between%20Objects.md#extract-class) in one class and use the new component in the other.
- If a large number of conditional expressions are present and perform the same code (differing only in their conditions), merge these operators into a single condition using [Consolidate Conditional Expression](Simplifying%20Conditional%20Expressions.md#consolidate-conditional-expression) and use [Extract Method](Composing%20Methods.md#extract-method) to place the condition in a separate method with an easy-to-understand name.
- If the same code is performed in all branches of a conditional expression: place the identical code outside of the condition tree by using [Consolidate Duplicate Conditional Fragments](Simplifying%20Conditional%20Expressions.md#consolidate-duplicate-conditional-fragments).

#### Payoff

- Merging duplicate code simplifies the structure of your code and makes it shorter.
- Simplification + shortness = code that’s easier to simplify and cheaper to support.

![](https://refactoring.guru/images/refactoring/content/smells/duplicate-code-03.png)

#### When to Ignore

- In very rare cases, merging two identical fragments of code can make the code less intuitive and obvious.

---

<a id="data-class"></a>
## [Data Class](https://refactoring.guru/smells/data-class)

#### Signs and Symptoms

A data class refers to a class that contains only fields and crude methods for accessing them (getters and setters). These are simply containers for data used by other classes. These classes don’t contain any additional functionality and can’t independently operate on the data that they own.

![](https://refactoring.guru/images/refactoring/content/smells/data-class-01.png)

#### Reasons for the Problem

It’s a normal thing when a newly created class contains only a few public fields (and maybe even a handful of getters/setters). But the true power of objects is that they can contain behavior types or operations on their data.

#### Treatment

- If a class contains public fields, use [Encapsulate Field](Organizing%20Data.md#encapsulate-field) to hide them from direct access and require that access be performed via getters and setters only.
- Use [Encapsulate Collection](Organizing%20Data.md#encapsulate-collection) for data stored in collections (such as arrays).
- Review the client code that uses the class. In it, you may find functionality that would be better located in the data class itself. If this is the case, use [Move Method](Moving%20Features%20between%20Objects.md#move-method) and [Extract Method](Composing%20Methods.md#extract-method) to migrate this functionality to the data class.
- After the class has been filled with well thought-out methods, you may want to get rid of old methods for data access that give overly broad access to the class data. For this, [Remove Setting Method](Simplifying%20Method%20Calls.md#remove-setting-method) and [Hide Method](Simplifying%20Method%20Calls.md#hide-method) may be helpful.

![](https://refactoring.guru/images/refactoring/content/smells/data-class-02.png)

#### Payoff

- Improves understanding and organization of code. Operations on particular data are now gathered in a single place, instead of haphazardly throughout the code.
- Helps you to spot duplication of client code.

---

<a id="dead-code"></a>
## [Dead Code](https://refactoring.guru/smells/dead-code)

#### Signs and Symptoms

A variable, parameter, field, method or class is no longer used (usually because it’s obsolete).

![](https://refactoring.guru/images/refactoring/content/smells/dead-code-01.png)

#### Reasons for the Problem

When requirements for the software have changed or corrections have been made, nobody had time to clean up the old code.

Such code could also be found in complex conditionals, when one of the branches becomes unreachable (due to error or other circumstances).

#### Treatment

The quickest way to find dead code is to use a good [IDE](https://en.wikipedia.org/wiki/Integrated_development_environment).

- Delete unused code and unneeded files.
- In the case of an unnecessary class, [Inline Class](Moving%20Features%20between%20Objects.md#inline-class) or [Collapse Hierarchy](Dealing%20with%20Generalization.md#collapse-hierarchy) can be applied if a subclass or superclass is used.
- To remove unneeded parameters, use [Remove Parameter](Simplifying%20Method%20Calls.md#remove-parameter).

![](https://refactoring.guru/images/refactoring/content/smells/dead-code-02.png)

#### Payoff

- Reduced code size.
- Simpler support.

---

<a id="lazy-class"></a>
## [Lazy Class](https://refactoring.guru/smells/lazy-class)

#### Signs and Symptoms

Understanding and maintaining classes always costs time and money. So if a class doesn’t do enough to earn your attention, it should be deleted.

![](https://refactoring.guru/images/refactoring/content/smells/lazy-class-01.png)

#### Reasons for the Problem

Perhaps a class was designed to be fully functional but after some of the refactoring it has become ridiculously small.

Or perhaps it was designed to support future development work that never got done.

#### Treatment

- Components that are near-useless should be given the [Inline Class](Moving%20Features%20between%20Objects.md#inline-class) treatment.
- For subclasses with few functions, try [Collapse Hierarchy](Dealing%20with%20Generalization.md#collapse-hierarchy).

![](https://refactoring.guru/images/refactoring/content/smells/lazy-class-02.png)

#### Payoff

- Reduced code size.
- Easier maintenance.

#### When to Ignore

- Sometimes a *Lazy Class* is created in order to delineate intentions for future development, In this case, try to maintain a balance between clarity and simplicity in your code.

---

<a id="speculative-generality"></a>
## [Speculative Generality](https://refactoring.guru/smells/speculative-generality)

#### Signs and Symptoms

There’s an unused class, method, field or parameter.

![](https://refactoring.guru/images/refactoring/content/smells/speculative-generality-01.png)

#### Reasons for the Problem

Sometimes code is created “just in case” to support anticipated future features that never get implemented. As a result, code becomes hard to understand and support.

#### Treatment

- For removing unused abstract classes, try [Collapse Hierarchy](Dealing%20with%20Generalization.md#collapse-hierarchy).
- Unnecessary delegation of functionality to another class can be eliminated via [Inline Class](Moving%20Features%20between%20Objects.md#inline-class).
- Unused methods? Use [Inline Method](Composing%20Methods.md#inline-method) to get rid of them.
- Methods with unused parameters should be given a look with the help of [Remove Parameter](Simplifying%20Method%20Calls.md#remove-parameter).
- Unused fields can be simply deleted.

![](https://refactoring.guru/images/refactoring/content/smells/speculative-generality-02.png)

#### Payoff

- Slimmer code.
- Easier support.

#### When to Ignore

- If you’re working on a framework, it’s eminently reasonable to create functionality not used in the framework itself, as long as the functionality is needed by the frameworks’s users.
- Before deleting elements, make sure that they aren’t used in unit tests. This happens if tests need a way to get certain internal information from a class or perform special testing-related actions.

---
