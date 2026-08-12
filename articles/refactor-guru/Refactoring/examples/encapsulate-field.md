# Encapsulate Field - Code Examples

[← Back to Encapsulate Field explanation](../Organizing%20Data.md#encapsulate-field)

**Section:** [Organizing Data](../Organizing%20Data.md) | **Original:** [Encapsulate Field](https://refactoring.guru/encapsulate-field)

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
class Person {
  public String name;
}
```

**After:**

```java
class Person {
  private String name;

  public String getName() {
    return name;
  }
  public void setName(String arg) {
    name = arg;
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Encapsulate Field](../Organizing%20Data.md#encapsulate-field)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
class Person 
{
  public string name;
}
```

**After:**

```csharp
class Person 
{
  private string name;

  public string Name
  {
    get { return name; }
    set { name = value; }
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Encapsulate Field](../Organizing%20Data.md#encapsulate-field)

---

<a id="php"></a>
### PHP

**Before:**

```php
public $name;
```

**After:**

```php
private $name;

public getName() {
  return $this->name;
}

public setName($arg) {
  $this->name = $arg;
}
```

[↑ Back to top](#available-languages) | [← Back to Encapsulate Field](../Organizing%20Data.md#encapsulate-field)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
class Person {
  name: string;
}
```

**After:**

```typescript
class Person {
  private _name: string;

  get name() {
    return this._name;
  }
  setName(arg: string): void {
    this._name = arg;
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Encapsulate Field](../Organizing%20Data.md#encapsulate-field)

---
