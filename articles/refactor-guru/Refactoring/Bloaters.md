# [Bloaters](https://refactoring.guru/refactoring/smells/bloaters)

Bloaters are code, methods and classes that have increased to such gargantuan proportions that they’re hard to work with. Usually these smells don’t crop up right away, rather they accumulate over time as the program evolves (and especially when nobody makes an effort to eradicate them).

[Long Method](#long-method)

A method contains too many lines of code. Generally, any method longer than ten lines should make you start asking questions.

[Large Class](#large-class)

A class contains many fields/methods/lines of code.

[Primitive Obsession](#primitive-obsession)

- Use of primitives instead of small objects for simple tasks (such as currency, ranges, special strings for phone numbers, etc.)
- Use of constants for coding information (such as a constant `USER_ADMIN_ROLE = 1` for referring to users with administrator rights.)
- Use of string constants as field names for use in data arrays.

[Long Parameter List](#long-parameter-list)

More than three or four parameters for a method.

[Data Clumps](#data-clumps)

Sometimes different parts of the code contain identical groups of variables (such as parameters for connecting to a database). These clumps should be turned into their own classes.

### Table of Contents

- [Long Method](#long-method)
- [Large Class](#large-class)
- [Primitive Obsession](#primitive-obsession)
- [Long Parameter List](#long-parameter-list)
- [Data Clumps](#data-clumps)

---

<a id="long-method"></a>
## [Long Method](https://refactoring.guru/smells/long-method)

#### Signs and Symptoms

A method contains too many lines of code. Generally, any method longer than ten lines should make you start asking questions.

![](https://refactoring.guru/images/refactoring/content/smells/long-method-01.png)

#### Reasons for the Problem

Like the Hotel California, something is always being added to a method but nothing is ever taken out. Since it’s easier to write code than to read it, this “smell” remains unnoticed until the method turns into an ugly, oversized beast.

Mentally, it’s often harder to create a new method than to add to an existing one: “But it’s just two lines, there’s no use in creating a whole method just for that...” Which means that another line is added and then yet another, giving birth to a tangle of spaghetti code.

#### Treatment

As a rule of thumb, if you feel the need to comment on something inside a method, you should take this code and put it in a new method. Even a single line can and should be split off into a separate method, if it requires explanations. And if the method has a descriptive name, nobody will need to look at the code to see what it does.

![](https://refactoring.guru/images/refactoring/content/smells/long-method-02.png)

- To reduce the length of a method body, use [Extract Method](Composing%20Methods.md#extract-method).
- If local variables and parameters interfere with extracting a method, use [Replace Temp with Query](Composing%20Methods.md#replace-temp-with-query), [Introduce Parameter Object](Simplifying%20Method%20Calls.md#introduce-parameter-object) or [Preserve Whole Object](Simplifying%20Method%20Calls.md#preserve-whole-object).
- If none of the previous recipes help, try moving the entire method to a separate object via [Replace Method with Method Object](Composing%20Methods.md#replace-method-with-method-object).
- Conditional operators and loops are a good clue that code can be moved to a separate method. For conditionals, use [Decompose Conditional](Simplifying%20Conditional%20Expressions.md#decompose-conditional). If loops are in the way, try [Extract Method](Composing%20Methods.md#extract-method).

#### Payoff

- Among all types of object-oriented code, classes with short methods live longest. The longer a method or function is, the harder it becomes to understand and maintain it.
- In addition, long methods offer the perfect hiding place for unwanted duplicate code.

![](https://refactoring.guru/images/refactoring/content/smells/long-method-03.png)

#### Performance

Does an increase in the number of methods hurt performance, as many people claim? In almost all cases the impact is so negligible that it’s not even worth worrying about.

Plus, now that you have clear and understandable code, you’re more likely to find truly effective methods for restructuring code and getting real performance gains if the need ever arises.

---

<a id="large-class"></a>
## [Large Class](https://refactoring.guru/smells/large-class)

#### Signs and Symptoms

A class contains many fields/methods/lines of code.

![](https://refactoring.guru/images/refactoring/content/smells/large-class-01.png)

#### Reasons for the Problem

Classes usually start small. But over time, they get bloated as the program grows.

As is the case with long methods as well, programmers usually find it mentally less taxing to place a new feature in an existing class than to create a new class for the feature.

![](https://refactoring.guru/images/refactoring/content/smells/large-class-02.png)

#### Treatment

When a class is wearing too many (functional) hats, think about splitting it up:

- [Extract Class](Moving%20Features%20between%20Objects.md#extract-class) helps if part of the behavior of the large class can be spun off into a separate component.
- [Extract Subclass](Dealing%20with%20Generalization.md#extract-subclass) helps if part of the behavior of the large class can be implemented in different ways or is used in rare cases.
- [Extract Interface](Dealing%20with%20Generalization.md#extract-interface) helps if it’s necessary to have a list of the operations and behaviors that the client can use.
- If a large class is responsible for the graphical interface, you may try to move some of its data and behavior to a separate domain object. In doing so, it may be necessary to store copies of some data in two places and keep the data consistent. [Duplicate Observed Data](Organizing%20Data.md#duplicate-observed-data) offers a way to do this.

![](https://refactoring.guru/images/refactoring/content/smells/large-class-03.png)

#### Payoff

- Refactoring of these classes spares developers from needing to remember a large number of attributes for a class.
- In many cases, splitting large classes into parts avoids duplication of code and functionality.

---

<a id="primitive-obsession"></a>
## [Primitive Obsession](https://refactoring.guru/smells/primitive-obsession)

#### Signs and Symptoms

- Use of primitives instead of small objects for simple tasks (such as currency, ranges, special strings for phone numbers, etc.)
- Use of constants for coding information (such as a constant `USER_ADMIN_ROLE = 1` for referring to users with administrator rights.)
- Use of string constants as field names for use in data arrays.

![](https://refactoring.guru/images/refactoring/content/smells/primitive-obsession-01.png)

#### Reasons for the Problem

Like most other smells, primitive obsessions are born in moments of weakness. “Just a field for storing some data!” the programmer said. Creating a primitive field is so much easier than making a whole new class, right? And so it was done. Then another field was needed and added in the same way. Lo and behold, the class became huge and unwieldy.

Primitives are often used to “simulate” types. So instead of a separate data type, you have a set of numbers or strings that form the list of allowable values for some entity. Easy-to-understand names are then given to these specific numbers and strings via constants, which is why they’re spread wide and far.

Another example of poor primitive use is field simulation. The class contains a large array of diverse data and string constants (which are specified in the class) are used as array indices for getting this data.

#### Treatment

- If you have a large variety of primitive fields, it may be possible to logically group some of them into their own class. Even better, move the behavior associated with this data into the class too. For this task, try [Replace Data Value with Object](Organizing%20Data.md#replace-data-value-with-object).
  ![](https://refactoring.guru/images/refactoring/content/smells/primitive-obsession-02.png)
- If the values of primitive fields are used in method parameters, go with [Introduce Parameter Object](Simplifying%20Method%20Calls.md#introduce-parameter-object) or [Preserve Whole Object](Simplifying%20Method%20Calls.md#preserve-whole-object).
- When complicated data is coded in variables, use [Replace Type Code with Class](Organizing%20Data.md#replace-type-code-with-class), [Replace Type Code with Subclasses](Organizing%20Data.md#replace-type-code-with-subclasses) or [Replace Type Code with State/Strategy](Organizing%20Data.md#replace-type-code-with-state-strategy).
- If there are arrays among the variables, use [Replace Array with Object](Organizing%20Data.md#replace-array-with-object).

![](https://refactoring.guru/images/refactoring/content/smells/primitive-obsession-03.png)

#### Payoff

- Code becomes more flexible thanks to use of objects instead of primitives.
- Better understandability and organization of code. Operations on particular data are in the same place, instead of being scattered. No more guessing about the reason for all these strange constants and why they’re in an array.
- Easier finding of duplicate code.

---

<a id="long-parameter-list"></a>
## [Long Parameter List](https://refactoring.guru/smells/long-parameter-list)

#### Signs and Symptoms

More than three or four parameters for a method.

![](https://refactoring.guru/images/refactoring/content/smells/long-parameter-list-01.png)

#### Reasons for the Problem

A long list of parameters might happen after several types of algorithms are merged in a single method. A long list may have been created to control which algorithm will be run and how.

Long parameter lists may also be the byproduct of efforts to make classes more independent of each other. For example, the code for creating specific objects needed in a method was moved from the method to the code for calling the method, but the created objects are passed to the method as parameters. Thus the original class no longer knows about the relationships between objects, and dependency has decreased. But if several of these objects are created, each of them will require its own parameter, which means a longer parameter list.

It’s hard to understand such lists, which become contradictory and hard to use as they grow longer. Instead of a long list of parameters, a method can use the data of its own object. If the current object doesn’t contain all necessary data, another object (which will get the necessary data) can be passed as a method parameter.

#### Treatment

- Check what values are passed to parameters. If some of the arguments are just results of method calls of another object, use [Replace Parameter with Method Call](Simplifying%20Method%20Calls.md#replace-parameter-with-method-call). This object can be placed in the field of its own class or passed as a method parameter.
- Instead of passing a group of data received from another object as parameters, pass the object itself to the method, by using [Preserve Whole Object](Simplifying%20Method%20Calls.md#preserve-whole-object).
- But if these parameters are coming from different sources, you can pass them as a single parameter object via [Introduce Parameter Object](Simplifying%20Method%20Calls.md#introduce-parameter-object).

![](https://refactoring.guru/images/refactoring/content/smells/long-parameter-list-02.png)

#### Payoff

- More readable, shorter code.
- Refactoring may reveal previously unnoticed duplicate code.

#### When to Ignore

- Don’t get rid of parameters if doing so would cause unwanted dependency between classes.

---

<a id="data-clumps"></a>
## [Data Clumps](https://refactoring.guru/smells/data-clumps)

#### Signs and Symptoms

Sometimes different parts of the code contain identical groups of variables (such as parameters for connecting to a database). These clumps should be turned into their own classes.

![](https://refactoring.guru/images/refactoring/content/smells/data-clumps-01.png)

#### Reasons for the Problem

Often these data groups are due to poor program structure or "copypasta programming”.

If you want to make sure whether or not some data is a data clump, just delete one of the data values and see whether the other values still make sense. If this isn’t the case, this is a good sign that this group of variables should be combined into an object.

#### Treatment

- If repeating data comprises the fields of a class, use [Extract Class](Moving%20Features%20between%20Objects.md#extract-class) to move the fields to their own class.
- If the same data clumps are passed in the parameters of methods, use [Introduce Parameter Object](Simplifying%20Method%20Calls.md#introduce-parameter-object) to set them off as a class.
- If some of the data is passed to other methods, think about passing the entire data object to the method instead of just individual fields. [Preserve Whole Object](Simplifying%20Method%20Calls.md#preserve-whole-object) will help with this.
- Look at the code used by these fields. It may be a good idea to move this code to a data class.

![](https://refactoring.guru/images/refactoring/content/smells/data-clumps-02.png)

#### Payoff

- Improves understanding and organization of code. Operations on particular data are now gathered in a single place, instead of haphazardly throughout the code.
- Reduces code size.

![](https://refactoring.guru/images/refactoring/content/smells/data-clumps-03.png)

#### When to Ignore

- Passing an entire object in the parameters of a method, instead of passing just its values (primitive types), may create an undesirable dependency between the two classes.

---
