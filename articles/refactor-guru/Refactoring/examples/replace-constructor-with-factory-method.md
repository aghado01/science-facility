# Replace Constructor with Factory Method - Code Examples

[← Back to Replace Constructor with Factory Method explanation](../Simplifying%20Method%20Calls.md#replace-constructor-with-factory-method)

**Section:** [Simplifying Method Calls](../Simplifying%20Method%20Calls.md) | **Original:** [Replace Constructor with Factory Method](https://refactoring.guru/replace-constructor-with-factory-method)

---

### Available Languages

- [Java](#java)
- [C#](#csharp)
- [PHP](#php)
- [TypeScript](#typescript)

---

<a id="java"></a>
### Java

**Before:**

```java
class Employee {
  Employee(int type) {
    this.type = type;
  }
  // ...
}
```

**After:**

```java
class Employee {
  static Employee create(int type) {
    employee = new Employee(type);
    // do some heavy lifting.
    return employee;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Constructor with Factory Method](../Simplifying%20Method%20Calls.md#replace-constructor-with-factory-method)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
public class Employee 
{
  public Employee(int type) 
  {
    this.type = type;
  }
  // ...
}
```

**After:**

```csharp
public class Employee
{
  public static Employee Create(int type)
  {
    employee = new Employee(type);
    // Do some heavy lifting.
    return employee;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Constructor with Factory Method](../Simplifying%20Method%20Calls.md#replace-constructor-with-factory-method)

---

<a id="php"></a>
### PHP

**Before:**

```php
class Employee {
  // ...
  public function __construct($type) {
   $this->type = $type;
  }
  // ...
}
```

**After:**

```php
class Employee {
  // ...
  static public function create($type) {
    $employee = new Employee($type);
    // do some heavy lifting.
    return $employee;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Constructor with Factory Method](../Simplifying%20Method%20Calls.md#replace-constructor-with-factory-method)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
class Employee {
  constructor(type: number) {
    this.type = type;
  }
  // ...
}
```

**After:**

```typescript
class Employee {
  static create(type: number): Employee {
    let employee = new Employee(type);
    // Do some heavy lifting.
    return employee;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Constructor with Factory Method](../Simplifying%20Method%20Calls.md#replace-constructor-with-factory-method)

---
