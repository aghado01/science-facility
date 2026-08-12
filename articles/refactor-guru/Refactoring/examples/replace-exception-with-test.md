# Replace Exception with Test - Code Examples

[← Back to Replace Exception with Test explanation](../Simplifying%20Method%20Calls.md#replace-exception-with-test)

**Section:** [Simplifying Method Calls](../Simplifying%20Method%20Calls.md) | **Original:** [Replace Exception with Test](https://refactoring.guru/replace-exception-with-test)

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
double getValueForPeriod(int periodNumber) {
  try {
    return values[periodNumber];
  } catch (ArrayIndexOutOfBoundsException e) {
    return 0;
  }
}
```

**After:**

```java
double getValueForPeriod(int periodNumber) {
  if (periodNumber >= values.length) {
    return 0;
  }
  return values[periodNumber];
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Exception with Test](../Simplifying%20Method%20Calls.md#replace-exception-with-test)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
double GetValueForPeriod(int periodNumber) 
{
  try 
  {
    return values[periodNumber];
  } 
  catch (IndexOutOfRangeException e) 
  {
    return 0;
  }
}
```

**After:**

```csharp
double GetValueForPeriod(int periodNumber) 
{
  if (periodNumber >= values.Length) 
  {
    return 0;
  }
  return values[periodNumber];
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Exception with Test](../Simplifying%20Method%20Calls.md#replace-exception-with-test)

---

<a id="php"></a>
### PHP

**Before:**

```php
function getValueForPeriod($periodNumber) {
  try {
    return $this->values[$periodNumber];
  } catch (ArrayIndexOutOfBoundsException $e) {
    return 0;
  }
}
```

**After:**

```php
function getValueForPeriod($periodNumber) {
  if ($periodNumber >= count($this->values)) {
    return 0;
  }
  return $this->values[$periodNumber];
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Exception with Test](../Simplifying%20Method%20Calls.md#replace-exception-with-test)

---

<a id="python"></a>
### Python

**Before:**

```python
def getValueForPeriod(periodNumber):
    try:
        return values[periodNumber]
    except IndexError:
        return 0
```

**After:**

```python
def getValueForPeriod(self, periodNumber):
    if periodNumber >= len(self.values):
        return 0
    return self.values[periodNumber]
```

[↑ Back to top](#available-languages) | [← Back to Replace Exception with Test](../Simplifying%20Method%20Calls.md#replace-exception-with-test)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
getValueForPeriod(periodNumber: number): number {
  try {
    return values[periodNumber];
  } catch (ArrayIndexOutOfBoundsException e) {
    return 0;
  }
}
```

**After:**

```typescript
getValueForPeriod(periodNumber: number): number {
  if (periodNumber >= values.length) {
    return 0;
  }
  return values[periodNumber];
}
```

[↑ Back to top](#available-languages) | [← Back to Replace Exception with Test](../Simplifying%20Method%20Calls.md#replace-exception-with-test)

---
