#### Four Guidelines

Kent Beck’s Four “Rules” of Simple Design are (in Kent’s order of precedence, and written with my interpretation):

1. **It works!** It does what we expect at this point in time. **_It has tests, and they all pass._**
2. **It’s understandable:** The code is expressive, concise, and obvious to the team.
3. **Once and only once (OAOO):** Behaviors, concepts, and configuration details are defined in one location in the system (code, build scripts, config files). Don’t Repeat Yourself (DRY).
4. **Minimal:** Nothing extra. Nothing designed for some as-yet-unforeseen future need. You Aren’t Going to Need It (YAGNI)

You’ll notice that there is a lot of overlap. For example, rules 2 through 4 could all dissuade you from creating an unnecessary class.

#### Five Heuristics

Daniel Terhorst-North has formulated a similarly straightforward set of heuristics that also help guide and evaluate software design. He calls this C.U.P.I.D.

Again, I’ve elaborated upon, or interpreted, the descriptions.

1. **Composable:** Plays well with others. Small interfaces, intention-revealing names, and few dependencies.
2. **Unix philosophy:** Does one thing well. Conceptually “fits in my head.”
3. **Predictable:** Does what you expect. Deterministic. ***Passes all the tests.* **No “subtype surprises” (doesn’t break Liskov’s Substitution Principle).
4. **Idiomatic:** Feels natural. Uses language idioms. Uses, or allows for the emergence of, team coding standards.
5. **Domain-based:** Uses a ubiquitous domain language. Code is written to satisfy stakeholder requests, not frameworks or dogmatic rules.

#### Code Smells

New behaviors introduced by changing requirements leave their mark on the design. This is the very thing that would drive good developers away from software development: We design our system, and then an unexpected request alters our preconceived pristine design, often in detrimental ways.

This deterioration happens on a large scale, as it did in my pre-Agile years.

It is also _expected_, on a tiny scale, with Test-Driven Development. When we use TDD, each tiny new unit test, and the implementation of that specified behavior, has a commensurately tiny negative impact on design. We repair the damage through Diligent Refactoring, but we have to first recognize and identify the damage.

How to see the damage done on such a tiny scale? You’ve likely been doing it your whole development career: You notice that something isn’t quite right, or that a few small changes could place the new and old behaviors in a better relationship to each other.

In Martin Fowler’s book, _Refactoring_, Kent Beck and Fowler chose to use the term “code smells” to refer to these infractions against good design. They listed many of the common smells and gave them names, similar to Design Pattern names, so teams can communicate effectively about the smells they dislike. They also provided a table (in the back of the Refactoring book, or here, [https://refactoring.guru/refactoring/smells](https://refactoring.guru/refactoring/smells) ) mapping code smells to the refactorings that will help.

#### Practices

Instead of encouraging philosophical debates over “good,” I recommend teams adopt iterative/incremental practices that help maintain their software by removing code smells as they arise: TDD and BDD, Diligent Refactoring, Continuous Integration, Continuous Collaboration (pair/ensemble-programming; & sitting together or always visible on Zoom/Teams), Collective Stewardship, Continuous Learning.
