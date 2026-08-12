# Introduce Assertion - Code Examples

[← Back to Introduce Assertion explanation](../Simplifying%20Conditional%20Expressions.md#introduce-assertion)

**Section:** [Simplifying Conditional Expressions](../Simplifying%20Conditional%20Expressions.md) | **Original:** [Introduce Assertion](https://refactoring.guru/introduce-assertion)

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
double getExpenseLimit() {
  // Should have either expense limit or
  // a primary project.
  return (expenseLimit != NULL_EXPENSE) ?
    expenseLimit :
    primaryProject.getMemberExpenseLimit();
}
```

**After:**

```java
double getExpenseLimit() {
  Assert.isTrue(expenseLimit != NULL_EXPENSE || primaryProject != null);

  return (expenseLimit != NULL_EXPENSE) ?
    expenseLimit:
    primaryProject.getMemberExpenseLimit();
}
```

[↑ Back to top](#available-languages) | [← Back to Introduce Assertion](../Simplifying%20Conditional%20Expressions.md#introduce-assertion)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
double GetExpenseLimit() 
{
  // Should have either expense limit or
  // a primary project.
  return (expenseLimit != NULL_EXPENSE) ?
    expenseLimit :
    primaryProject.GetMemberExpenseLimit();
}
```

**After:**

```csharp
double GetExpenseLimit() 
{
  Assert.IsTrue(expenseLimit != NULL_EXPENSE || primaryProject != null);

  return (expenseLimit != NULL_EXPENSE) ?
    expenseLimit:
    primaryProject.GetMemberExpenseLimit();
}
```

[↑ Back to top](#available-languages) | [← Back to Introduce Assertion](../Simplifying%20Conditional%20Expressions.md#introduce-assertion)

---

<a id="php"></a>
### PHP

**Before:**

```php
function getExpenseLimit() {
  // Should have either expense limit or
  // a primary project.
  return ($this->expenseLimit !== NULL_EXPENSE) ?
    $this->expenseLimit:
    $this->primaryProject->getMemberExpenseLimit();
}
```

**After:**

```php
function getExpenseLimit() {
  assert($this->expenseLimit !== NULL_EXPENSE || isset($this->primaryProject));

  return ($this->expenseLimit !== NULL_EXPENSE) ?
    $this->expenseLimit:
    $this->primaryProject->getMemberExpenseLimit();
}
```

[↑ Back to top](#available-languages) | [← Back to Introduce Assertion](../Simplifying%20Conditional%20Expressions.md#introduce-assertion)

---

<a id="python"></a>
### Python

**Before:**

```python
def getExpenseLimit(self):
    # Should have either expense limit or
    # a primary project.
    return self.expenseLimit if self.expenseLimit != NULL_EXPENSE else \
        self.primaryProject.getMemberExpenseLimit()
```

**After:**

```python
def getExpenseLimit(self):
    assert (self.expenseLimit != NULL_EXPENSE) or (self.primaryProject != None)

    return self.expenseLimit if (self.expenseLimit != NULL_EXPENSE) else \
        self.primaryProject.getMemberExpenseLimit()
```

[↑ Back to top](#available-languages) | [← Back to Introduce Assertion](../Simplifying%20Conditional%20Expressions.md#introduce-assertion)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
getExpenseLimit(): number {
  // Should have either expense limit or
  // a primary project.
  return (expenseLimit != NULL_EXPENSE) ?
    expenseLimit:
    primaryProject.getMemberExpenseLimit();
}
```

**After:**

```typescript
getExpenseLimit(): number {
  // TypeScript and JS doesn't have built-in assertions, so we'll use
  // good-old console.error(). You can always extract this into a
  // designated assertion function.
  if (!(expenseLimit != NULL_EXPENSE ||
       (typeof primaryProject !== 'undefined' && primaryProject))) {
      console.error("Assertion failed: getExpenseLimit()");
  }

  return (expenseLimit != NULL_EXPENSE) ?
    expenseLimit:
    primaryProject.getMemberExpenseLimit();
}
```

[↑ Back to top](#available-languages) | [← Back to Introduce Assertion](../Simplifying%20Conditional%20Expressions.md#introduce-assertion)

---
