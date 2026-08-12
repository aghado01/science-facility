# Inline Temp - Code Examples

[← Back to Inline Temp explanation](../Composing%20Methods.md#inline-temp)

**Section:** [Composing Methods](../Composing%20Methods.md) | **Original:** [Inline Temp](https://refactoring.guru/inline-temp)

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
boolean hasDiscount(Order order) {
  double basePrice = order.basePrice();
  return basePrice > 1000;
}
```

**After:**

```java
boolean hasDiscount(Order order) {
  return order.basePrice() > 1000;
}
```

[↑ Back to top](#available-languages) | [← Back to Inline Temp](../Composing%20Methods.md#inline-temp)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
bool HasDiscount(Order order)
{
  double basePrice = order.BasePrice();
  return basePrice > 1000;
}
```

**After:**

```csharp
bool HasDiscount(Order order)
{
  return order.BasePrice() > 1000;
}
```

[↑ Back to top](#available-languages) | [← Back to Inline Temp](../Composing%20Methods.md#inline-temp)

---

<a id="php"></a>
### PHP

**Before:**

```php
$basePrice = $anOrder->basePrice();
return $basePrice > 1000;
```

**After:**

```php
return $anOrder->basePrice() > 1000;
```

[↑ Back to top](#available-languages) | [← Back to Inline Temp](../Composing%20Methods.md#inline-temp)

---

<a id="python"></a>
### Python

**Before:**

```python
def hasDiscount(order):
    basePrice = order.basePrice()
    return basePrice > 1000
```

**After:**

```python
def hasDiscount(order):
    return order.basePrice() > 1000
```

[↑ Back to top](#available-languages) | [← Back to Inline Temp](../Composing%20Methods.md#inline-temp)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
hasDiscount(order: Order): boolean {
  let basePrice: number = order.basePrice();
  return basePrice > 1000;
}
```

**After:**

```typescript
hasDiscount(order: Order): boolean {
  return order.basePrice() > 1000;
}
```

[↑ Back to top](#available-languages) | [← Back to Inline Temp](../Composing%20Methods.md#inline-temp)

---
