# Self Encapsulate Field - Code Examples

[← Back to Self Encapsulate Field explanation](../Organizing%20Data.md#self-encapsulate-field)

**Section:** [Organizing Data](../Organizing%20Data.md) | **Original:** [Self Encapsulate Field](https://refactoring.guru/self-encapsulate-field)

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
class Range {
  private int low, high;
  boolean includes(int arg) {
    return arg >= low && arg <= high;
  }
}
```

**After:**

```java
class Range {
  private int low, high;
  boolean includes(int arg) {
    return arg >= getLow() && arg <= getHigh();
  }
  int getLow() {
    return low;
  }
  int getHigh() {
    return high;
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Self Encapsulate Field](../Organizing%20Data.md#self-encapsulate-field)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
class Range 
{
  private int low, high;
  
  bool Includes(int arg) 
  {
    return arg >= low && arg <= high;
  }
}
```

**After:**

```csharp
class Range 
{
  private int low, high;
  
  int Low {
    get { return low; }
  }
  int High {
    get { return high; }
  }
  
  bool Includes(int arg) 
  {
    return arg >= Low && arg <= High;
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Self Encapsulate Field](../Organizing%20Data.md#self-encapsulate-field)

---

<a id="php"></a>
### PHP

**Before:**

```php
private $low;
private $high;

function includes($arg) {
  return $arg >= $this->low && $arg <= $this->high;
}
```

**After:**

```php
private $low;
private $high;

function includes($arg) {
  return $arg >= $this->getLow() && $arg <= $this->getHigh();
}
function getLow() {
  return $this->low;
}
function getHigh() {
  return $this->high;
}
```

[↑ Back to top](#available-languages) | [← Back to Self Encapsulate Field](../Organizing%20Data.md#self-encapsulate-field)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
class Range {
  private low: number
  private high: number;
  includes(arg: number): boolean {
    return arg >= low && arg <= high;
  }
}
```

**After:**

```typescript
class Range {
  private low: number
  private high: number;
  includes(arg: number): boolean {
    return arg >= getLow() && arg <= getHigh();
  }
  getLow(): number {
    return low;
  }
  getHigh(): number {
    return high;
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Self Encapsulate Field](../Organizing%20Data.md#self-encapsulate-field)

---
