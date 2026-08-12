# Replace Nested Conditional with Guard Clauses - Code Examples

[← Back to Replace Nested Conditional with Guard Clauses explanation](../Simplifying%20Conditional%20Expressions.md#replace-nested-conditional-with-guard-clauses)

**Section:** [Simplifying Conditional Expressions](../Simplifying%20Conditional%20Expressions.md) | **Original:** [Replace Nested Conditional with Guard Clauses](https://refactoring.guru/replace-nested-conditional-with-guard-clauses)

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
public double getPayAmount() {
  double result;
  if (isDead){
    result = deadAmount();
  }
  else {
    if (isSeparated){
      result = separatedAmount();
    }
    else {
      if (isRetired){
        result = retiredAmount();
      }
      else{
        result = normalPayAmount();
      }
    }
  }
  return result;
}
```

**After:**

```java
public double getPayAmount() {
  if (isDead){
    return deadAmount();
  }
  if (isSeparated){
    return separatedAmount();
  }
  if (isRetired){
    return retiredAmount();
  }
  return normalPayAmount();
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Nested Conditional with Guard Clauses](../Simplifying%20Conditional%20Expressions.md#replace-nested-conditional-with-guard-clauses)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
public double GetPayAmount()
{
  double result;
  
  if (isDead)
  {
    result = DeadAmount();
  }
  else 
  {
    if (isSeparated)
    {
      result = SeparatedAmount();
    }
    else 
    {
      if (isRetired)
      {
        result = RetiredAmount();
      }
      else
      {
        result = NormalPayAmount();
      }
    }
  }
  
  return result;
}
```

**After:**

```csharp
public double GetPayAmount() 
{
  if (isDead)
  {
    return DeadAmount();
  }
  if (isSeparated)
  {
    return SeparatedAmount();
  }
  if (isRetired)
  {
    return RetiredAmount();
  }
  return NormalPayAmount();
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Nested Conditional with Guard Clauses](../Simplifying%20Conditional%20Expressions.md#replace-nested-conditional-with-guard-clauses)

---

<a id="php"></a>
### PHP

**Before:**

```php
function getPayAmount() {
  if ($this->isDead) {
    $result = $this->deadAmount();
  } else {
    if ($this->isSeparated) {
      $result = $this->separatedAmount();
    } else {
      if ($this->isRetired) {
        $result = $this->retiredAmount();
      } else {
        $result = $this->normalPayAmount();
      }
    }
  }
  return $result;
}
```

**After:**

```php
function getPayAmount() {
  if ($this->isDead) {
    return $this->deadAmount();
  }
  if ($this->isSeparated) {
    return $this->separatedAmount();
  }
  if ($this->isRetired) {
    return $this->retiredAmount();
  }
  return $this->normalPayAmount();
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Nested Conditional with Guard Clauses](../Simplifying%20Conditional%20Expressions.md#replace-nested-conditional-with-guard-clauses)

---

<a id="python"></a>
### Python

**Before:**

```python
def getPayAmount(self):
    if self.isDead:
        result = deadAmount()
    else:
        if self.isSeparated:
            result = separatedAmount()
        else:
            if self.isRetired:
                result = retiredAmount()
            else:
                result = normalPayAmount()
    return result
```

**After:**

```python
def getPayAmount(self):
    if self.isDead:
        return deadAmount()
    if self.isSeparated:
        return separatedAmount()
    if self.isRetired:
        return retiredAmount()
    return normalPayAmount()
```

[↑ Back to top](#available-languages) | [← Back to Replace Nested Conditional with Guard Clauses](../Simplifying%20Conditional%20Expressions.md#replace-nested-conditional-with-guard-clauses)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
getPayAmount(): number {
  let result: number;
  if (isDead){
    result = deadAmount();
  }
  else {
    if (isSeparated){
      result = separatedAmount();
    }
    else {
      if (isRetired){
        result = retiredAmount();
      }
      else{
        result = normalPayAmount();
      }
    }
  }
  return result;
}
```

**After:**

```typescript
getPayAmount(): number {
  if (isDead){
    return deadAmount();
  }
  if (isSeparated){
    return separatedAmount();
  }
  if (isRetired){
    return retiredAmount();
  }
  return normalPayAmount();
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Nested Conditional with Guard Clauses](../Simplifying%20Conditional%20Expressions.md#replace-nested-conditional-with-guard-clauses)

---
