# Consolidate Duplicate Conditional Fragments - Code Examples

[← Back to Consolidate Duplicate Conditional Fragments explanation](../Simplifying%20Conditional%20Expressions.md#consolidate-duplicate-conditional-fragments)

**Section:** [Simplifying Conditional Expressions](../Simplifying%20Conditional%20Expressions.md) | **Original:** [Consolidate Duplicate Conditional Fragments](https://refactoring.guru/consolidate-duplicate-conditional-fragments)

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
if (isSpecialDeal()) {
  total = price * 0.95;
  send();
}
else {
  total = price * 0.98;
  send();
}
```

**After:**

```java
if (isSpecialDeal()) {
  total = price * 0.95;
}
else {
  total = price * 0.98;
}
send();
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Duplicate Conditional Fragments](../Simplifying%20Conditional%20Expressions.md#consolidate-duplicate-conditional-fragments)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
if (IsSpecialDeal()) 
{
  total = price * 0.95;
  Send();
}
else 
{
  total = price * 0.98;
  Send();
}
```

**After:**

```csharp
if (IsSpecialDeal())
{
  total = price * 0.95;
}
else
{
  total = price * 0.98;
}
Send();
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Duplicate Conditional Fragments](../Simplifying%20Conditional%20Expressions.md#consolidate-duplicate-conditional-fragments)

---

<a id="php"></a>
### PHP

**Before:**

```php
if (isSpecialDeal()) {
  $total = $price * 0.95;
  send();
} else {
  $total = $price * 0.98;
  send();
}
```

**After:**

```php
if (isSpecialDeal()) {
  $total = $price * 0.95;
} else {
  $total = $price * 0.98;
}
send();
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Duplicate Conditional Fragments](../Simplifying%20Conditional%20Expressions.md#consolidate-duplicate-conditional-fragments)

---

<a id="python"></a>
### Python

**Before:**

```python
if isSpecialDeal():
    total = price * 0.95
    send()
else:
    total = price * 0.98
    send()
```

**After:**

```python
if isSpecialDeal():
    total = price * 0.95
else:
    total = price * 0.98
send()
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Duplicate Conditional Fragments](../Simplifying%20Conditional%20Expressions.md#consolidate-duplicate-conditional-fragments)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
if (isSpecialDeal()) {
  total = price * 0.95;
  send();
}
else {
  total = price * 0.98;
  send();
}
```

**After:**

```typescript
if (isSpecialDeal()) {
  total = price * 0.95;
}
else {
  total = price * 0.98;
}
send();
```

[↑ Back to top](#available-languages) | [← Back to Consolidate Duplicate Conditional Fragments](../Simplifying%20Conditional%20Expressions.md#consolidate-duplicate-conditional-fragments)

---
