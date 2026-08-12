# Remove Assignments to Parameters - Code Examples

[← Back to Remove Assignments to Parameters explanation](../Composing%20Methods.md#remove-assignments-to-parameters)

**Section:** [Composing Methods](../Composing%20Methods.md) | **Original:** [Remove Assignments to Parameters](https://refactoring.guru/remove-assignments-to-parameters)

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
int discount(int inputVal, int quantity) {
  if (quantity > 50) {
    inputVal -= 2;
  }
  // ...
}
```

**After:**

```java
int discount(int inputVal, int quantity) {
  int result = inputVal;
  if (quantity > 50) {
    result -= 2;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Remove Assignments to Parameters](../Composing%20Methods.md#remove-assignments-to-parameters)

---

<a id="csharp"></a>
### C#

**Before:**

```csharp
int Discount(int inputVal, int quantity) 
{
  if (quantity > 50) 
  {
    inputVal -= 2;
  }
  // ...
}
```

**After:**

```csharp
int Discount(int inputVal, int quantity) 
{
  int result = inputVal;
  
  if (quantity > 50) 
  {
    result -= 2;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Remove Assignments to Parameters](../Composing%20Methods.md#remove-assignments-to-parameters)

---

<a id="php"></a>
### PHP

**Before:**

```php
function discount($inputVal, $quantity) {
  if ($quantity > 50) {
    $inputVal -= 2;
  }
  ...
```

**After:**

```php
function discount($inputVal, $quantity) {
  $result = $inputVal;
  if ($quantity > 50) {
    $result -= 2;
  }
  ...
```

[↑ Back to top](#available-languages) | [← Back to Remove Assignments to Parameters](../Composing%20Methods.md#remove-assignments-to-parameters)

---

<a id="python"></a>
### Python

**Before:**

```python
def discount(inputVal, quantity):
    if quantity > 50:
        inputVal -= 2
    # ...
```

**After:**

```python
def discount(inputVal, quantity):
    result = inputVal
    if quantity > 50:
        result -= 2
    # ...
```

[↑ Back to top](#available-languages) | [← Back to Remove Assignments to Parameters](../Composing%20Methods.md#remove-assignments-to-parameters)

---

<a id="typescript"></a>
### TypeScript

**Before:**

```typescript
discount(inputVal: number, quantity: number): number {
  if (quantity > 50) {
    inputVal -= 2;
  }
  // ...
}
```

**After:**

```typescript
discount(inputVal: number, quantity: number): number {
  let result = inputVal;
  if (quantity > 50) {
    result -= 2;
  }
  // ...
}
```

[↑ Back to top](#available-languages) | [← Back to Remove Assignments to Parameters](../Composing%20Methods.md#remove-assignments-to-parameters)

---
