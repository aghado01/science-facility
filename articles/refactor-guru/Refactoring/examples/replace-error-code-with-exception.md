# Replace Error Code with Exception - Code Examples

[← Back to Replace Error Code with Exception explanation](../Simplifying%20Method%20Calls.md#replace-error-code-with-exception)

**Section:** [Simplifying Method Calls](../Simplifying%20Method%20Calls.md) | **Original:** [Replace Error Code with Exception](https://refactoring.guru/replace-error-code-with-exception)

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
int withdraw(int amount) {
  if (amount > _balance) {
    return -1;
  }
  else {
    balance -= amount;
    return 0;
  }
}
```

**After:**

```java
void withdraw(int amount) throws BalanceException {
  if (amount > _balance) {
    throw new BalanceException();
  }
  balance -= amount;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Error Code with Exception](../Simplifying%20Method%20Calls.md#replace-error-code-with-exception)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
int Withdraw(int amount) 
{
  if (amount > _balance) 
  {
    return -1;
  }
  else 
  {
    balance -= amount;
    return 0;
  }
}
```

**After:**

```csharp
///<exception cref="BalanceException">Thrown when amount > _balance</exception>
void Withdraw(int amount)
{
  if (amount > _balance) 
  {
    throw new BalanceException();
  }
  balance -= amount;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Error Code with Exception](../Simplifying%20Method%20Calls.md#replace-error-code-with-exception)

---

<a id="php"></a>
### PHP

**Before:**

```php
function withdraw($amount) {
  if ($amount > $this->balance) {
    return -1;
  } else {
    $this->balance -= $amount;
    return 0;
  }
}
```

**After:**

```php
function withdraw($amount) {
  if ($amount > $this->balance) {
    throw new BalanceException;
  }
  $this->balance -= $amount;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Error Code with Exception](../Simplifying%20Method%20Calls.md#replace-error-code-with-exception)

---

<a id="python"></a>
### Python

**Before:**

```python
def withdraw(self, amount):
    if amount > self.balance:
        return -1
    else:
        self.balance -= amount
    return 0
```

**After:**

```python
def withdraw(self, amount):
    if amount > self.balance:
        raise BalanceException()
    self.balance -= amount
```

[↑ Back to top](#available-languages) | [← Back to Replace Error Code with Exception](../Simplifying%20Method%20Calls.md#replace-error-code-with-exception)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
withdraw(amount: number): number {
  if (amount > _balance) {
    return -1;
  }
  else {
    balance -= amount;
    return 0;
  }
}
```

**After:**

```typescript
withdraw(amount: number): void {
  if (amount > _balance) {
    throw new Error();
  }
  balance -= amount;
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Error Code with Exception](../Simplifying%20Method%20Calls.md#replace-error-code-with-exception)

---
