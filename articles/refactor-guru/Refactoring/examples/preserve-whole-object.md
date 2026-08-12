# Preserve Whole Object - Code Examples

[← Back to Preserve Whole Object explanation](../Simplifying%20Method%20Calls.md#preserve-whole-object)

**Section:** [Simplifying Method Calls](../Simplifying%20Method%20Calls.md) | **Original:** [Preserve Whole Object](https://refactoring.guru/preserve-whole-object)

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
int low = daysTempRange.getLow();
int high = daysTempRange.getHigh();
boolean withinPlan = plan.withinRange(low, high);
```

**After:**

```java
boolean withinPlan = plan.withinRange(daysTempRange);
```

[↑ Back to top](#available-languages) | [← Back to Preserve Whole Object](../Simplifying%20Method%20Calls.md#preserve-whole-object)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
int low = daysTempRange.GetLow();
int high = daysTempRange.GetHigh();
bool withinPlan = plan.WithinRange(low, high);
```

**After:**

```csharp
bool withinPlan = plan.WithinRange(daysTempRange);
```

[↑ Back to top](#available-languages) | [← Back to Preserve Whole Object](../Simplifying%20Method%20Calls.md#preserve-whole-object)

---

<a id="php"></a>
### PHP

**Before:**

```php
$low = $daysTempRange->getLow();
$high = $daysTempRange->getHigh();
$withinPlan = $plan->withinRange($low, $high);
```

**After:**

```php
$withinPlan = $plan->withinRange($daysTempRange);
```

[↑ Back to top](#available-languages) | [← Back to Preserve Whole Object](../Simplifying%20Method%20Calls.md#preserve-whole-object)

---

<a id="python"></a>
### Python

**Before:**

```python
low = daysTempRange.getLow()
high = daysTempRange.getHigh()
withinPlan = plan.withinRange(low, high)
```

**After:**

```python
withinPlan = plan.withinRange(daysTempRange)
```

[↑ Back to top](#available-languages) | [← Back to Preserve Whole Object](../Simplifying%20Method%20Calls.md#preserve-whole-object)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
let low = daysTempRange.getLow();
let high = daysTempRange.getHigh();
let withinPlan = plan.withinRange(low, high);
```

**After:**

```typescript
let withinPlan = plan.withinRange(daysTempRange);
```

[↑ Back to top](#available-languages) | [← Back to Preserve Whole Object](../Simplifying%20Method%20Calls.md#preserve-whole-object)

---
