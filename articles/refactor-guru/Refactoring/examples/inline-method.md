# Inline Method - Code Examples

[← Back to Inline Method explanation](../Composing%20Methods.md#inline-method)

**Section:** [Composing Methods](../Composing%20Methods.md) | **Original:** [Inline Method](https://refactoring.guru/inline-method)

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
class PizzaDelivery {
  // ...
  int getRating() {
    return moreThanFiveLateDeliveries() ? 2 : 1;
  }
  boolean moreThanFiveLateDeliveries() {
    return numberOfLateDeliveries > 5;
  }
}
```

**After:**

```java
class PizzaDelivery {
  // ...
  int getRating() {
    return numberOfLateDeliveries > 5 ? 2 : 1;
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Inline Method](../Composing%20Methods.md#inline-method)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
class PizzaDelivery 
{
  // ...
  int GetRating() 
  {
    return MoreThanFiveLateDeliveries() ? 2 : 1;
  }
  bool MoreThanFiveLateDeliveries() 
  {
    return numberOfLateDeliveries > 5;
  }
}
```

**After:**

```csharp
class PizzaDelivery 
{
  // ...
  int GetRating() 
  {
    return numberOfLateDeliveries > 5 ? 2 : 1;
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Inline Method](../Composing%20Methods.md#inline-method)

---

<a id="php"></a>
### PHP

**Before:**

```php
function getRating() {
  return ($this->moreThanFiveLateDeliveries()) ? 2 : 1;
}
function moreThanFiveLateDeliveries() {
  return $this->numberOfLateDeliveries > 5;
}
```

**After:**

```php
function getRating() {
  return ($this->numberOfLateDeliveries > 5) ? 2 : 1;
}
```

[↑ Back to top](#available-languages) | [← Back to Inline Method](../Composing%20Methods.md#inline-method)

---

<a id="python"></a>
### Python

**Before:**

```python
class PizzaDelivery:
    # ...
    def getRating(self):
        return 2 if self.moreThanFiveLateDeliveries() else 1
  
    def moreThanFiveLateDeliveries(self):
        return self.numberOfLateDeliveries > 5
```

**After:**

```python
class PizzaDelivery:
  # ...
  def getRating(self):
    return 2 if self.numberOfLateDeliveries > 5 else 1
```

[↑ Back to top](#available-languages) | [← Back to Inline Method](../Composing%20Methods.md#inline-method)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
class PizzaDelivery {
  // ...
  getRating(): number {
    return moreThanFiveLateDeliveries() ? 2 : 1;
  }
  moreThanFiveLateDeliveries(): boolean {
    return numberOfLateDeliveries > 5;
  }
}
```

**After:**

```typescript
class PizzaDelivery {
  // ...
  getRating(): number {
    return numberOfLateDeliveries > 5 ? 2 : 1;
  }
}
```

[↑ Back to top](#available-languages) | [← Back to Inline Method](../Composing%20Methods.md#inline-method)

---
