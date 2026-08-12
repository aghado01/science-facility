# Consolidate Conditional Expression - Code Examples

[← Back to Consolidate Conditional Expression explanation](../Simplifying%20Conditional%20Expressions.md#consolidate-conditional-expression)

**Section:** [Simplifying Conditional Expressions](../Simplifying%20Conditional%20Expressions.md) | **Original:** [Consolidate Conditional Expression](https://refactoring.guru/consolidate-conditional-expression)

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
double disabilityAmount() {
  if (seniority < 2) {
    return 0;
  }
  if (monthsDisabled > 12) {
    return 0;
  }
  if (isPartTime) {
    return 0;
  }
  // Compute the disability amount.
  // ...
}
```

**After:**

```java
double disabilityAmount() {
  if (isNotEligibleForDisability()) {
    return 0;
  }
  // Compute the disability amount.
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Conditional Expression](../Simplifying%20Conditional%20Expressions.md#consolidate-conditional-expression)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
double DisabilityAmount() 
{
  if (seniority < 2) 
  {
    return 0;
  }
  if (monthsDisabled > 12) 
  {
    return 0;
  }
  if (isPartTime) 
  {
    return 0;
  }
  // Compute the disability amount.
  // ...
}
```

**After:**

```csharp
double DisabilityAmount()
{
  if (IsNotEligibleForDisability())
  {
    return 0;
  }
  // Compute the disability amount.
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Conditional Expression](../Simplifying%20Conditional%20Expressions.md#consolidate-conditional-expression)

---

<a id="php"></a>
### PHP

**Before:**

```php
function disabilityAmount() {
  if ($this->seniority < 2) {
    return 0;
  }
  if ($this->monthsDisabled > 12) {
    return 0;
  }
  if ($this->isPartTime) {
    return 0;
  }
  // compute the disability amount
  ...
```

**After:**

```php
function disabilityAmount() {
  if ($this->isNotEligibleForDisability()) {
    return 0;
  }
  // compute the disability amount
  ...
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Conditional Expression](../Simplifying%20Conditional%20Expressions.md#consolidate-conditional-expression)

---

<a id="python"></a>
### Python

**Before:**

```python
def disabilityAmount():
    if seniority < 2:
        return 0
    if monthsDisabled > 12:
        return 0
    if isPartTime:
        return 0
    # Compute the disability amount.
    # ...
```

**After:**

```python
def disabilityAmount():
    if isNotEligibleForDisability():
        return 0
    # Compute the disability amount.
    # ...
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Conditional Expression](../Simplifying%20Conditional%20Expressions.md#consolidate-conditional-expression)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
disabilityAmount(): number {
  if (seniority < 2) {
    return 0;
  }
  if (monthsDisabled > 12) {
    return 0;
  }
  if (isPartTime) {
    return 0;
  }
  // Compute the disability amount.
  // ...
}
```

**After:**

```typescript
disabilityAmount(): number {
  if (isNotEligibleForDisability()) {
    return 0;
  }
  // Compute the disability amount.
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Conditional Expression](../Simplifying%20Conditional%20Expressions.md#consolidate-conditional-expression)

---
