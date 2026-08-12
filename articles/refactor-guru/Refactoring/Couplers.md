# [Couplers](https://refactoring.guru/refactoring/smells/couplers)

All the smells in this group contribute to excessive coupling between classes or show what happens if coupling is replaced by excessive delegation.

[Feature Envy](#feature-envy)

A method accesses the data of another object more than its own data.

[Inappropriate Intimacy](#inappropriate-intimacy)

One class uses the internal fields and methods of another class.

[Message Chains](#message-chains)

In code you see a series of calls resembling `$a->b()->c()->d()`

[Middle Man](#middle-man)

If a class performs only one action, delegating work to another class, why does it exist at all?

### Table of Contents

- [Feature Envy](#feature-envy)
- [Inappropriate Intimacy](#inappropriate-intimacy)
- [Incomplete Library Class](#incomplete-library-class)
- [Message Chains](#message-chains)
- [Middle Man](#middle-man)

---

<a id="feature-envy"></a>
## [Feature Envy](https://refactoring.guru/smells/feature-envy)

#### Signs and Symptoms

A method accesses the data of another object more than its own data.

![](https://refactoring.guru/images/refactoring/content/smells/feature-envy-01.png)

#### Reasons for the Problem

This smell may occur after fields are moved to a data class. If this is the case, you may want to move the operations on data to this class as well.

#### Treatment

As a basic rule, if things change at the same time, you should keep them in the same place. Usually data and functions that use this data are changed together (although exceptions are possible).

- If a method clearly should be moved to another place, use [Move Method](Moving%20Features%20between%20Objects.md#move-method).
- If only part of a method accesses the data of another object, use [Extract Method](Composing%20Methods.md#extract-method) to move the part in question.
- If a method uses functions from several other classes, first determine which class contains most of the data used. Then place the method in this class along with the other data. Alternatively, use [Extract Method](Composing%20Methods.md#extract-method) to split the method into several parts that can be placed in different places in different classes.

![](https://refactoring.guru/images/refactoring/content/smells/feature-envy-02.png)

#### Payoff

- Less code duplication (if the data handling code is put in a central place).
- Better code organization (methods for handling data are next to the actual data).

![](https://refactoring.guru/images/refactoring/content/smells/feature-envy-03.png)

#### When to Ignore

- Sometimes behavior is purposefully kept separate from the class that holds the data. The usual advantage of this is the ability to dynamically change the behavior (see [Strategy](https://refactoring.guru/design-patterns/strategy), [Visitor](https://refactoring.guru/design-patterns/visitor) and other patterns).

---

<a id="inappropriate-intimacy"></a>
## [Inappropriate Intimacy](https://refactoring.guru/smells/inappropriate-intimacy)

#### Signs and Symptoms

One class uses the internal fields and methods of another class.

![](https://refactoring.guru/images/refactoring/content/smells/inappropriate-intimacy-01.png)

#### Reasons for the Problem

Keep a close eye on classes that spend too much time together. Good classes should know as little about each other as possible. Such classes are easier to maintain and reuse.

#### Treatment

- The simplest solution is to use [Move Method](Moving%20Features%20between%20Objects.md#move-method) and [Move Field](Moving%20Features%20between%20Objects.md#move-field) to move parts of one class to the class in which those parts are used. But this works only if the first class truly doesn’t need these parts.
  ![](https://refactoring.guru/images/refactoring/content/smells/inappropriate-intimacy-02.png)
- Another solution is to use [Extract Class](Moving%20Features%20between%20Objects.md#extract-class) and [Hide Delegate](Moving%20Features%20between%20Objects.md#hide-delegate) on the class to make the code relations “official”.
- If the classes are mutually interdependent, you should use [Change Bidirectional Association to Unidirectional](Organizing%20Data.md#change-bidirectional-association-to-unidirectional).
- If this “intimacy” is between a subclass and the superclass, consider [Replace Delegation with Inheritance](Dealing%20with%20Generalization.md#replace-delegation-with-inheritance).

![](https://refactoring.guru/images/refactoring/content/smells/inappropriate-intimacy-03.png)

#### Payoff

- Improves code organization.
- Simplifies support and code reuse.

---

<a id="incomplete-library-class"></a>
## [Incomplete Library Class](https://refactoring.guru/smells/incomplete-library-class)

#### Signs and Symptoms

Sooner or later, [libraries](https://en.wikipedia.org/wiki/Library_(computing)) stop meeting user needs. The only solution to the problem—changing the library—is often impossible since the library is read-only.

![](https://refactoring.guru/images/refactoring/content/smells/incomplete-library-class-01.png)

#### Reasons for the Problem

The author of the library hasn’t provided the features you need or has refused to implement them.

#### Treatment

- To introduce a few methods to a library class, use [Introduce Foreign Method](Moving%20Features%20between%20Objects.md#introduce-foreign-method).
- For big changes in a class library, use [Introduce Local Extension](Moving%20Features%20between%20Objects.md#introduce-local-extension).

#### Payoff

- Reduces code duplication (instead of creating your own library from scratch, you can still piggy-back off an existing one).

![](https://refactoring.guru/images/refactoring/content/smells/incomplete-library-class-02.png)

#### When to Ignore

- Extending a library can generate additional work if the changes to the library involve changes in code.

---

<a id="message-chains"></a>
## [Message Chains](https://refactoring.guru/smells/message-chains)

#### Signs and Symptoms

In code you see a series of calls resembling `$a->b()->c()->d()`

![](https://refactoring.guru/images/refactoring/content/smells/message-chains-01.png)

#### Reasons for the Problem

A message chain occurs when a client requests another object, that object requests yet another one, and so on. These chains mean that the client is dependent on navigation along the class structure. Any changes in these relationships require modifying the client.

#### Treatment

- To delete a message chain, use [Hide Delegate](Moving%20Features%20between%20Objects.md#hide-delegate).
- Sometimes it’s better to think of why the end object is being used. Perhaps it would make sense to use [Extract Method](Composing%20Methods.md#extract-method) for this functionality and move it to the beginning of the chain, by using [Move Method](Moving%20Features%20between%20Objects.md#move-method).

![](https://refactoring.guru/images/refactoring/content/smells/message-chains-02.png)

#### Payoff

- Reduces dependencies between classes of a chain.
- Reduces the amount of bloated code.

![](https://refactoring.guru/images/refactoring/content/smells/message-chains-03.png)

#### When to Ignore

- Overly aggressive delegate hiding can cause code in which it’s hard to see where the functionality is actually occurring. Which is another way of saying, avoid the [Middle Man](#middle-man) smell as well.

---

<a id="middle-man"></a>
## [Middle Man](https://refactoring.guru/smells/middle-man)

#### Signs and Symptoms

If a class performs only one action, delegating work to another class, why does it exist at all?

![](https://refactoring.guru/images/refactoring/content/smells/middle-man-01.png)

#### Reasons for the Problem

This smell can be the result of overzealous elimination of [Message Chains](#message-chains).

In other cases, it can be the result of the useful work of a class being gradually moved to other classes. The class remains as an empty shell that doesn’t do anything other than delegate.

#### Treatment

- If most of a method’s classes delegate to another class, [Remove Middle Man](Moving%20Features%20between%20Objects.md#remove-middle-man) is in order.

#### Payoff

- Less bulky code.

![](https://refactoring.guru/images/refactoring/content/smells/middle-man-02.png)

#### When to Ignore

Don’t delete middle man that have been created for a reason:

- A middle man may have been added to avoid interclass dependencies.
- Some design patterns create middle man on purpose (such as [Proxy](https://refactoring.guru/design-patterns/proxy) or [Decorator](https://refactoring.guru/design-patterns/decorator)).

---
