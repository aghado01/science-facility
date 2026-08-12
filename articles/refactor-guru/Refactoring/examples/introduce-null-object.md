# Introduce Null Object - Code Examples

[← Back to Introduce Null Object explanation](../Simplifying%20Conditional%20Expressions.md#introduce-null-object)

**Section:** [Simplifying Conditional Expressions](../Simplifying%20Conditional%20Expressions.md) | **Original:** [Introduce Null Object](https://refactoring.guru/introduce-null-object)

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
if (customer == null) {
  plan = BillingPlan.basic();
}
else {
  plan = customer.getPlan();
}
```

**After:**

```java
class NullCustomer extends Customer {
  boolean isNull() {
    return true;
  }
  Plan getPlan() {
    return new NullPlan();
  }
  // Some other NULL functionality.
}

// Replace null values with Null-object.
customer = (order.customer != null) ?
  order.customer : new NullCustomer();

// Use Null-object as if it's normal subclass.
plan = customer.getPlan();
```

[↑ Back to top](#available-languages) | [← Back to Introduce Null Object](../Simplifying%20Conditional%20Expressions.md#introduce-null-object)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
if (customer == null) 
{
  plan = BillingPlan.Basic();
}
else 
{
  plan = customer.GetPlan();
}
```

**After:**

```csharp
public sealed class NullCustomer: Customer 
{
  public override bool IsNull 
  {
    get { return true; }
  }
  
  public override Plan GetPlan() 
  {
    return new NullPlan();
  }
  // Some other NULL functionality.
}

// Replace null values with Null-object.
customer = order.customer ?? new NullCustomer();

// Use Null-object as if it's normal subclass.
plan = customer.GetPlan();
```

[↑ Back to top](#available-languages) | [← Back to Introduce Null Object](../Simplifying%20Conditional%20Expressions.md#introduce-null-object)

---

<a id="php"></a>
### PHP

**Before:**

```php
if ($customer === null) {
  $plan = BillingPlan::basic();
} else {
  $plan = $customer->getPlan();
}
```

**After:**

```php
class NullCustomer extends Customer {
  public function isNull() {
    return true;
  }
  public function getPlan() {
    return new NullPlan();
  }
  // Some other NULL functionality.
}

// Replace null values with Null-object.
$customer = ($order->customer !== null) ?
  $order->customer :
  new NullCustomer;

// Use Null-object as if it's normal subclass.
$plan = $customer->getPlan();
```

[↑ Back to top](#available-languages) | [← Back to Introduce Null Object](../Simplifying%20Conditional%20Expressions.md#introduce-null-object)

---

<a id="python"></a>
### Python

**Before:**

```python
if customer is None:
    plan = BillingPlan.basic()
else:
    plan = customer.getPlan()
```

**After:**

```python
class NullCustomer(Customer):

    def isNull(self):
        return True

    def getPlan(self):
        return self.NullPlan()

    # Some other NULL functionality.

# Replace null values with Null-object.
customer = order.customer or NullCustomer()

# Use Null-object as if it's normal subclass.
plan = customer.getPlan()
```

[↑ Back to top](#available-languages) | [← Back to Introduce Null Object](../Simplifying%20Conditional%20Expressions.md#introduce-null-object)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
if (customer == null) {
  plan = BillingPlan.basic();
}
else {
  plan = customer.getPlan();
}
```

**After:**

```typescript
class NullCustomer extends Customer {
  isNull(): boolean {
    return true;
  }
  getPlan(): Plan {
    return new NullPlan();
  }
  // Some other NULL functionality.
}

// Replace null values with Null-object.
let customer = (order.customer != null) ?
  order.customer : new NullCustomer();

// Use Null-object as if it's normal subclass.
plan = customer.getPlan();
```

[↑ Back to top](#available-languages) | [← Back to Introduce Null Object](../Simplifying%20Conditional%20Expressions.md#introduce-null-object)

---
