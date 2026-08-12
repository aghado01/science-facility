# Replace Temp with Query - Code Examples

[← Back to Replace Temp with Query explanation](../Composing%20Methods.md#replace-temp-with-query)

**Section:** [Composing Methods](../Composing%20Methods.md) | **Original:** [Replace Temp with Query](https://refactoring.guru/replace-temp-with-query)

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
double calculateTotal() {
  double basePrice = quantity * itemPrice;
  if (basePrice > 1000) {
    return basePrice * 0.95;
  }
  else {
    return basePrice * 0.98;
  }
}
```

**After:**

```java
double calculateTotal() {
  if (basePrice() > 1000) {
    return basePrice() * 0.95;
  }
  else {
    return basePrice() * 0.98;
  }
}
double basePrice() {
  return quantity * itemPrice;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Temp with Query](../Composing%20Methods.md#replace-temp-with-query)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
double CalculateTotal() 
{
  double basePrice = quantity * itemPrice;
  
  if (basePrice > 1000) 
  {
    return basePrice * 0.95;
  }
  else 
  {
    return basePrice * 0.98;
  }
}
```

**After:**

```csharp
double CalculateTotal() 
{
  if (BasePrice() > 1000) 
  {
    return BasePrice() * 0.95;
  }
  else 
  {
    return BasePrice() * 0.98;
  }
}
double BasePrice() 
{
  return quantity * itemPrice;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Temp with Query](../Composing%20Methods.md#replace-temp-with-query)

---

<a id="php"></a>
### PHP

**Before:**

```php
$basePrice = $this->quantity * $this->itemPrice;
if ($basePrice > 1000) {
  return $basePrice * 0.95;
} else {
  return $basePrice * 0.98;
}
```

**After:**

```php
if ($this->basePrice() > 1000) {
  return $this->basePrice() * 0.95;
} else {
  return $this->basePrice() * 0.98;
}

...

function basePrice() {
  return $this->quantity * $this->itemPrice;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Temp with Query](../Composing%20Methods.md#replace-temp-with-query)

---

<a id="python"></a>
### Python

**Before:**

```python
def calculateTotal():
    basePrice = quantity * itemPrice
    if basePrice > 1000:
        return basePrice * 0.95
    else:
        return basePrice * 0.98
```

**After:**

```python
def calculateTotal():
    if basePrice() > 1000:
        return basePrice() * 0.95
    else:
        return basePrice() * 0.98

def basePrice():
    return quantity * itemPrice
```

[↑ Back to top](#available-languages) | [← Back to Replace Temp with Query](../Composing%20Methods.md#replace-temp-with-query)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
calculateTotal(): number {
  let basePrice = quantity * itemPrice;
  if (basePrice > 1000) {
    return basePrice * 0.95;
  }
  else {
    return basePrice * 0.98;
  }
}
```

**After:**

```typescript
calculateTotal(): number {
  if (basePrice() > 1000) {
    return basePrice() * 0.95;
  }
  else {
    return basePrice() * 0.98;
  }
}
basePrice(): number {
  return quantity * itemPrice;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Temp with Query](../Composing%20Methods.md#replace-temp-with-query)

---
