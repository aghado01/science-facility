# Decompose Conditional - Code Examples

[← Back to Decompose Conditional explanation](../Simplifying%20Conditional%20Expressions.md#decompose-conditional)

**Section:** [Simplifying Conditional Expressions](../Simplifying%20Conditional%20Expressions.md) | **Original:** [Decompose Conditional](https://refactoring.guru/decompose-conditional)

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
if (date.before(SUMMER_START) || date.after(SUMMER_END)) {
  charge = quantity * winterRate + winterServiceCharge;
}
else {
  charge = quantity * summerRate;
}
```

**After:**

```java
if (isSummer(date)) {
  charge = summerCharge(quantity);
}
else {
  charge = winterCharge(quantity);
}
```

[↑ Back to top](#available-languages) | [← Back to Decompose Conditional](../Simplifying%20Conditional%20Expressions.md#decompose-conditional)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
if (date < SUMMER_START || date > SUMMER_END) 
{
  charge = quantity * winterRate + winterServiceCharge;
}
else 
{
  charge = quantity * summerRate;
}
```

**After:**

```csharp
if (isSummer(date))
{
  charge = SummerCharge(quantity);
}
else 
{
  charge = WinterCharge(quantity);
}
```

[↑ Back to top](#available-languages) | [← Back to Decompose Conditional](../Simplifying%20Conditional%20Expressions.md#decompose-conditional)

---

<a id="php"></a>
### PHP

**Before:**

```php
if ($date->before(SUMMER_START) || $date->after(SUMMER_END)) {
  $charge = $quantity * $winterRate + $winterServiceCharge;
} else {
  $charge = $quantity * $summerRate;
}
```

**After:**

```php
if (isSummer($date)) {
  $charge = summerCharge($quantity);
} else {
  $charge = winterCharge($quantity);
}
```

[↑ Back to top](#available-languages) | [← Back to Decompose Conditional](../Simplifying%20Conditional%20Expressions.md#decompose-conditional)

---

<a id="python"></a>
### Python

**Before:**

```python
if date.before(SUMMER_START) or date.after(SUMMER_END):
    charge = quantity * winterRate + winterServiceCharge
else:
    charge = quantity * summerRate
```

**After:**

```python
if isSummer(date):
    charge = summerCharge(quantity)
else:
    charge = winterCharge(quantity)
```

[↑ Back to top](#available-languages) | [← Back to Decompose Conditional](../Simplifying%20Conditional%20Expressions.md#decompose-conditional)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
if (date.before(SUMMER_START) || date.after(SUMMER_END)) {
  charge = quantity * winterRate + winterServiceCharge;
}
else {
  charge = quantity * summerRate;
}
```

**After:**

```typescript
if (isSummer(date)) {
  charge = summerCharge(quantity);
}
else {
  charge = winterCharge(quantity);
}
```

[↑ Back to top](#available-languages) | [← Back to Decompose Conditional](../Simplifying%20Conditional%20Expressions.md#decompose-conditional)

---
