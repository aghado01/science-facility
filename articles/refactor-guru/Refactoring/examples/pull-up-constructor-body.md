# Pull Up Constructor Body - Code Examples

[← Back to Pull Up Constructor Body explanation](../Dealing%20with%20Generalization.md#pull-up-constructor-body)

**Section:** [Dealing with Generalization](../Dealing%20with%20Generalization.md) | **Original:** [Pull Up Constructor Body](https://refactoring.guru/pull-up-constructor-body)

---

### Available Languages

- [Java](#java)
- [C#](#csharp)
- [PHP](#php)
- [Python](#python)
- [TypeScript](#typescript)

---

<a id="java"></a>
### Java

**Before:**

```java
class Manager extends Employee {
  public Manager(String name, String id, int grade) {
    this.name = name;
    this.id = id;
    this.grade = grade;
  }
  // ...
}
```

**After:**

```java
class Manager extends Employee {
  public Manager(String name, String id, int grade) {
    super(name, id);
    this.grade = grade;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Pull Up Constructor Body](../Dealing%20with%20Generalization.md#pull-up-constructor-body)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
public class Manager: Employee 
{
  public Manager(string name, string id, int grade) 
  {
    this.name = name;
    this.id = id;
    this.grade = grade;
  }
  // ...
}
```

**After:**

```csharp
public class Manager: Employee 
{
  public Manager(string name, string id, int grade): base(name, id)
  {
    this.grade = grade;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Pull Up Constructor Body](../Dealing%20with%20Generalization.md#pull-up-constructor-body)

---

<a id="php"></a>
### PHP

**Before:**

```php
class Manager extends Employee {
  public function __construct($name, $id, $grade) {
    $this->name = $name;
    $this->id = $id;
    $this->grade = $grade;
  }
  // ...
}
```

**After:**

```php
class Manager extends Employee {
  public function __construct($name, $id, $grade) {
    parent::__construct($name, $id);
    $this->grade = $grade;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Pull Up Constructor Body](../Dealing%20with%20Generalization.md#pull-up-constructor-body)

---

<a id="python"></a>
### Python

**Before:**

```python
class Manager(Employee):
    def __init__(self, name, id, grade):
        self.name = name
        self.id = id
        self.grade = grade
    # ...
```

**After:**

```python
class Manager(Employee):
    def __init__(self, name, id, grade):
        Employee.__init__(name, id)
        self.grade = grade
    # ...
```

[↑ Back to top](#available-languages) | [← Back to Pull Up Constructor Body](../Dealing%20with%20Generalization.md#pull-up-constructor-body)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
class Manager extends Employee {
  constructor(name: string, id: string, grade: number) {
    this.name = name;
    this.id = id;
    this.grade = grade;
  }
  // ...
}
```

**After:**

```typescript
class Manager extends Employee {
  constructor(name: string, id: string, grade: number) {
    super(name, id);
    this.grade = grade;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Pull Up Constructor Body](../Dealing%20with%20Generalization.md#pull-up-constructor-body)

---
