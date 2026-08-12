# Replace Parameter with Method Call - Code Examples

[← Back to Replace Parameter with Method Call explanation](../Simplifying%20Method%20Calls.md#replace-parameter-with-method-call)

**Section:** [Simplifying Method Calls](../Simplifying%20Method%20Calls.md) | **Original:** [Replace Parameter with Method Call](https://refactoring.guru/replace-parameter-with-method-call)

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
int basePrice = quantity * itemPrice;
double seasonDiscount = this.getSeasonalDiscount();
double fees = this.getFees();
double finalPrice = discountedPrice(basePrice, seasonDiscount, fees);
```

**After:**

```java
int basePrice = quantity * itemPrice;
double finalPrice = discountedPrice(basePrice);
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Method Call](../Simplifying%20Method%20Calls.md#replace-parameter-with-method-call)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
int basePrice = quantity * itemPrice;
double seasonDiscount = this.GetSeasonalDiscount();
double fees = this.GetFees();
double finalPrice = DiscountedPrice(basePrice, seasonDiscount, fees);
```

**After:**

```csharp
int basePrice = quantity * itemPrice;
double finalPrice = DiscountedPrice(basePrice);
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Method Call](../Simplifying%20Method%20Calls.md#replace-parameter-with-method-call)

---

<a id="php"></a>
### PHP

**Before:**

```php
$basePrice = $this->quantity * $this->itemPrice;
$seasonDiscount = $this->getSeasonalDiscount();
$fees = $this->getFees();
$finalPrice = $this->discountedPrice($basePrice, $seasonDiscount, $fees);
```

**After:**

```php
$basePrice = $this->quantity * $this->itemPrice;
$finalPrice = $this->discountedPrice($basePrice);
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Method Call](../Simplifying%20Method%20Calls.md#replace-parameter-with-method-call)

---

<a id="python"></a>
### Python

**Before:**

```python
basePrice = quantity * itemPrice
seasonalDiscount = self.getSeasonalDiscount()
fees = self.getFees()
finalPrice = discountedPrice(basePrice, seasonalDiscount, fees)
```

**After:**

```python
basePrice = quantity * itemPrice
finalPrice = discountedPrice(basePrice)
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Method Call](../Simplifying%20Method%20Calls.md#replace-parameter-with-method-call)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
let basePrice = quantity * itemPrice;
const seasonDiscount = this.getSeasonalDiscount();
const fees = this.getFees();
const finalPrice = discountedPrice(basePrice, seasonDiscount, fees);
```

**After:**

```typescript
let basePrice = quantity * itemPrice;
let finalPrice = discountedPrice(basePrice);
```

[↑ Back to top](#available-languages) | [← Back to Replace Parameter with Method Call](../Simplifying%20Method%20Calls.md#replace-parameter-with-method-call)

---
